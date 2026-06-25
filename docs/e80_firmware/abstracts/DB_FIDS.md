# DB_FIDS

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**DB_FIDS** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The field dictionary the DATABASE/DBNAV protocol carries: every FID the
E80 database registers, its encoding, and its meaning. A component of
[DATABASE](DATABASE.md) -- the substantive content of what that protocol
delivers.

## The two axes: FID and ENC

Every datum the database carries is a **(FID, ENC, value)**. The two
identifiers are independent and answer different questions:

- The **FID** (field ID) says *what the value means and which source
  produced it* -- "this engine's RPM", "the main compass heading", "the
  speed-through-water reading". A FID names a per-source quantity.
- The **ENC** (encoding) says *how to decode the bytes* -- the units,
  scale, precision, and shape (scalar or packed struct).

The firmware binds each registered FID to exactly one ENC, and that same
binding rides on every value the unit serializes on the wire. Decoder
choice is therefore driven by the ENC, not guessed per FID. The high bit
of an ENC word (`0x8000`) marks a **signed** encoding; the remaining bits
select the base type.

The ENC column here gives the binding for each FID; the full mechanistic
catalogue of every ENC type -- units, scale, structure, signedness -- is
[DB_DECODE](DB_DECODE.md). The wire protocol that carries these records
is [DATABASE](DATABASE.md).

## Two namespaces

FIDs fall into two namespaces, distinguished by the top byte:

- **Instrument** (top byte `0x00`) -- live measured values the unit
  computes or receives. These are broadcast on the DBNAV multicast and
  are also readable point-to-point.
- **Application** (top byte `0x01`, `0x03`, `0x05`, `0x06`) -- the
  unit's persistent settings. These never broadcast (subscription is
  namespace-gated to the instrument set), but they read and write
  point-to-point over the stock protocol.

## Instrument / broadcast FIDs

The live-measured half: the per-source instrument quantities the unit
computes or receives and broadcasts on DBNAV. Each FID's **ENC** is the
decode-type binding recovered from the firmware's source-constructor
registration code -- *source-independent*, so it states a FID's encoding
whether or not a source is currently feeding it.

That resolves an ambiguity the wire alone cannot. A FID's live type-id
reads `0x0000` in two different situations: when its decode type is
genuinely SPEED_0_1 (encoding id `0`), and when no decode type is bound
at all. The code separates the two -- the apparent-wind speeds
(`0x58`/`0x5a`/`0x5c`) are *genuine* encoding-`0` quantities, while
`0x33..0x43` are **reserved** slots with no decode type. So in this table
`0x0000` is a real binding, and a slot with no decode type is marked
`reserved` outright.

A **Name** is given where the per-source meaning is resolved (the `d_DB`
decoder set); where it is blank, the **ENC type** still states how the
slot's bytes decode. Runs of consecutive reserved (or same-ENC unnamed)
slots are collapsed to a range.

