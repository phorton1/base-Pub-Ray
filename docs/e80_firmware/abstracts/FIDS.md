# FIDS

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**FIDS**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The semantic data dictionary the DATABASE/DBNAV protocol carries:
TDBItem type catalog, FID enumeration, encoding decisions. Peer of
DATABASE; the substantive content of what the protocol delivers.

FIDS is the semantic data dictionary that the DATABASE/DBNAV
protocol carries. A FID (field ID) identifies a per-source
instance -- "this engine's RPM", "the main compass's heading",
"the speed-through-water reading from the speed sensor." A FID
alone tells you which source supplies a value; it doesn't tell
you how to decode the bytes that follow. That second part -- the
semantic type -- is what the firmware uses internally to wire
together its instrument data system, and it is present on the
wire too, attached to every value the E80 broadcasts.

This doc is about that semantic-type system: what the firmware
knows about its own data items, how that knowledge is exposed on
the wire, and what Patrick can do with it on the `/raymarine/NET`
side.

## The firmware's data-dictionary vocabulary

The firmware uses C++ templates of the form
`TDBItem<T, (UINT16)N, S>` to instantiate its database items.
162 distinct instantiations exist as RTTI typeinfo strings in
the binary, each carrying three template parameters:

- **T** -- a self-documenting semantic type name. Examples:
  `INSTRUMENTS::SPEED_0_01_METRES_PER_SECOND_T`,
  `INSTRUMENTS::ANGLE_0_0001_RAD_T`,
  `INSTRUMENTS::TEMPERATURE_0_01_KELVIN_T`,
  `INSTRUMENT_DATA_ITEMS::PACKED_POSITION_STRUCT_T`. The
  encoding (units, scale, precision) and shape (scalar vs
  packed-struct) is encoded in the name.
- **N** -- a `(UINT16)` constant ranging 0..270 plus a sparse
  set of `0x80xx` values for SIGNED variants. The 0x8000 bit is
  the sign flag.
- **S** -- an encoding marker (`SHORT_STRING`, `LONG_STRING`,
  `POSITION_STRING`, `NO_CONVERSION`, etc.).

The full sorted list of 162 entries is the table later in this
document ("The firmware TYPE universe").

## The wrong guess and the right answer

The earliest hope was that the TDBItem N parameter would equal
Patrick's wire FID -- a complete FID-to-semantic-type
dictionary sitting right there in the binary. That hope was
wrong: cross-checking N values against known FIDs showed a clear
mismatch. For example, Patrick's FID 0x03 is SPEED, but TDBItem
N=3 is DATE. The two enumerations are independent.

The correspondence is one level over. **The 2-byte `type` field
in every TFieldRecord on the DBNAV wire IS the firmware's TDBItem
N value.** Patrick's `d_DBNAV.pm decode_field` already unpacks
this field via `unpack('Vvv', ...)` but has treated only the
FID as semantic -- the type has been available all along; it
just hadn't been recognized as the firmware's type tag.

The two dimensions are independent:

- The wire **FID** identifies WHICH source supplies the value
  (which engine, which compass, which wind sensor).
- The wire **TYPE** identifies HOW to decode the value (the
  encoding and units).

The firmware emits both on every broadcast record. The decoder
choice can be driven by the type field rather than guessed
per-fid.

## Patrick's decoder coverage

Of the 162 firmware semantic types:

- **24 types** have a Patrick-side decoder.
- **20 of those 24** are wired up to one or more of Patrick's
  existing FIDs (covering ~62 individual FIDs handled correctly).
- **4 types** have a decoder ready but no FIDs assigned --
  they'll start decoding correctly as soon as a fid of that type
  arrives on the wire.
- **138 types** have no decoder.

The majority of the gap is `PACKED_*_STRUCT` types (GPS / GNSS /
DGNSS / autopilot / trip-parameters / etc.) and BYTE-encoded
enums (settings, modes, unit selectors, chart-display switches).
The scalar primitive gaps worth writing decoders for, when
interesting: FREQUENCY_1_HERTZ (183), FUEL_ECONOMY (212),
POSITION_PRECISION (153), CURRENT_0_1_AMPS (32793), and a few
SIGNED variants.

Examples of types Patrick's decoders correctly handle, by N:

