# DB_DECODE

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**[DB_FIDS](DB_FIDS.md)** --
**DB_DECODE**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The codec for the records the DATABASE/DBNAV protocol moves: the byte
anatomy of a record, the ENC catalogue that decodes a value, and the
source-provenance stamp that says where the value came from. Despite the
name this is both directions -- decoding a record read from the unit, and
encoding one to write back.

## The boundary: what DATABASE hands off

[DATABASE](DATABASE.md) runs the *conversation* -- ports, commands,
transactions, subscription, the broadcast cadence, packet and frame
headers, lengths, and reassembly. Once it has delivered one complete
record, its job is done and this document takes over: a record's interior
is defined and interpreted *here*.

The two documents divide on one rule, applied throughout: **a field is
defined in exactly one of them; the other refers to it by name.**

- **DATABASE owns the conversation** -- everything whose meaning is "how
  to move and address records," and which is discarded once you hold the
  record: the cmd_words, the transaction framing, the broadcast packet
  header, the frame length (`biglen`), `ttl`, and the `fid` used as a
  routing key.
- **DB_DECODE owns the record** -- the bytes inside one record: its
  header, its value (decoded per the ENC catalogue), and its source
  stamp. This is the part you keep.

Because a write *accepts* a record the client built (the SetItem path
hands back a read record with its value replaced), encoding is just
decoding run in reverse over the identical layout. Everything below reads
both ways.

## One record, two source views

The wire carries a single kind of record: the **value-record** -- a FID's
value together with where it came from. There is no separate "identity"
record. A FID may have several sources (a twin-engine boat feeds the
engine-RPM FID from two engines), and every source has its own
value-record.

What varies is *which* of a FID's sources you get:

- the **value** (preferred) view -- the one preferred source's
  value-record. This is what a value read returns and what the value
  broadcast (0x300) carries.
- the **directory** (all-sources) view -- every source's value-record,
  one per source. This is what a source enumeration returns and what the
  directory broadcast (0x301) carries.

Both views deliver value-records, decoded identically here; they differ
only in how many of a FID's sources they include. A source is identified
by an 8-byte **UUID** (`[device_id | per-item]`) that rides at the
transaction-envelope level (the Start/End frames), never inside a record
body.

Which exchange carries which:

| Exchange (see [DATABASE](DATABASE.md)) | direction | carries |
|----------------------------------------|-----------|---------|
| value read (QUERY) | E80 -> client | the preferred source's value-record |
| write (SetItem) | client -> E80 | one value-record |
| source enumeration / keyed read | E80 -> client | each source's value-record |
| value broadcast (0x300) | E80 -> multicast | preferred-source value-records |
| directory broadcast (0x301) | E80 -> multicast | all-source value-records |

A broadcast packet is a *list*: a header followed by N value-records. A
point-to-point read or write carries one record per transaction. Either
way the unit of decoding is a single value-record.

## Anatomy of a record

Every record shares a three-zone shape: a **header** identifying the FID
and its encoding, the **value**, and a **source tail**. The layout is
code-confirmed in
`DataProviderItem_serializeToSink` (@0x459c) and its tail helper
(@0x92d0), and wire-confirmed on the live unit.

A record is serialized two ways depending on how it travels. Both agree
on the header; they pack the tail differently.

**Transaction form** (a QUERY reply or a write, inside an INFO
transaction). All little-endian:

```
fid        (4)        the field id
enc        (2)        the encoding-type id (this catalogue)
size       (2)        byte length of the value
reserved   (4)        zero in practice
value      (size)     the datum -- decode per enc
A          (4)        SOURCE family (low byte meaningful)
B          (4)        SOURCE class  (low byte meaningful)
src-len    (2)        descriptor length: 6 for an N2K source, else 0
pad        (2)        zero
descriptor (src-len)  the N2K source descriptor (below), when src-len > 0
```