| FID | ENC | ENC type | Name | bytes | source |
|-----|-----|----------|------|-------|--------|
| 0x03 | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T | SPEED | 2 |  |
| 0x04 | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T | SOG | 2 |  |
| 0x05 | 0x0003 | DATE_T |  | 2 |  |
| 0x06 | 0x0004 | TIME_0_0001_SECONDS_T |  | 4 |  |
| 0x07 | 0x000d | DISTANCE_METRES_T | LOG_TOTAL | 4 |  |
| 0x08 | 0x000d | DISTANCE_METRES_T | LOG_TRIP | 4 |  |
| 0x09 | 0x000e | LONG_DISTANCE_0_01_METRES_T | DEPTH | 4 |  |
| 0x0a | 0x80c3 | SIGNED_DISTANCE_0_001_METRES_T |  | 2 |  |
| 0x0b..0x0d |  | reserved |  |  |  |
| 0x0f | 0x0012 | TEMPERATURE_0_01_KELVIN_T |  | 2 |  |
| 0x10..0x11 |  | reserved |  |  |  |
| 0x12 | 0x0004 | TIME_0_0001_SECONDS_T | TIME | 4 |  |
| 0x13 | 0x0003 | DATE_T | DATE | 2 |  |
| 0x14 | 0x8011 | SIGNED_ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x15..0x16 |  | reserved |  |  |  |
| 0x17 | 0x002a | ANGLE_0_0001_RAD_T | HEADING | 2 |  |
| 0x18 | 0x002a | ANGLE_0_0001_RAD_T | SET | 2 |  |
| 0x19 | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T | DRIFT | 2 |  |
| 0x1a | 0x002a | ANGLE_0_0001_RAD_T | COG | 2 |  |
| 0x1b | 0x8011 | SIGNED_ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x1c | 0x8011 | SIGNED_ANGLE_0_0001_RAD_T | HEAD_MAYBE | 2 |  |
| 0x21 | 0x0014 | PRESSURE_100_PASCAL_T | ENG_OIL_PRESS1 | 2 |  |
| 0x22 | 0x0013 | TEMPERATURE_0_1_KELVIN_T | ENG_OIL_TEMP1 | 2 |  |
| 0x23 | 0x002c | ENGINE_DISCRETE_STATUS_T |  | 2 |  |
| 0x24 | 0x0012 | TEMPERATURE_0_01_KELVIN_T | ENG_COOL_TEMP1 | 2 |  |
| 0x25 | 0x8018 | POTENTIAL_0_01_VOLTS_T | ENG_ALT_VOLT1 | 2 |  |
| 0x26 | 0x801c | VOLUME_RATE_0_0001_CUBIC_METRES_PER_HOUR_T | ENG_FUEL_RATE | 2 |  |
| 0x2b..0x2f |  | reserved |  |  |  |
| 0x30 | 0x001a | REVOLUTION_RATE_0_25_RPM_T | ENG_RPM1 | 2 |  |
| 0x31 | 0x0014 | PRESSURE_100_PASCAL_T |  | 2 |  |
| 0x32 | 0x801e | SIGNED_0_004_PERCENT_T | FUEL_LEVEL2 | 2 |  |
| 0x33 |  | reserved |  |  |  |
| 0x34 | 0x000e | LONG_DISTANCE_0_01_METRES_T | XTE | 4 |  |
| 0x35..0x43 |  | reserved |  |  |  |
| 0x44 | 0x003c | PACKED_POSITION_STRUCT_T | LATLON | 8 |  |
| 0x45..0x46 |  | reserved |  |  |  |
| 0x47 | 0x002a | ANGLE_0_0001_RAD_T | HEADING_MAG | 2 |  |
| 0x48 | 0x002a | ANGLE_0_0001_RAD_T | HEADING_MAG2 | 2 |  |
| 0x49 | 0x002a | ANGLE_0_0001_RAD_T | SET_MAG | 2 |  |
| 0x4e..0x54 |  | reserved |  |  |  |
| 0x55 | 0x80a8 | SIGNED_SPEED_0_01_METRES_PER_SECOND_T | VMG_WIND | 2 |  |
| 0x58 | 0x0000 | SPEED_0_1_METRES_PER_SECOND_T | WIND_SPEED_APP | 2 |  |
| 0x59 | 0x002a | ANGLE_0_0001_RAD_T | WIND_ANGLE_APP | 2 |  |
| 0x5a | 0x0000 | SPEED_0_1_METRES_PER_SECOND_T | WIND_SPEED_TRUE | 2 |  |
| 0x5b | 0x002a | ANGLE_0_0001_RAD_T | WIND_ANGLE_TRUE | 2 |  |
| 0x5c | 0x0000 | SPEED_0_1_METRES_PER_SECOND_T | WIND_SPEED_GND | 2 |  |
| 0x5d | 0x002a | ANGLE_0_0001_RAD_T | WIND_ANGLE_GND | 2 |  |
| 0x5e |  | reserved |  |  |  |
| 0x5f | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x60 | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T |  | 2 |  |
| 0x61 | 0x0051 | AVERAGE_SPEED_STATUS_T |  | 1 |  |
| 0x62 | 0x8027 | SIGNED_TIME_MINUTES_T |  | 2 |  |
| 0x63 | 0x0028 | COMPASS_STATUS_T |  | 1 |  |
| 0x64 | 0x0052 | ST2_AUTOPILOT_MODE_T |  | 4 |  |
| 0x65 |  | reserved |  |  |  |
| 0x66 | 0x002a | ANGLE_0_0001_RAD_T | WP_HEADING | 2 |  |
| 0x67 | 0x002a | ANGLE_0_0001_RAD_T | WP_HEADING_MAG | 2 |  |
| 0x68 | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x69 | 0x0072 | WAYPOINT_ID_T | WP_ID | var |  |
| 0x6a | 0x000d | DISTANCE_METRES_T | WP_DISTANCE | 4 |  |
| 0x6b | 0x000d | DISTANCE_METRES_T |  | 4 |  |
| 0x6c | 0x0055 | DIRECTION_ORDER_T |  | 1 |  |
| 0x6d |  | reserved |  |  |  |
| 0x6e..0x6f | 0x0054 | BOOL8 |  | 1 |  |
| 0x70 |  | reserved | WP_HEADING2 |  |  |
| 0x71 |  | reserved |  |  |  |
| 0x72 | 0x0056 | COURSE_COMPUTER_RESPONSE_LEVEL_T |  | 1 |  |
| 0x73 | 0x0057 | COURSE_COMPUTER_RUDDER_GAIN_T |  | 1 |  |
| 0x74 |  | reserved |  |  |  |
| 0x76 | 0x005a | PACKED_GPS_SATELLITES_STRUCT_T |  | var |  |
| 0x77 | 0x005b | PACKED_GPS_SATELLITES_IN_USE_STRUCT_T |  | var |  |
| 0x79 | 0x005d | GPS_VISABLE_SATELLITE_COUNT_T |  | 1 |  |
| 0x7b | 0x005f | GPS_ENABLE_DIFF_T |  | 1 |  |
| 0x7c | 0x0054 | BOOL8 |  | 1 |  |
| 0x7d | 0x0060 | GPS_QUALITY_INDICATOR_T |  | 1 |  |
| 0x7e | 0x0061 | GPS_USED_SATELLITE_COUNT_T |  | 1 |  |
| 0x7f | 0x0062 | GPS_HDOP_T | GPS_HDOP | 2 |  |
| 0x80 | 0x0063 | GPS_ANTENNA_HEIGHT_T |  | 4 |  |
| 0x81 | 0x0064 | GPS_GEOIDAL_HEIGHT_T |  | 4 |  |
| 0x82 | 0x0065 | DGPS_AGE_T |  | 2 |  |
| 0x83 | 0x0066 | DGPS_STATION_ID_T |  | 2 |  |
| 0x84 | 0x0067 | PACKED_DGPS_DATA_STRUCT_T |  | var |  |
| 0x85 | 0x0068 | PACKED_GPS_DIFF_SATS_STRUCT_T |  | var |  |
| 0x86 | 0x0069 | GPS_SAT_DIFF_STATUS_T |  | 1 |  |
| 0x87..0x88 | 0x0054 | BOOL8 |  | 1 |  |
| 0x89 | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x8a | 0x00a7 | PERCENT_T |  | 1 |  |
| 0x8b | 0x0071 | MOB_STATE_T |  | 1 |  |
| 0x8c | 0x000e | LONG_DISTANCE_0_01_METRES_T |  | 4 |  |
| 0x8d | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x8e..0x8f | 0x000d | DISTANCE_METRES_T |  | 4 |  |
| 0x90 |  | reserved |  |  |  |
| 0x91 | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0x92 | 0x0005 | TIME_SECONDS_T |  | 4 |  |
| 0x93 | 0x0073 | PACKED_MM_POSITION_STRUCT_T | NORTHEAST | var |  |
| 0x94 | 0x0076 | PACKED_GPS_FIXMODE_SMOOTHING_SETUP_STRUCT_T |  | var |  |
| 0x95 | 0x0077 | PACKED_GPS_USER_DATUM_SETUP_STRUCT_T |  | var |  |
| 0x96 | 0x0078 | GPS_DIFF_SATS_ENABLED_PRN_MAP_T |  | 4 |  |
| 0x97 | 0x0079 | PACKED_UNIT_IDENTITY_STRUCT_T |  | var |  |
| 0x98 | 0x007a | DGPS_DIFF_SOURCE_T |  | 1 |  |
| 0x99 | 0x003c | PACKED_POSITION_STRUCT_T | LATLON2 | 8 |  |
| 0x9a..0x9b |  | reserved |  |  |  |
| 0x9c |  |  | TIME2 |  |  |
| 0x9e | 0x0099 | POSITION_PRECISION_T |  | 1 |  |
| 0x9f | 0x009f | PACKED_DSC_DISTRESS_DATA_STRUCT_T |  | var |  |
| 0xa0..0xa2 |  | reserved |  |  |  |
| 0xa5 | 0x002a | ANGLE_0_0001_RAD_T |  | 2 |  |
| 0xaa | 0x0003 | DATE_T | DATE2 | 2 |  |
| 0xb6 |  |  | VMG_WPT |  |  |
| 0xb9 | 0x80a3 | GPS_DATUM_INDEX_T |  | 1 |  |
| 0xba | 0x002a | ANGLE_0_0001_RAD_T | HEAD2 | 2 |  |
| 0xbb | 0x002a | ANGLE_0_0001_RAD_T | HEAD3 | 2 | avg(HEAD2) |
| 0xbc | 0x002a | ANGLE_0_0001_RAD_T | HEAD4 | 2 | avg(HEADING) |
| 0xbd | 0x002a | ANGLE_0_0001_RAD_T | HEAD5_MAG | 2 | avg(HEADING_MAG) |
| 0xbe | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T | SPEED_AVG | 2 | avg(SPEED) |
| 0xbf | 0x000e | LONG_DISTANCE_0_01_METRES_T | DEPTH_AVG | 4 | avg(DEPTH) |
| 0xc0 |  | reserved |  |  |  |
| 0xc1 | 0x002a | ANGLE_0_0001_RAD_T | COG2 | 2 |  |
| 0xc2 | 0x0054 | BOOL8 |  | 1 |  |
| 0xc3 |  | reserved | WP_HEADING3 |  |  |
| 0xc4 |  | reserved | WP_LATLON |  |  |
| 0xc5 |  |  | WP_NORTHEAST |  |  |
| 0xc8 |  | reserved |  |  |  |
| 0xcf |  |  | WP_LEG_DIST? |  |  |
| 0xd0 |  |  | WP_TIME |  |  |
| 0xd2..0xd7 |  | reserved |  |  |  |
| 0xd8 | 0x00af | WAYPOINT_NAME_T | WP_NAME | var |  |
| 0xdf | 0x0004 | TIME_0_0001_SECONDS_T | TIME3 | 4 |  |
| 0xe0 | 0x0054 | BOOL8 |  | 1 |  |
| 0xe5 | 0x0054 | BOOL8 |  | 1 |  |
| 0xe6..0xe9 | 0x00c0 | UINT8 |  | 1 |  |
| 0xec | 0x0054 | BOOL8 |  | 1 |  |
| 0xee | 0x0004 | TIME_0_0001_SECONDS_T | TIME4 | 4 |  |
| 0xef | 0x0003 | DATE_T | DATE2 | 2 |  |
| 0xf0 | 0x0054 | BOOL8 |  | 1 |  |
| 0xf2 | 0x002a | ANGLE_0_0001_RAD_T | SET_AVG | 2 | avg(SET) |
| 0xf3 | 0x002a | ANGLE_0_0001_RAD_T | SET_MAG_AVG | 2 | avg(SET_MAG) |
| 0xf4 | 0x0001 | SPEED_0_01_METRES_PER_SECOND_T |  | 2 | avg(DRIFT) |
| 0xf5 | 0x00ca | POSITION_SOURCE_T |  | 1 |  |
| 0xf7 |  | reserved |  |  |  |
| 0xf8 | 0x00d4 | FUEL_ECONOMY_METRES_PER_LITRE_T |  | 4 |  |
| 0xf9 | 0x000d | DISTANCE_METRES_T |  | 4 |  |
| 0xfa | 0x00d3 | VOLUME_0_1_LITRE_T | TOTAL_FUEL | 4 |  |
| 0xfb..0xfd |  | reserved |  |  |  |
| 0xff | 0x00d3 | VOLUME_0_1_LITRE_T | FUEL_CAPACITY2 | 4 |  |
| 0x101 | 0x0078 | GPS_DIFF_SATS_ENABLED_PRN_MAP_T |  | 4 |  |
| 0x102 | 0x0054 | BOOL8 |  | 1 |  |
| 0x104..0x108 | 0x000d | DISTANCE_METRES_T |  | 4 |  |
| 0x114 | 0x00a7 | PERCENT_T |  | 1 |  |
| 0x12a..0x133 | 0x0054 | BOOL8 |  | 1 |  |
| 0x134 |  | reserved |  |  |  |
| 0x135 | 0x00d3 | VOLUME_0_1_LITRE_T |  | 4 |  |
| 0x136 |  | reserved |  |  |  |
| 0x13a | 0x010b | WAYPOINT_SEQUENCE_ID_T |  | 2 |  |
| 0x13c |  | reserved |  |  |  |
| 0x144 | 0x0072 | WAYPOINT_ID_T |  | var |  |
| 0x145 | 0x010c | WAYPOINT_NUMBER_T |  | 2 |  |