```
N=0   SPEED_0_1_METRES_PER_SECOND       -> deciMetersPerSec
N=1   SPEED_0_01_METRES_PER_SECOND      -> centiMetersPerSec
N=3   DATE                              -> date
N=4   TIME_0_0001_SECONDS               -> time
N=13  DISTANCE_METRES                   -> distanceMeters
N=14  LONG_DISTANCE_0_01_METRES         -> depth/distanceCentiMeters
N=18  TEMPERATURE_0_01_KELVIN           -> kelvinOver100
N=19  TEMPERATURE_0_1_KELVIN            -> kelvinOver10
N=20  PRESSURE_100_PASCAL               -> millibarsToPSI
N=26  REVOLUTION_RATE_0_25_RPM          -> intWordOver4
N=42  ANGLE_0_0001_RAD                  -> heading
N=60  PACKED_POSITION_STRUCT            -> latLon
N=114 WAYPOINT_ID                       -> string
N=115 PACKED_MM_POSITION_STRUCT         -> northEast
N=175 WAYPOINT_NAME                     -> string15
N=211 VOLUME_0_1_LITRE                  -> deciLitresToGallons
```

The full 162-row table with Patrick's coverage per row follows
below, and is suitable for direct copy into a Perl hash.

## The firmware TYPE universe -- 162 entries, with coverage

Every `TDBItem<T, (UINT16)N, S>` the firmware names, sorted by N,
with a column for "does Patrick have a decoder for this type, and
which FIDs of his does that decoder currently handle." Names are
abbreviated (common prefixes like `INSTRUMENTS::`,
`INSTRUMENT_DATA_ITEMS::`, `UNITS::`, and the trailing `_T`
stripped).