The transaction's frame length (`biglen`, owned by DATABASE) brackets
exactly this record: `biglen = 12 (header) + size + 12 + src-len`.
Verified against live captures (depth `12+4+12 = 0x1c`, latlon
`12+8+12 = 0x20`).

**Broadcast form** (a FIELD or UUID multicast record). Same header; a
compact, self-delimiting tail with a time-to-live:

```
fid        (4)
enc        (2)
len        (2)        = size
data       (len)      the value (decode per enc)
type8      (1)        the source FAMILY (= A), low byte
ttl        (1)        broadcast time-to-live -- a delivery field (its role is DATABASE's)
extra_len  (2)        length of the trailing descriptor block
extra      (extra_len) the source descriptor (the N2K [PGN|SA|flag]), when present
```

So the source stamp rides both forms, but they keep different parts of
it. The transaction form spells out both source words -- `A | B | src-len
| descriptor`. The broadcast form keeps only the source **family**, packed
to the one-byte `type8` (= `A`'s low byte), plus the descriptor in
`extra`, and adds a `ttl`; **it drops the source class (`B`) entirely** --
a broadcast record carries the family but not the class. (Firmware-
confirmed: `type8` is the same field the transaction tail writes as `A`.)

There is no separate directory record to lay out. The directory broadcast
(0x301) emits the same value-record per source -- identical in layout to
the value broadcast (0x300) -- and simply enumerates *all* of a FID's
sources rather than just the preferred one. (Firmware-confirmed via the
directory packet builder; the 0x300 value broadcast is also wire-confirmed
via `d_DBNAV`, the 0x301 directory broadcast established from the
firmware -- a live 0x301 capture would be the final empirical check.)

## The value axis: the ENC catalogue

The `enc` field selects a firmware decode type -- its units, scale,
structure, and signedness. ENC is orthogonal to FID: one ENC backs many
FIDs (ENC `0x002a` `ANGLE_0_0001_RAD_T` backs every heading-like field).

- **Signed bit.** An ENC with the `0x8000` bit set is the signed variant
  of its base type (`0x8011 SIGNED_ANGLE_0_0001_RAD_T` vs `0x002a
  ANGLE_0_0001_RAD_T`). Mask `0x8000` for the base; the bit means the
  value is two's-complement.
- **Width.** `size` in the record equals the storage width below: 1, 2,
  4, or 8 bytes for scalars, and the per-struct width for `var` types.
- **Self-documenting names.** The scale lives in the name --
  `ANGLE_0_0001_RAD` is angle in 0.0001 rad, `LONG_DISTANCE_0_01_METRES`
  is distance in 0.01 m, `REVOLUTION_RATE_0_25_RPM` is 0.25 rpm.

The full catalogue, sorted by id (name shown with namespace stripped and
the trailing `_T` restored; `var` = variable-width packed struct):

| ENC | ENC type | bytes | signed | Pub::Ray* |
|-----|----------|-------|--------|-----------|
| 0x0000 | SPEED_0_1_METRES_PER_SECOND_T | 2 |  | deciMetersPerSec |
| 0x0001 | SPEED_0_01_METRES_PER_SECOND_T | 2 |  | centiMetersPerSec |
| 0x0003 | DATE_T | 2 |  | date |
| 0x0004 | TIME_0_0001_SECONDS_T | 4 |  | time |
| 0x0005 | TIME_SECONDS_T | 4 |  | seconds |
| 0x000d | DISTANCE_METRES_T | 4 |  | distanceMeters |
| 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  | depth / distanceCentiMeters |
| 0x0012 | TEMPERATURE_0_01_KELVIN_T | 2 |  | kelvinOver100 |
| 0x0013 | TEMPERATURE_0_1_KELVIN_T | 2 |  | kelvinOver10 |
| 0x0014 | PRESSURE_100_PASCAL_T | 2 |  | millibarsToPSI |
| 0x001a | REVOLUTION_RATE_0_25_RPM_T | 2 |  | intWordOver4 |
| 0x0025 | PASSWORD_TEXT_T | 1 |  |  |
| 0x0028 | COMPASS_STATUS_T | 1 |  |  |
| 0x002a | ANGLE_0_0001_RAD_T | 2 |  | heading |
| 0x002b | TRANSMISSION_GEAR_T | 1 |  |  |
| 0x002c | ENGINE_DISCRETE_STATUS_T | 2 |  |  |
| 0x002d | TRANSMISSION_DISCRETE_STATUS_T | 1 |  |  |
| 0x002e | PACKED_TRIP_PARAMETERS_STRUCT_T | var |  |  |
| 0x0031 | PACKED_BEARING_DISTANCE_BETWEEN_TWO_MARKS_STRUCT_T | var |  |  |
| 0x0033 | PACKED_TIME_TO_OR_FROM_MARK_STRUCT_T | var |  |  |
| 0x0034 | PACKED_DATUM_STRUCT_T | var |  |  |
| 0x0035 | PACKED_DGNSS_CORRECTIONS_STRUCT_T | var |  |  |
| 0x0036 | PACKED_GNSS_CONTROL_STATUS_STRUCT_T | var |  |  |
| 0x0037 | PACKED_GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_INTERFACE_STRUCT_T | var |  |  |
| 0x0038 | PACKED_GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_SIGNAL_STRUCT_T | var |  |  |
| 0x0039 | PACKED_GNSS_DOPS_STRUCT_T | var |  |  |
| 0x003a | PACKED_GNSS_POSITION_DATA_STRUCT_T | var |  |  |
| 0x003b | PACKED_GNSS_RAIM_OUTPUT_STRUCT_T | var |  |  |
| 0x003c | PACKED_POSITION_STRUCT_T | 8 |  | latLon |
| 0x003d | PACKED_NMEA2000_NAVIGATION_DATA_STRUCT_T | var |  |  |
| 0x003e | PACKED_HEADING_TRACK_CONTROL_STRUCT_T | var |  |  |
| 0x0043 | PACKED_NMEA0183_BEARING_DISTANCE_TO_WAYPOINT_STRUCT_T | var |  |  |
| 0x0046 | PACKED_NMEA0183_RECOMMENDED_MINIMUM_NAVIGATION_INFO_STRUCT_T | var |  |  |
| 0x0047 | PACKED_NMEA0183_AUTOPILOT_DATA_STRUCT_T | var |  |  |
| 0x004a | PACKED_NAV_MOVING_DATA_STRUCT_T | var |  |  |
| 0x0051 | AVERAGE_SPEED_STATUS_T | 1 |  |  |
| 0x0052 | ST2_AUTOPILOT_MODE_T | 4 |  |  |
| 0x0052 | COURSE_COMPUTER_STATUS_T | 4 |  |  |
| 0x0053 | XTE_MODE_T | 1 |  |  |
| 0x0054 | BOOL8 | 1 |  |  |
| 0x0055 | DIRECTION_ORDER_T | 1 |  |  |
| 0x0056 | COURSE_COMPUTER_RESPONSE_LEVEL_T | 1 |  |  |
| 0x0057 | COURSE_COMPUTER_RUDDER_GAIN_T | 1 |  |  |
| 0x005a | PACKED_GPS_SATELLITES_STRUCT_T | var |  |  |
| 0x005b | PACKED_GPS_SATELLITES_IN_USE_STRUCT_T | var |  |  |
| 0x005d | GPS_VISABLE_SATELLITE_COUNT_T | 1 |  |  |
| 0x005f | GPS_ENABLE_DIFF_T | 1 |  |  |
| 0x0060 | GPS_QUALITY_INDICATOR_T | 1 |  |  |
| 0x0061 | GPS_USED_SATELLITE_COUNT_T | 1 |  |  |
| 0x0062 | GPS_HDOP_T | 2 |  |  |
| 0x0063 | GPS_ANTENNA_HEIGHT_T | 4 | Y |  |
| 0x0064 | GPS_GEOIDAL_HEIGHT_T | 4 | Y |  |
| 0x0065 | DGPS_AGE_T | 2 |  |  |
| 0x0066 | DGPS_STATION_ID_T | 2 |  |  |
| 0x0067 | PACKED_DGPS_DATA_STRUCT_T | var |  |  |
| 0x0068 | PACKED_GPS_DIFF_SATS_STRUCT_T | var |  |  |
| 0x0069 | GPS_SAT_DIFF_STATUS_T | 1 |  |  |
| 0x0071 | MOB_STATE_T | 1 |  |  |
| 0x0072 | WAYPOINT_ID_T | var |  | string |
| 0x0073 | PACKED_MM_POSITION_STRUCT_T | var |  | northEast |
| 0x0076 | PACKED_GPS_FIXMODE_SMOOTHING_SETUP_STRUCT_T | var |  |  |
| 0x0077 | PACKED_GPS_USER_DATUM_SETUP_STRUCT_T | var |  |  |
| 0x0078 | GPS_DIFF_SATS_ENABLED_PRN_MAP_T | 4 |  |  |
| 0x0079 | PACKED_UNIT_IDENTITY_STRUCT_T | var |  |  |
| 0x007a | DGPS_DIFF_SOURCE_T | 1 |  |  |
| 0x0080 | GPS_OPERATING_MODE_T | 1 |  |  |
| 0x0081 | GPS_FIX_MODE_T | 1 |  |  |
| 0x0082 | WAYPOINT_POSITION_ENTRY_T | 1 |  |  |
| 0x0083 | SIMULATOR_MODE_T | 1 |  |  |
| 0x0084 | BEARING_MODE_T | 1 |  |  |
| 0x0085 | MOB_DATA_TYPE_T | 1 |  |  |
| 0x0086 | VARIATION_SOURCE_T | 1 |  |  |
| 0x0087 | LANGUAGE_T | 1 |  |  |
| 0x0088 | CURSOR_READOUT_T | 1 |  |  |
| 0x0089 | CURSOR_REFERENCE_T | 1 |  |  |
| 0x008a | DISTANCE_UNITS_T | 1 |  |  |
| 0x008b | SPEED_UNITS_T | 1 |  |  |
| 0x008c | TEMPERATURE_UNITS_T | 1 |  |  |
| 0x008d | DEPTH_UNITS_T | 1 |  |  |
| 0x008e | DATE_FORMAT_T | 1 |  |  |
| 0x008f | TIME_FORMAT_T | 1 |  |  |
| 0x0090 | TIME_OFFSET_T | 1 |  |  |
| 0x0091 | TIME_0_0001_SECONDS_T | 4 |  |  |
| 0x0097 | RACE_TIME_STATUS_T | 1 |  |  |
| 0x0098 | TEMPERATURE_ALARM_LIMITS_T | 1 |  |  |
| 0x0099 | POSITION_PRECISION_T | 1 |  |  |
| 0x009f | PACKED_DSC_DISTRESS_DATA_STRUCT_T | var |  |  |
| 0x00a0 | PACKED_COURSE_COMPUTER_RESPONSE_LEVEL_LIMITS_STRUCT_T | var |  |  |
| 0x00a1 | PACKED_COURSE_COMPUTER_RUDDER_GAIN_LIMITS_STRUCT_T | var |  |  |
| 0x00a4 | MMI_AUTOPILOT_CONTROL_MODE_T | 1 |  |  |
| 0x00a5 | DSC_MESSAGES_MODE_T | 1 |  |  |
| 0x00a6 | SEATALK_ALARMS_MODE_T | 1 |  |  |
| 0x00a7 | PERCENT_T | 1 |  |  |
| 0x00a9 | OBJECT_INFORMATION_T | 1 |  |  |
| 0x00ab | CHART_DISPLAY_T | 1 |  |  |
| 0x00ac | NAV_MARKS_SYMBOLS_T | 1 |  |  |
| 0x00ad | SYMBOL_T | 1 |  |  |
| 0x00ae | CALCULATION_TYPE_T | 1 |  |  |
| 0x00af | WAYPOINT_NAME_T | var |  | string15 |
| 0x00b1 | PACKED_LORAN_POSITION_STRUCT_T | var |  |  |
| 0x00b7 | FREQUENCY_1_HERTZ_T | 4 |  |  |
| 0x00ba | TD_CHAIN_T | 1 |  |  |
| 0x00bb | TD_SLAVE_T | 1 |  |  |
| 0x00bc | TD_SLAVE_T | 1 |  |  |
| 0x00bd | TD_ASF_T | 1 |  |  |
| 0x00be | TD_ASF_T | 1 |  |  |
| 0x00c0 | UINT8 | 1 |  |  |
| 0x00c2 | BRIDGE_NMEA_HEADING_MODE_T | 1 |  |  |
| 0x00c5 | SAFETY_CONTOUR_T | 1 |  |  |
| 0x00c6 | DEPTH_CONTOUR_T | 1 |  |  |
| 0x00ca | POSITION_SOURCE_T | 1 |  |  |
| 0x00cb | RADAR_SYSTEM_DATA_T | var |  |  |
| 0x00cf | POSITION_OFFSET_VALUE_T | 1 |  |  |
| 0x00d1 | PHOTO_OVERLAY_VALUE_T | 1 |  |  |
| 0x00d3 | VOLUME_0_1_LITRE_T | 4 |  | deciLitresToGallons |
| 0x00d4 | FUEL_ECONOMY_METRES_PER_LITRE_T | 4 |  |  |
| 0x00da | PRESSURE_UNITS_T | 1 |  |  |
| 0x00db | VOLUME_UNITS_T | 1 |  |  |
| 0x00dc | ALTERNATOR_VOLTAGE_RANGE_T | 1 |  |  |
| 0x00dd | ENGINE_REV_LIMIT_T | 1 |  |  |
| 0x00e0 | RAY_GUID | 4 |  |  |
| 0x00e1 | BOAT_ICON_3D_T | 1 |  |  |
| 0x00e2 | AERIAL_OVERLAY_T | 1 |  |  |
| 0x00e3 | PACKED_BATHY_VIEW_LOCATOR_STRUCT_T | var |  |  |
| 0x00e4 | PACKED_BATHY_3D_SYNC_STRUCT_T | var |  |  |
| 0x00e6 | TRACK_RECORDING_METHOD_T | 1 |  |  |
| 0x00e7 | TRACK_RECORDING_TIME_INTERVAL_T | 1 |  |  |
| 0x00e9 | TRACK_RECORDING_DISTANCE_INTERVAL_T | 1 |  |  |
| 0x00ec | NUMBER_OF_ENGINES_T | 1 |  |  |
| 0x00ee | AIS_TARGET_TYPE_DISPLAY_OPTION_T | 1 |  |  |
| 0x00ef | UINT32 | 4 |  |  |
| 0x00f1 | BACKGROUND_COLOR_T | 1 |  |  |
| 0x00f3 | VECTOR_LENGTH_T | var |  |  |
| 0x00f4 | HISTORY_LENGTH_T | var |  |  |
| 0x00f5 | VECTOR_WIDTHS_T | 1 |  |  |
| 0x00f6 | COMPASS_BAR_MODE_T | 1 |  |  |
| 0x00f8 | BOAT_SIZE_3D_T | 1 |  |  |
| 0x00f8 | UINT32 | 1 |  |  |
| 0x00f9 | ONAN_GENSET_STATUS_T | 1 |  |  |
| 0x00fb | NUMBER_OF_GENSETS_T | 1 |  |  |
| 0x00fe | HIDE_ROCKS_T | 1 |  |  |
| 0x00ff | FISH_FINDER_PRESET_INDEX_T | 1 |  |  |
| 0x0103 | FISH_FINDER_COLOUR_THRESHOLD_T | 1 |  |  |
| 0x0104 | CHART_VIEW_DATA_VERSION_NUMBER_T | 1 |  |  |
| 0x0106 | G_SERIES_KEYBOARD_BACKLIGHT_CONTROL_T | 1 |  |  |
| 0x0108 | char [6] | var |  |  |
| 0x010a | TURN_SEVERITY_T | 1 |  |  |
| 0x010b | WAYPOINT_SEQUENCE_ID_T | 2 |  |  |
| 0x010c | WAYPOINT_NUMBER_T | 2 |  |  |
| 0x010e | RTE_TRK_LEG_WIDTHS_T | 1 |  |  |
| 0x8002 | SIGNED_SPEED_0_001_METRES_PER_SECOND_T | 2 | Y |  |
| 0x8011 | SIGNED_ANGLE_0_0001_RAD_T | 2 | Y | heading |
| 0x8018 | POTENTIAL_0_01_VOLTS_T | 2 | Y | wordOver100 |
| 0x8019 | CURRENT_0_1_AMPS_T | 2 | Y |  |
| 0x801c | VOLUME_RATE_0_0001_CUBIC_METRES_PER_HOUR_T | 2 | Y | deciLitresToGallons |
| 0x801d | SIGNED_PERCENT_T | 1 | Y |  |
| 0x801e | SIGNED_0_004_PERCENT_T | 2 | Y | wordOver250 |
| 0x8027 | SIGNED_TIME_MINUTES_T | 2 | Y |  |
| 0x806c | SIGNED_ANGLE_0_1_DEG_T | 2 | Y |  |
| 0x80a3 | GPS_DATUM_INDEX_T | 1 | Y |  |
| 0x80a8 | SIGNED_SPEED_0_01_METRES_PER_SECOND_T | 2 | Y | centiMetersPerSec |
| 0x80c3 | SIGNED_DISTANCE_0_001_METRES_T | 2 | Y |  |

\* These are the existing `d_DBNAV` decoders at the time of this writing. They are subject to change in Pub::Ray at any time.

The `var` (packed-struct) types -- positions, GPS/GNSS/DSC/autopilot
families, unit identity -- decode per their own sub-layouts, a second
tier below the scalar codecs.

## The source axis: the A / B / X provenance stamp

The record tail stamps **where a value came from**. `A` and `B` are
runtime, last-writer-wins values: they describe the source that last fed
*this* value, not a fixed attribute of the FID (a FID shows whichever
family last wrote it). The full mechanism and the firmware call chain are
in the source-descriptor analysis.

**A = source family** (the kind of producing engine):

| A | family |
|---|--------|
| 4 | NMEA 2000 bus (carries a descriptor) |
| 5 | NMEA 0183 |
| 7 | application / configuration set |
| 9 | SeaTalk / instrument bus |
| 10 | internal computation / average / nav |
| 12 | GPS / compass fusion |
| 15 | heading / COG primary |

**B = source class** (a sub-tag within a family):

| B | meaning | within |
|---|---------|--------|
| 5 | basic instrument (depth/speed/heading/wind) | family 9 |
| 0 | log / computed / config | families 7, 9, 10 |
| 12 | waypoint | family 9 |
| 30 | GPS | family 9 |
| 0x19 | the N2K class tag | family 4 |

**X = the N2K source descriptor** (`src-len = 6`, NMEA 2000 only):

```
PGN (4)  |  SA (1)  |  flag (1)
```

- **SA** -- the live bus source address, the real per-frame provenance
  datum.
- **flag** -- a static per-handler byte; `0` for most handlers, `1` for
  the Engine-Rapid handler (PGN 127488).

0183, SeaTalk, and computed sources carry no descriptor (`src-len = 0`).

**PGN -> FID** is a separate, firmware-derived table (one PGN feeds
several FIDs; e.g. PGN 128267 feeds FIDs `0x09`/`0x0a`). The authoritative
binding comes from the N2K `pgnHandler` constructors, not a bench-observed
PGN column; it lives with this source material.

---

**Next:** [Home (Abstracts)](readme.md) ...