- **ENC** -- the 16-bit decode-type id the firmware binds to the FID,
  shown as its full value; the high bit (`0x8000`) marks a signed
  encoding. `0x0000` is a *real* binding (encoding id `0`, SPEED_0_1), not
  "missing". A blank ENC is either a `reserved` slot or a FID known only
  from wire observation (see ENC type).
- **ENC type** -- the firmware's RTTI decode-type name, namespace prefix
  removed (e.g. `INSTRUMENTS::ANGLE_0_0001_RAD_T` ->
  `ANGLE_0_0001_RAD_T`); the full encoding is catalogued in
  [DB_DECODE](DB_DECODE.md). **`reserved`** marks a registered FID slot to
  which no source statically binds a decode type -- if a runtime source
  ever feeds it, the type comes from that source. A blank ENC type beside
  a Name is a `d_DB` wire-label the static map does not place (a candidate
  for a later code pass).
- **bytes** -- the wire width of the encoded value; `var` marks a
  variable-width packed struct.
- **Name** -- the per-source meaning where resolved (`d_DB`); blank where
  only the encoding is known.
- **source** -- shown only where the firmware itself is the deterministic
  single producer: the averaging-registrar FIDs, each the running average
  of a named source FID (`avg(SOURCE)`). For every other FID the producing
  source is a runtime, last-writer-wins property of the live record, not a
  fixed attribute of the FID; that provenance is described in
  [DATABASE](DATABASE.md).