| TYPE (dec) | hex   | Firmware T name | Encoding | Patrick decoder | Patrick FIDs |
|-----------:|-------|-----------------|----------|-----------------|--------------|
|     0 | 0x0000 | SPEED_0_1_METRES_PER_SECOND | SHORT | deciMetersPerSec | 0x58, 0x5a, 0x5c |
|     1 | 0x0001 | SPEED_0_01_METRES_PER_SECOND | SHORT | centiMetersPerSec | 0x03, 0x04, 0x19, 0x55, 0x7f, 0xb6, 0xbe |
|     3 | 0x0003 | DATE | SHORT | date | 0x13, 0xaa, 0xef |
|     4 | 0x0004 | TIME_0_0001_SECONDS | LONG | time | 0x12, 0x9c, 0xdf, 0xee |
|     5 | 0x0005 | TIME_SECONDS | LONG | seconds | 0xd0 |
|    13 | 0x000d | DISTANCE_METRES | LONG | distanceMeters | 0x07, 0x08, 0x6a, 0xcf |
|    14 | 0x000e | LONG_DISTANCE_0_01_METRES | LONG | depth/distanceCentiMeters | 0x09, 0x34, 0xbf |
|    18 | 0x0012 | TEMPERATURE_0_01_KELVIN | SHORT | kelvinOver100 | 0x24 |
|    19 | 0x0013 | TEMPERATURE_0_1_KELVIN | SHORT | kelvinOver10 | 0x22 |
|    20 | 0x0014 | PRESSURE_100_PASCAL | SHORT | millibarsToPSI | 0x21 |
|    26 | 0x001a | REVOLUTION_RATE_0_25_RPM | SHORT | intWordOver4 | 0x30 |
|    37 | 0x0025 | PASSWORD_TEXT | BYTE | --- | --- |
|    40 | 0x0028 | COMPASS_STATUS | BYTE | --- | --- |
|    42 | 0x002a | ANGLE_0_0001_RAD | SHORT | heading | 0x17, 0x18, 0x1a, 0x1c, 0x47, 0x48, 0x49, 0x59, 0x5b, 0x5d, 0x66, 0x67, 0x70, 0xba, 0xbb, 0xbc, 0xbd, 0xc1, 0xc3, 0xf2, 0xf3 |
|    43 | 0x002b | TRANSMISSION_GEAR | BYTE | --- | --- |
|    44 | 0x002c | ENGINE_DISCRETE_STATUS | SHORT | --- | --- |
|    45 | 0x002d | TRANSMISSION_DISCRETE_STATUS | BYTE | --- | --- |
|    46 | 0x002e | PACKED_TRIP_PARAMETERS_STRUCT | TRIP_PARAMETERS | --- | --- |
|    49 | 0x0031 | PACKED_BEARING_DISTANCE_BETWEEN_TWO_MARKS_STRUCT | BEARING_DISTANCE_BETWEEN_TWO_MARKS | --- | --- |
|    51 | 0x0033 | PACKED_TIME_TO_OR_FROM_MARK_STRUCT | TIME_TO_OR_FROM_MARK | --- | --- |
|    52 | 0x0034 | PACKED_DATUM_STRUCT | DATUM | --- | --- |
|    53 | 0x0035 | PACKED_DGNSS_CORRECTIONS_STRUCT | DGNSS_CORRECTIONS | --- | --- |
|    54 | 0x0036 | PACKED_GNSS_CONTROL_STATUS_STRUCT | GNSS_CONTROL_STATUS | --- | --- |
|    55 | 0x0037 | PACKED_GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_INTERFACE_STRUCT | GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_INTERFACE | --- | --- |
|    56 | 0x0038 | PACKED_GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_SIGNAL_STRUCT | GNSS_DIFFERENTIAL_CORRECTION_RECEIVER_SIGNAL | --- | --- |
|    57 | 0x0039 | PACKED_GNSS_DOPS_STRUCT | GNSS_DOPS | --- | --- |
|    58 | 0x003a | PACKED_GNSS_POSITION_DATA_STRUCT | GNSS_POSITION_DATA | --- | --- |
|    59 | 0x003b | PACKED_GNSS_RAIM_OUTPUT_STRUCT | GNSS_RAIM_OUTPUT | --- | --- |
|    60 | 0x003c | PACKED_POSITION_STRUCT | POSITION | latLon | 0x44, 0x99, 0xc4 |
|    61 | 0x003d | PACKED_NMEA2000_NAVIGATION_DATA_STRUCT | NMEA2000_NAVIGATION_DATA | --- | --- |
|    62 | 0x003e | PACKED_HEADING_TRACK_CONTROL_STRUCT | HEADING_TRACK_CONTROL | --- | --- |
|    67 | 0x0043 | PACKED_NMEA0183_BEARING_DISTANCE_TO_WAYPOINT_STRUCT | NMEA0183_BEARING_DISTANCE_TO_WAYPOINT | --- | --- |
|    70 | 0x0046 | PACKED_NMEA0183_RECOMMENDED_MINIMUM_NAVIGATION_INFO_STRUCT | NMEA0183_RECOMMENDED_MINIMUM_NAVIGATION_INFO | --- | --- |
|    71 | 0x0047 | PACKED_NMEA0183_AUTOPILOT_DATA_STRUCT | NMEA0183_AUTOPILOT_DATA | --- | --- |
|    74 | 0x004a | PACKED_NAV_MOVING_DATA_STRUCT | NAV_MOVING_DATA | --- | --- |
|    81 | 0x0051 | AVERAGE_SPEED_STATUS | BYTE | --- | --- |
|    82 | 0x0052 | ST2_AUTOPILOT_MODE_T / INSTRUMENTS::COURSE_COMPUTER_STATUS | LONG | --- | --- |
|    83 | 0x0053 | XTE_MODE | BYTE | --- | --- |
|    84 | 0x0054 | BOOL8 | BYTE | --- | --- |
|    85 | 0x0055 | DIRECTION_ORDER | BYTE | --- | --- |
|    86 | 0x0056 | COURSE_COMPUTER_RESPONSE_LEVEL | BYTE | --- | --- |
|    87 | 0x0057 | COURSE_COMPUTER_RUDDER_GAIN | BYTE | --- | --- |
|    90 | 0x005a | PACKED_GPS_SATELLITES_STRUCT | GPS_SATELLITES | --- | --- |
|    91 | 0x005b | PACKED_GPS_SATELLITES_IN_USE_STRUCT | GPS_SATELLITES_IN_USE | --- | --- |
|    93 | 0x005d | GPS_VISABLE_SATELLITE_COUNT | BYTE | --- | --- |
|    95 | 0x005f | GPS_ENABLE_DIFF | BYTE | --- | --- |
|    96 | 0x0060 | GPS_QUALITY_INDICATOR | BYTE | --- | --- |
|    97 | 0x0061 | GPS_USED_SATELLITE_COUNT | BYTE | --- | --- |
|    98 | 0x0062 | GPS_HDOP | SHORT | --- | --- |
|    99 | 0x0063 | GPS_ANTENNA_HEIGHT | SIGNED_LONG | --- | --- |
|   100 | 0x0064 | GPS_GEOIDAL_HEIGHT | SIGNED_LONG | --- | --- |
|   101 | 0x0065 | DGPS_AGE | SHORT | --- | --- |
|   102 | 0x0066 | DGPS_STATION_ID | SHORT | --- | --- |
|   103 | 0x0067 | PACKED_DGPS_DATA_STRUCT | DGPS_DATA | --- | --- |
|   104 | 0x0068 | PACKED_GPS_DIFF_SATS_STRUCT | GPS_DIFF_SATS | --- | --- |
|   105 | 0x0069 | GPS_SAT_DIFF_STATUS | BYTE | --- | --- |
|   113 | 0x0071 | MOB_STATE | BYTE | --- | --- |
|   114 | 0x0072 | WAYPOINT_ID | WAYPOINT_ID | string | 0x69 |
|   115 | 0x0073 | PACKED_MM_POSITION_STRUCT | MM_POSITION | northEast | 0x93, 0xc5 |
|   118 | 0x0076 | PACKED_GPS_FIXMODE_SMOOTHING_SETUP_STRUCT | GPS_FIXMODE_SMOOTHING_SETUP | --- | --- |
|   119 | 0x0077 | PACKED_GPS_USER_DATUM_SETUP_STRUCT | GPS_USER_DATUM_SETUP | --- | --- |
|   120 | 0x0078 | GPS_DIFF_SATS_ENABLED_PRN_MAP | LONG | --- | --- |
|   121 | 0x0079 | PACKED_UNIT_IDENTITY_STRUCT | UNIT_IDENTITY | --- | --- |
|   122 | 0x007a | DGPS_DIFF_SOURCE | BYTE | --- | --- |
|   128 | 0x0080 | GPS_OPERATING_MODE | BYTE | --- | --- |
|   129 | 0x0081 | GPS_FIX_MODE | BYTE | --- | --- |
|   130 | 0x0082 | WAYPOINT_POSITION_ENTRY | BYTE | --- | --- |
|   131 | 0x0083 | SIMULATOR_MODE | BYTE | --- | --- |
|   132 | 0x0084 | BEARING_MODE | BYTE | --- | --- |
|   133 | 0x0085 | MOB_DATA_TYPE | BYTE | --- | --- |
|   134 | 0x0086 | VARIATION_SOURCE | BYTE | --- | --- |
|   135 | 0x0087 | LANGUAGE | BYTE | --- | --- |
|   136 | 0x0088 | CURSOR_READOUT | BYTE | --- | --- |
|   137 | 0x0089 | CURSOR_REFERENCE | BYTE | --- | --- |
|   138 | 0x008a | DISTANCE_UNITS | BYTE | --- | --- |
|   139 | 0x008b | SPEED_UNITS | BYTE | --- | --- |
|   140 | 0x008c | TEMPERATURE_UNITS | BYTE | --- | --- |
|   141 | 0x008d | DEPTH_UNITS | BYTE | --- | --- |
|   142 | 0x008e | DATE_FORMAT | BYTE | --- | --- |
|   143 | 0x008f | TIME_FORMAT | BYTE | --- | --- |
|   144 | 0x0090 | TIME_OFFSET | BYTE | --- | --- |
|   145 | 0x0091 | TIME_0_0001_SECONDS | LONG | time (variant) | --- |
|   151 | 0x0097 | RACE_TIME_STATUS | BYTE | --- | --- |
|   152 | 0x0098 | TEMPERATURE_ALARM_LIMITS | BYTE | --- | --- |
|   153 | 0x0099 | POSITION_PRECISION | BYTE | --- | --- |
|   159 | 0x009f | PACKED_DSC_DISTRESS_DATA_STRUCT | DSC_DISTRESS_DATA | --- | --- |
|   160 | 0x00a0 | PACKED_COURSE_COMPUTER_RESPONSE_LEVEL_LIMITS_STRUCT | COURSE_COMPUTER_RESPONSE_LEVEL_LIMITS | --- | --- |
|   161 | 0x00a1 | PACKED_COURSE_COMPUTER_RUDDER_GAIN_LIMITS_STRUCT | COURSE_COMPUTER_RUDDER_GAIN_LIMITS | --- | --- |
|   164 | 0x00a4 | MMI_AUTOPILOT_CONTROL_MODE | BYTE | --- | --- |
|   165 | 0x00a5 | DSC_MESSAGES_MODE | BYTE | --- | --- |
|   166 | 0x00a6 | SEATALK_ALARMS_MODE | BYTE | --- | --- |
|   167 | 0x00a7 | PERCENT | BYTE | --- | --- |
|   169 | 0x00a9 | OBJECT_INFORMATION | BYTE | --- | --- |
|   171 | 0x00ab | CHART_DISPLAY | BYTE | --- | --- |
|   172 | 0x00ac | NAV_MARKS_SYMBOLS | BYTE | --- | --- |
|   173 | 0x00ad | SYMBOL | BYTE | --- | --- |
|   174 | 0x00ae | CALCULATION_TYPE | BYTE | --- | --- |
|   175 | 0x00af | WAYPOINT_NAME | WAYPOINT_NAME | string15 | 0xd8 |
|   177 | 0x00b1 | PACKED_LORAN_POSITION_STRUCT | LORAN_POSITION | --- | --- |
|   183 | 0x00b7 | FREQUENCY_1_HERTZ | LONG | --- | --- |
|   186 | 0x00ba | TD_CHAIN | BYTE | --- | --- |
|   187 | 0x00bb | TD_SLAVE | BYTE | --- | --- |
|   188 | 0x00bc | TD_SLAVE | BYTE | --- | --- |
|   189 | 0x00bd | TD_ASF | BYTE | --- | --- |
|   190 | 0x00be | TD_ASF | BYTE | --- | --- |
|   192 | 0x00c0 | UINT8 | BYTE | --- | --- |
|   194 | 0x00c2 | BRIDGE_NMEA_HEADING_MODE | BYTE | --- | --- |
|   197 | 0x00c5 | SAFETY_CONTOUR | BYTE | --- | --- |
|   198 | 0x00c6 | DEPTH_CONTOUR | BYTE | --- | --- |
|   202 | 0x00ca | POSITION_SOURCE | BYTE | --- | --- |
|   203 | 0x00cb | RADAR_SYSTEM_DATA | NO_CONVERSION | --- | --- |
|   207 | 0x00cf | POSITION_OFFSET_VALUE | BYTE | --- | --- |
|   209 | 0x00d1 | PHOTO_OVERLAY_VALUE | BYTE | --- | --- |
|   211 | 0x00d3 | VOLUME_0_1_LITRE | LONG | deciLitresToGallons | 0xfa, 0xff |
|   212 | 0x00d4 | FUEL_ECONOMY_METRES_PER_LITRE | LONG | --- | --- |
|   218 | 0x00da | PRESSURE_UNITS | BYTE | --- | --- |
|   219 | 0x00db | VOLUME_UNITS | BYTE | --- | --- |
|   220 | 0x00dc | ALTERNATOR_VOLTAGE_RANGE | BYTE | --- | --- |
|   221 | 0x00dd | ENGINE_REV_LIMIT | BYTE | --- | --- |
|   224 | 0x00e0 | RAY_GUID | LONG | --- | --- |
|   225 | 0x00e1 | BOAT_ICON_3D | BYTE | --- | --- |
|   226 | 0x00e2 | AERIAL_OVERLAY | BYTE | --- | --- |
|   227 | 0x00e3 | PACKED_BATHY_VIEW_LOCATOR_STRUCT | NO_CONVERSION | --- | --- |
|   228 | 0x00e4 | PACKED_BATHY_3D_SYNC_STRUCT | NO_CONVERSION | --- | --- |
|   230 | 0x00e6 | TRACK_RECORDING_METHOD | BYTE | --- | --- |
|   231 | 0x00e7 | TRACK_RECORDING_TIME_INTERVAL | BYTE | --- | --- |
|   233 | 0x00e9 | TRACK_RECORDING_DISTANCE_INTERVAL | BYTE | --- | --- |
|   236 | 0x00ec | NUMBER_OF_ENGINES | BYTE | --- | --- |
|   238 | 0x00ee | AIS_TARGET_TYPE_DISPLAY_OPTION | BYTE | --- | --- |
|   239 | 0x00ef | UINT32 | LONG | --- | --- |
|   241 | 0x00f1 | BACKGROUND_COLOR | BYTE | --- | --- |
|   243 | 0x00f3 | VECTOR_LENGTH | NO_CONVERSION | --- | --- |
|   244 | 0x00f4 | HISTORY_LENGTH | NO_CONVERSION | --- | --- |
|   245 | 0x00f5 | VECTOR_WIDTHS | BYTE | --- | --- |
|   246 | 0x00f6 | COMPASS_BAR_MODE | BYTE | --- | --- |
|   248 | 0x00f8 | BOAT_SIZE_3D_T / UINT32 | BYTE | --- | --- |
|   249 | 0x00f9 | ONAN_GENSET_STATUS | BYTE | --- | --- |
|   251 | 0x00fb | NUMBER_OF_GENSETS | BYTE | --- | --- |
|   254 | 0x00fe | HIDE_ROCKS | BYTE | --- | --- |
|   255 | 0x00ff | FISH_FINDER_PRESET_INDEX | BYTE | --- | --- |
|   259 | 0x0103 | FISH_FINDER_COLOUR_THRESHOLD | BYTE | --- | --- |
|   260 | 0x0104 | CHART_VIEW_DATA_VERSION_NUMBER | BYTE | --- | --- |
|   262 | 0x0106 | G_SERIES_KEYBOARD_BACKLIGHT_CONTROL | BYTE | --- | --- |
|   264 | 0x0108 | char | [6]  INSTRUMENT_DATA_ITEMS::NO_CONVERSION | --- | --- |
|   266 | 0x010a | TURN_SEVERITY | BYTE | --- | --- |
|   267 | 0x010b | WAYPOINT_SEQUENCE_ID | SHORT | --- | --- |
|   268 | 0x010c | WAYPOINT_NUMBER | SHORT | --- | --- |
|   270 | 0x010e | RTE_TRK_LEG_WIDTHS | BYTE | --- | --- |
| 32770 | 0x8002 | SIGNED_SPEED_0_001_METRES_PER_SECOND | SIGNED_SHORT | metersPerSec | --- |
| 32785 | 0x8011 | SIGNED_ANGLE_0_0001_RAD | SIGNED_SHORT | --- | --- |
| 32792 | 0x8018 | POTENTIAL_0_01_VOLTS | SHORT | wordOver100 | 0x25 |
| 32793 | 0x8019 | CURRENT_0_1_AMPS | SHORT | --- | --- |
| 32796 | 0x801c | VOLUME_RATE_0_0001_CUBIC_METRES_PER_HOUR | SHORT | deciLitresToGallons (rate) | 0x26 |
| 32797 | 0x801d | SIGNED_PERCENT | SIGNED_BYTE | --- | --- |
| 32798 | 0x801e | SIGNED_0_004_PERCENT | SIGNED_SHORT | wordOver250 | 0x32 |
| 32807 | 0x8027 | SIGNED_TIME_MINUTES | SIGNED_SHORT | --- | --- |
| 32876 | 0x806c | SIGNED_ANGLE_0_1_DEG | SHORT | --- | --- |
| 32931 | 0x80a3 | GPS_DATUM_INDEX | BYTE | --- | --- |
| 32936 | 0x80a8 | SIGNED_SPEED_0_01_METRES_PER_SECOND | SIGNED_SHORT | centiMetersPerSec (signed) | --- |
| 32963 | 0x80c3 | SIGNED_DISTANCE_0_001_METRES | SIGNED_SHORT | distanceDeciMeters? | --- |