## Application FIDs

The other half is the application namespaces -- the unit's persistent
settings (system, units, display, integration, alarms, navtex, and
engine in `0x01`; fishfinder in `0x03`; chart and cartography in `0x05`;
3D chart in `0x06`). These never broadcast, but they read and write
point-to-point over the stock protocol (QUERY and SetItem; see
[DATABASE](DATABASE.md)), which is what makes no-modification
configuration control meaningful: the table says what each writable FID
*is*. The proof case: `0x05000087` (Record Vessel Track By) was read,
written Auto<->Time, and confirmed on the unit's Chart Setup menu,
entirely over the stock wire.

Two no-modification sources build the table: the **ENC type** comes from
a QUERY of the FID (the registry decode type); the **menu**, **setting**,
and **value** come from the firmware's own English UI strings, laid out
per setup dialog. About 180 application FIDs are registered; roughly half
carry a setup-menu label, the rest are stored data records (packed
structs and internal state with no single UI label). Runs of consecutive
data-record FIDs that share an ENC are collapsed to a range, and the
Navtex message-category toggles are collapsed to a single row.

Two of the ENC-type values here are characterizations, not catalogue
names. **`packed struct`** marks a deliberate non-TDBItem id -- a packed
app-private record (chart state, fishfinder presets) whose layout the
producing app owns and for which the firmware declares no type-name.
**`untyped (unfed)`** marks a real config setting that has never been
written: its decode-type is latent, stamped into the item only on first
write, so a read of the untouched item returns no type. Both differ from
the instrument side's `reserved` (a slot with no binding at all), and
neither is recoverable from a static table walk -- the dialog builder
reorders fid-to-descriptor, so a positional read would mistype them.

| FID | menu | setting | ENC | ENC type | bytes | value |
|-----|------|---------|-----|----------|-------|-------|
| 0x0100008a-8c |  |  |  | untyped (unfed) |  |  |
| 0x0100008d |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01000145 |  |  | 0x00fc | packed struct | var |  |
| 0x01000146 |  |  | 0x00fd | packed struct | var |  |
| 0x01000147 |  |  | 0x0102 | packed struct | var |  |
| 0x01000148-4a |  |  |  | untyped (unfed) |  |  |
| 0x0100014b |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x0100015f |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01000160-61 |  |  | 0x0106 | G_SERIES_KEYBOARD_BACKLIGHT_CONTROL_T | 1 |  |
| 0x01010001 | System Setup | Position Mode | 0x0082 | WAYPOINT_POSITION_ENTRY_T | 1 | Lat/Long, TDs |
| 0x01010002 | System Setup | Simulator | 0x0083 | SIMULATOR_MODE_T | 1 | OFF, ON, DEMO |
| 0x01010003 | System Setup | Bearing Mode | 0x0084 | BEARING_MODE_T | 1 | Magnetic, True |
| 0x01010004 | System Setup | MOB Data Type | 0x0085 | MOB_DATA_TYPE_T | 1 | Dead Reckoning, Position |
| 0x01010005 | System Setup | Variation Source | 0x0086 | VARIATION_SOURCE_T | 1 | Auto, Manual |
| 0x01010006 | System Setup | Language | 0x0087 | LANGUAGE_T | 1 |  |
| 0x01010007 | Display Setup | Cursor Autohide | 0x0088 | CURSOR_READOUT_T | 1 |  |
| 0x01010008 |  |  | 0x0089 | CURSOR_REFERENCE_T | 1 |  |
| 0x01010009 | Units Setup | Distance Units | 0x008a | DISTANCE_UNITS_T | 1 | Nautical Miles, Statute Miles, Kilometres |
| 0x0101000a | Units Setup | Speed Units | 0x008b | SPEED_UNITS_T | 1 | Knots, kph, mph |
| 0x0101000b | Units Setup | Temperature Units | 0x008c | TEMPERATURE_UNITS_T | 1 | Fahrenheit, Celsius |
| 0x0101000c | Units Setup | Depth Units | 0x008d | DEPTH_UNITS_T | 1 | Feet, Metres, Fathoms |
| 0x0101000d | Date/Time Setup | Date Format | 0x008e | DATE_FORMAT_T | 1 | dd/mm/yy, mm/dd/yy |
| 0x0101000e | Date/Time Setup | Time Format | 0x008f | TIME_FORMAT_T | 1 | 12hr, 24hr |
| 0x0101000f | Date/Time Setup | Time Offset | 0x0090 | TIME_OFFSET_T | 1 | UTC, Local |
| 0x01010010 | System Integration Setup | Autopilot Control | 0x00a4 | MMI_AUTOPILOT_CONTROL_MODE_T | 1 |  |
| 0x01010011 | System Integration Setup | DSC Message | 0x00a5 | DSC_MESSAGES_MODE_T | 1 |  |
| 0x01010012 | System Integration Setup | Seatalk Alarms | 0x00a6 | SEATALK_ALARMS_MODE_T | 1 |  |
| 0x01010014 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010015 |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x01010016 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010017 |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x01010018 | Alarm Setup | Temperature Alarm | 0x0054 | BOOL8 | 1 |  |
| 0x01010019 | Alarm Setup | Temperature Alarm Limits | 0x0098 | TEMPERATURE_ALARM_LIMITS_T | 1 | INSIDE, OUTSIDE |
| 0x0101001a | Alarm Setup | Lower Temperature Limit | 0x0012 | TEMPERATURE_0_01_KELVIN_T | 2 |  |
| 0x0101001b | Alarm Setup | Upper Temperature Limit | 0x0012 | TEMPERATURE_0_01_KELVIN_T | 2 |  |
| 0x0101001c |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x0101001d-1e |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x0101001f |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010020 |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x01010021-22 |  |  |  | untyped (unfed) |  |  |
| 0x01010023 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010024-25 |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x01010026 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010027 | Display Setup | Power Down / Seconds To Power Down | 0x0005 | TIME_SECONDS_T | 4 |  |
| 0x01010028 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010029 |  |  | 0x0005 | TIME_SECONDS_T | 4 |  |
| 0x0101002a |  |  |  | untyped (unfed) |  |  |
| 0x0101002b |  |  | 0x80a3 | GPS_DATUM_INDEX_T | 1 |  |
| 0x0101002c | System Setup | Extended Character Set | 0x0054 | BOOL8 | 1 |  |
| 0x0101002d |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x0101002e |  |  | 0x000e | LONG_DISTANCE_0_01_METRES_T | 4 |  |
| 0x0101002f | System Setup | Manual Variation | 0x806c | SIGNED_ANGLE_0_1_DEG_T | 2 |  |
| 0x01010031 | Units Setup | Pressure Units | 0x00da | PRESSURE_UNITS_T | 1 | Bar, PSI, Kilopascals, mm of Water |
| 0x01010032 | Units Setup | Volume Units | 0x00db | VOLUME_UNITS_T | 1 | US Gallons, Imp Gallons, Litres |
| 0x01010033 | Engine Monitoring Setup | Alternator Voltage Range | 0x00dc | ALTERNATOR_VOLTAGE_RANGE_T | 1 |  |
| 0x01010034 | Engine Monitoring Setup | Maximum tachometer range | 0x00dd | ENGINE_REV_LIMIT_T | 1 | Auto, 3000rpm, 4000rpm, 5000rpm, 6000rpm, 7000rpm, 8000rpm |
| 0x01010036 | Engine Monitoring Setup | Number of Engines | 0x00ec | NUMBER_OF_ENGINES_T | 1 |  |
| 0x01010037 |  |  |  | untyped (unfed) |  |  |
| 0x01010038 |  |  | 0x000d | DISTANCE_METRES_T | 4 |  |
| 0x01010039 |  |  | 0x0005 | TIME_SECONDS_T | 4 |  |
| 0x0101003b | Chart Setup | Vector Length | 0x00f3 | VECTOR_LENGTH_T | var |  |
| 0x0101003c |  |  | 0x00f4 | HISTORY_LENGTH_T | var |  |
| 0x0101003d | Engine Monitoring Setup | Number of Gensets | 0x00fb | NUMBER_OF_GENSETS_T | 1 |  |
| 0x01010077 | System Integration Setup | Bridge NMEA Heading | 0x00c2 | BRIDGE_NMEA_HEADING_MODE_T | 1 |  |
| 0x010100c8 | System Setup | Chain | 0x00ba | TD_CHAIN_T | 1 |  |
| 0x010100c9 | System Setup | Slave 1 | 0x00bb | TD_SLAVE_T | 1 |  |
| 0x010100ca | System Setup | Slave 2 | 0x00bc | TD_SLAVE_T | 1 |  |
| 0x010100cb | System Setup | ASF 1 | 0x00bd | TD_ASF_T | 1 |  |
| 0x010100cc | System Setup | ASF 2 | 0x00be | TD_ASF_T | 1 |  |
| 0x010100d0-d1 |  |  | 0x00e5 | packed struct | var |  |
| 0x0101012c-3c | Navtex Setup | Message categories A-Z (17 toggles) | 0x0054 | BOOL8 | 1 | per-category on/off |
| 0x0101013d |  |  | 0x00ee | AIS_TARGET_TYPE_DISPLAY_OPTION_T | 1 |  |
| 0x0101013e |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010140 |  |  | 0x00c0 | UINT8 | 1 |  |
| 0x01010141-42 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010143 | Databar Setup | Compass Bar Mode | 0x00f6 | COMPASS_BAR_MODE_T | 1 | OFF, Top, Side |
| 0x01010144 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x01010145-46 |  |  |  | untyped (unfed) |  |  |
| 0x01010147 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x03000001 | Fishfinder Setup | Scroll / Colour Threshold | 0x0103 | FISH_FINDER_COLOUR_THRESHOLD_T | 1 |  |
| 0x0300000a |  |  | 0x0109 | packed struct | var |  |
| 0x03000031 | Fishfinder Setup | Frequency 1 | 0x00ff | FISH_FINDER_PRESET_INDEX_T | 1 |  |
| 0x03000032-49 |  |  | 0x0100 | packed struct | var |  |
| 0x05000000-05 |  |  | 0x007b | packed struct | var |  |
| 0x05000064 | Chart Setup | Object Information | 0x00a9 | OBJECT_INFORMATION_T | 1 |  |
| 0x05000066 | Cartography Setup | Chart Text ? | 0x0054 | BOOL8 | 1 |  |
| 0x0500006a |  |  | 0x8027 | SIGNED_TIME_MINUTES_T | 2 |  |
| 0x0500006b |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x0500006c | Cartography Setup | Chart Display | 0x00ab | CHART_DISPLAY_T | 1 | Auto, Simple, Detailed, Extra Detailed |
| 0x0500006d | Cartography Setup | Chart Boundaries | 0x0054 | BOOL8 | 1 |  |
| 0x0500006e | Cartography Setup | Spot Soundings | 0x0054 | BOOL8 | 1 |  |
| 0x0500006f | Cartography Setup | Safety Contour | 0x00c5 | SAFETY_CONTOUR_T | 1 |  |
| 0x05000070 | Cartography Setup | Depth Contour | 0x00c6 | DEPTH_CONTOUR_T | 1 |  |
| 0x05000071 | Cartography Setup | Nav. Marks | 0x0054 | BOOL8 | 1 |  |
| 0x05000072 | Cartography Setup | Nav. Marks Symbols | 0x00ac | NAV_MARKS_SYMBOLS_T | 1 | International, US |
| 0x05000073 | Cartography Setup | Light Sectors | 0x0054 | BOOL8 | 1 |  |
| 0x05000074 | Cartography Setup | Caution & Routing Data | 0x0054 | BOOL8 | 1 |  |
| 0x05000075 | Cartography Setup | Marine Features | 0x0054 | BOOL8 | 1 |  |
| 0x05000076 | Cartography Setup | Land Features | 0x0054 | BOOL8 | 1 |  |
| 0x05000077 | Cartography Setup | Chart Grid | 0x0054 | BOOL8 | 1 |  |
| 0x05000078 | Chart Setup | Chart Offset... | 0x00cf | POSITION_OFFSET_VALUE_T | 1 | OFFSET, SET OFFSET..., CLEAR OFFSET, ADJUST N-S, ADJUST E-W |
| 0x05000079 |  |  |  | untyped (unfed) |  |  |
| 0x0500007a | Cartography Setup | Coloured Seabed Areas ? | 0x0054 | BOOL8 | 1 |  |
| 0x0500007b |  |  | 0x00e1 | BOAT_ICON_3D_T | 1 |  |
| 0x0500007c | Cartography Setup | Port Services ? | 0x0054 | BOOL8 | 1 |  |
| 0x0500007d | Cartography Setup | Business Services ? | 0x0054 | BOOL8 | 1 |  |
| 0x0500007e-80 |  |  | 0x0054 | BOOL8 | 1 |  |
| 0x05000081 | Cartography Setup | Aerial Photo Overlay | 0x00e2 | AERIAL_OVERLAY_T | 1 | On Land, On Land and Sea |
| 0x05000082 | Cartography Setup | Roads | 0x0054 | BOOL8 | 1 |  |
| 0x05000083 | Cartography Setup | Additional Wrecks | 0x0054 | BOOL8 | 1 |  |
| 0x05000084 |  |  |  | untyped (unfed) |  |  |
| 0x05000087 | Chart Setup | Record Vessel Track By | 0x00e6 | TRACK_RECORDING_METHOD_T | 1 | Auto, Time, Distance |
| 0x05000088 | Chart Setup | Track Interval (time) | 0x00e7 | TRACK_RECORDING_TIME_INTERVAL_T | 1 | 3 Mins., 6 Mins., Infinite |
| 0x05000089 | Chart Setup | Track Interval (distance) | 0x00e9 | TRACK_RECORDING_DISTANCE_INTERVAL_T | 1 |  |
| 0x0500008e | Cartography Setup | Background Colour | 0x00f1 | BACKGROUND_COLOR_T | 1 | White, Blue |
| 0x0500008f | Chart Setup | Vector Width | 0x00f5 | VECTOR_WIDTHS_T | 1 | Thin, Normal, Wide |
| 0x05000090 | Cartography Setup | Hide Rocks | 0x00fe | HIDE_ROCKS_T | 1 |  |
| 0x05000091 |  |  | 0x0104 | CHART_VIEW_DATA_VERSION_NUMBER_T | 1 |  |
| 0x05000093 | Chart Setup | Route Width | 0x010e | RTE_TRK_LEG_WIDTHS_T | 1 | Thin, Normal, Wide |
| 0x05ff0001 |  | mod003 timed-track toggle | 0x0054 | BOOL8 | 1 | absent/0 = timed (default), nonzero = stock |
| 0x06000001 | 3D Chart Setup | Vessel Size | 0x00f8 | BOAT_SIZE_3D_T | 1 | Tiny, Small, Medium, Large, Huge |
| 0x06000002 | 3D Chart Setup | Centre-of-View Indicator ? | 0x0054 | BOOL8 | 1 |  |
| 0x06000003 | 3D Chart Setup | Vessel Symbol ? | 0x0054 | BOOL8 | 1 |  |
| 0x06000004 | 3D Chart Setup | Sonar Overlay ? | 0x0054 | BOOL8 | 1 |  |
| 0x06000007 | 3D Chart Setup | Sonar Overlay History Duration (Minutes) ? | 0x00f8 | BOAT_SIZE_3D_T | 1 |  |