## What this enables

Without further firmware work, `d_DBNAV.pm` can be enhanced today:

1. **Build a `%TDBI_TYPES` Perl hash** from the 162 typeinfo
   entries (one line per entry, N => "T name"). Each entry maps
   an N value to the firmware's own self-documenting type name.
2. **Surface the type alongside the decoded value.** The
   per-record log line for fid 0x17 would show
   `type=ANGLE_0_0001_RAD (N=42)` next to the current heading
   value, making unfamiliar fids self-documenting.
3. **Drive decoder selection by type.** Any fid whose wire type
   is N=42 gets the heading decoder; any N=1 gets the speed
   decoder; etc. Patrick's hand-curated `%DB_FIELDS` becomes a
   per-fid NAME table only; decoder choice unifies across all
   fids by type.

The benefit: observe unknown FIDs and immediately see their
semantic encoding, without needing to reverse-engineer each one.
The per-fid NAME (which engine instance, which wind sensor)
still requires identifying the data source -- but the
"what are these bytes" question is solved.

## The application config fids -- a settings datasheet

The fids above are the **instrument** half of the database -- live
measured values, broadcast on DBNAV. The other half is the
**application** namespaces: the unit's persistent settings, keyed by
fids whose top byte is 0x01 (system / units / display / integration /
alarms / navtex / engine), 0x03 (fishfinder), 0x05 (chart and
cartography), or 0x06 (3D chart). These never broadcast -- subscription
is namespace-gated to the instrument set -- but they **read and write
point-to-point** over the stock protocol (QUERY and SetItem; see
[DATABASE](DATABASE.md)). This datasheet is what makes that no-mod
config control meaningful: it says what each writable fid *is*.