- **menu / setting** -- the Setup-menu dialog and the on-screen label,
  read from the firmware UI strings. A blank menu/setting is a stored
  data record with no menu item. A trailing `?` marks a sequence-inferred
  FID-to-label binding (the menu FIDs run sequentially but cross a gap
  there), not a directly confirmed link.
- **ENC / ENC type / bytes** -- as in the instrument table above.
  `packed struct` = a bound type-id with no firmware RTTI name (an
  app-private packed record). `untyped (unfed)` = a valid setting whose
  decode-type the firmware only materializes on first write.
- **value** -- the decoded value-set for an enumerated setting (the
  ordered option labels). A blank value is a non-enumerated quantity: a
  number, angle, temperature, duration, or text.

The one **non-factory** row above is `0x05ff0001` -- a project-minted toggle, added over
the stock protocol and read by [mod003](../deployment/mod003.md) to gate per-point
timed-track recording. It has no Setup-menu origin, so its menu column is blank.

## Empirical notes from the live QUERY sweep (temp/db_instrument_sweep.txt)
The sweep confirms d_DB ENC ids for the whole live set and surfaces a few d_DB %DB_FIELDS
NAME corrections to apply when building the full table:
- **0x7f**: d_DB calls it VMG_WIND, but it reads enc=98 (GPS_HDOP) + B=30 (GPS class) ->
  it is a GPS HDOP quantity, NOT VMG. Re-name.
- **0x55**: d_DB VMG_WIND, enc=32936 (SIGNED_SPEED_0_01) -- a signed speed (plausibly VMG;
  keep but mark signed).
- **0x1c** HEAD_MAYBE: enc=32785 (SIGNED_ANGLE_0_0001_RAD) -- a signed angle (consistent
  with the heading guess).
- **0xee/0xef** (TIME4/DATE3): B=12 (waypoint class) -> waypoint-ETA time/date, not the clock.
- **0xfa** TOTAL_FUEL: live A=10 (computed) -- confirms d_DB's "fuel total is computed" note;
  source = computed.
- Not currently fed (no record): the engine analog fids 0x21-0x26 (engine off) and the
  waypoint/route fids 0x66/67/69/6a/9c/b6/c3/c4/c5/cf/d0/d8 (no active nav) -- they exist in
  the registrar but only serialize when a source feeds them.

---

**Next:** [DB_DECODE](DB_DECODE.md) ...