Two no-mod sources build it, with no reverse engineering needed by a
consumer:

- **Type** -- a QUERY of the fid returns the item record whose
  `type-id` is the firmware semantic-type from the catalog above
  (e.g. `DEPTH_UNITS_T`, `TRACK_RECORDING_METHOD_T`, `BOOL8`).
- **Label and value-set** -- the firmware's own English UI strings,
  laid out per setup dialog, give the human label for each setting
  and, for enumerated settings, the ordered value labels.

About 180 application fids exist; ~90 carry a setup-menu label. The
rest are stored data records -- packed structs with no single UI label
(e.g. the sounder frequency-preset slots 0x03000032..49 and the
chart-state structs 0x05000000..05). The full named-settings datasheet,
ordered by fid and tagged with its setup area (a trailing **?** marks a
sequence-inferred fid<->label binding; a blank value column means a
non-enumerated quantity -- a number, angle, or text):

| fid | area | setting | type | values |
| --- | ---- | ------- | ---- | ------ |
| 0x01010001 | System | Position Mode | WAYPOINT_POSITION_ENTRY_T | Lat/Long, TDs |
| 0x01010002 | System | Simulator | SIMULATOR_MODE_T | OFF, ON, DEMO |
| 0x01010003 | System | Bearing Mode | BEARING_MODE_T | Magnetic, True |
| 0x01010004 | System | MOB Data Type | MOB_DATA_TYPE_T | Dead Reckoning, Position |
| 0x01010005 | System | Variation Source | VARIATION_SOURCE_T | Auto, Manual |
| 0x01010006 | System | Language | LANGUAGE_T | |
| 0x01010007 | Display | Cursor Autohide | CURSOR_READOUT_T | |
| 0x01010009 | Units | Distance Units | DISTANCE_UNITS_T | Nautical Miles, Statute Miles, Kilometres |
| 0x0101000a | Units | Speed Units | SPEED_UNITS_T | Knots, kph, mph |
| 0x0101000b | Units | Temperature Units | TEMPERATURE_UNITS_T | Fahrenheit, Celsius |
| 0x0101000c | Units | Depth Units | DEPTH_UNITS_T | Feet, Metres, Fathoms |
| 0x0101000d | Date/Time | Date Format | DATE_FORMAT_T | dd/mm/yy, mm/dd/yy |
| 0x0101000e | Date/Time | Time Format | TIME_FORMAT_T | 12hr, 24hr |
| 0x0101000f | Date/Time | Time Offset | TIME_OFFSET_T | UTC, Local |
| 0x01010010 | Integration | Autopilot Control | MMI_AUTOPILOT_CONTROL_MODE_T | |
| 0x01010011 | Integration | DSC Message | DSC_MESSAGES_MODE_T | |
| 0x01010012 | Integration | Seatalk Alarms | SEATALK_ALARMS_MODE_T | |
| 0x01010018 | Alarm | Temperature Alarm | BOOL8 | |
| 0x01010019 | Alarm | Temperature Alarm Limits | TEMPERATURE_ALARM_LIMITS_T | INSIDE, OUTSIDE |
| 0x0101001a | Alarm | Lower Temperature Limit | TEMPERATURE_0_01_KELVIN_T | |
| 0x0101001b | Alarm | Upper Temperature Limit | TEMPERATURE_0_01_KELVIN_T | |
| 0x01010027 | Display | Power Down (seconds) | TIME_SECONDS_T | |
| 0x0101002c | System | Extended Character Set | BOOL8 | |
| 0x0101002f | System | Manual Variation | SIGNED_ANGLE_0_1_DEG_T | |
| 0x01010031 | Units | Pressure Units | PRESSURE_UNITS_T | Bar, PSI, Kilopascals, mm of Water |
| 0x01010032 | Units | Volume Units | VOLUME_UNITS_T | US Gallons, Imp Gallons, Litres |
| 0x01010033 | Engine | Alternator Voltage Range | ALTERNATOR_VOLTAGE_RANGE_T | |
| 0x01010034 | Engine | Maximum tachometer range | ENGINE_REV_LIMIT_T | Auto, 3000-8000rpm |
| 0x01010036 | Engine | Number of Engines | NUMBER_OF_ENGINES_T | |
| 0x0101003b | Chart | Vector Length | VECTOR_LENGTH_T | |
| 0x0101003d | Engine | Number of Gensets | NUMBER_OF_GENSETS_T | |
| 0x01010077 | Integration | Bridge NMEA Heading | BRIDGE_NMEA_HEADING_MODE_T | |
| 0x010100c8 | System | Chain | TD_CHAIN_T | |
| 0x010100c9 | System | Slave 1 | TD_SLAVE_T | |
| 0x010100ca | System | Slave 2 | TD_SLAVE_T | |
| 0x010100cb | System | ASF 1 | TD_ASF_T | |
| 0x010100cc | System | ASF 2 | TD_ASF_T | |
| 0x0101012c..3c | Navtex | Message categories A-Z (17 toggles) | BOOL8 | per-category on/off |
| 0x01010143 | Databar | Compass Bar Mode | COMPASS_BAR_MODE_T | OFF, Top, Side |
| 0x03000001 | Fishfinder | Scroll / Colour Threshold | FISH_FINDER_COLOUR_THRESHOLD_T | |
| 0x03000031 | Fishfinder | Frequency 1 | FISH_FINDER_PRESET_INDEX_T | |
| 0x05000064 | Chart | Object Information | OBJECT_INFORMATION_T | |
| 0x05000066 | Cartography | Chart Text **?** | BOOL8 | |
| 0x0500006c | Cartography | Chart Display | CHART_DISPLAY_T | Auto, Simple, Detailed, Extra Detailed |
| 0x0500006d | Cartography | Chart Boundaries | BOOL8 | |
| 0x0500006e | Cartography | Spot Soundings | BOOL8 | |
| 0x0500006f | Cartography | Safety Contour | SAFETY_CONTOUR_T | |
| 0x05000070 | Cartography | Depth Contour | DEPTH_CONTOUR_T | |
| 0x05000071 | Cartography | Nav. Marks | BOOL8 | |
| 0x05000072 | Cartography | Nav. Marks Symbols | NAV_MARKS_SYMBOLS_T | International, US |
| 0x05000073 | Cartography | Light Sectors | BOOL8 | |
| 0x05000074 | Cartography | Caution & Routing Data | BOOL8 | |
| 0x05000075 | Cartography | Marine Features | BOOL8 | |
| 0x05000076 | Cartography | Land Features | BOOL8 | |
| 0x05000077 | Cartography | Chart Grid | BOOL8 | |
| 0x05000078 | Chart | Chart Offset... | POSITION_OFFSET_VALUE_T | OFFSET, SET OFFSET..., CLEAR OFFSET, ADJUST N-S, ADJUST E-W |
| 0x0500007a | Cartography | Coloured Seabed Areas **?** | BOOL8 | |
| 0x0500007c | Cartography | Port Services **?** | BOOL8 | |
| 0x0500007d | Cartography | Business Services **?** | BOOL8 | |
| 0x05000081 | Cartography | Aerial Photo Overlay | AERIAL_OVERLAY_T | On Land, On Land and Sea |
| 0x05000082 | Cartography | Roads | BOOL8 | |
| 0x05000083 | Cartography | Additional Wrecks | BOOL8 | |
| 0x05000087 | Chart | Record Vessel Track By | TRACK_RECORDING_METHOD_T | Auto, Time, Distance |
| 0x05000088 | Chart | Track Interval (time) | TRACK_RECORDING_TIME_INTERVAL_T | 3 Mins., 6 Mins., Infinite |
| 0x05000089 | Chart | Track Interval (distance) | TRACK_RECORDING_DISTANCE_INTERVAL_T | |
| 0x0500008e | Cartography | Background Colour | BACKGROUND_COLOR_T | White, Blue |
| 0x0500008f | Chart | Vector Width | VECTOR_WIDTHS_T | Thin, Normal, Wide |
| 0x05000090 | Cartography | Hide Rocks | HIDE_ROCKS_T | |
| 0x05000093 | Chart | Route Width | RTE_TRK_LEG_WIDTHS_T | Thin, Normal, Wide |
| 0x06000001 | 3D Chart | Vessel Size | BOAT_SIZE_3D_T | Tiny, Small, Medium, Large, Huge |
| 0x06000002 | 3D Chart | Centre-of-View Indicator **?** | BOOL8 | |
| 0x06000003 | 3D Chart | Vessel Symbol **?** | BOOL8 | |
| 0x06000004 | 3D Chart | Sonar Overlay **?** | BOOL8 | |
| 0x06000007 | 3D Chart | Sonar Overlay History Duration **?** | BOAT_SIZE_3D_T | |

A worked end-to-end example: `0x05000087` (Record Vessel Track By)
was read, written Auto<->Time, and confirmed on the unit's Chart
Setup menu -- entirely over the stock wire, the proof case for
[DATABASE](DATABASE.md)'s read/write/persist path.

## What's still open

The naming gap that remains is the **instrument** half: mapping each
instrument fid to its firmware-source name, so 0x21 becomes the
firmware's own ENG_OIL_PRESS1 rather than Patrick's invented label.
That did NOT yield to this dig -- the Source's "get value by fid"
lookup sits behind a service-locator indirection, and the instrument
fids don't appear as static integer constants the way the Source
constructor's auto-subscribe block does, so the registration is built
by code, not a table. Per-instrument-fid firmware-name surfacing
remains a future task; the type-driven decoding above doesn't depend
on it. (The application/config fids *are* named now -- see the
settings datasheet above.)

---

**Next:** [Home (Abstracts)](readme.md) ...
