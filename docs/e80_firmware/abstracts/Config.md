# Config

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**[DB_FIDS](DB_FIDS.md)** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

**The E80's persistent screen-layout and panel configuration.** This document
describes the user-configurable display settings the E80 saves across power
cycles: the **page sets** the PAGE button cycles through, the **applications**
that occupy their windows, and the **data panels** that the Data, Engine
Monitor, and CDI applications subdivide into individual readouts. Page sets and
data panels are both saved on the unit and survive power cycles (see Panels
below, and [Architecture: configuration persistence](../architecture/persistence.md)).

This abstract is the *what* and the byte layout. The *how* -- the RayCom
component model, the class registry that turns a stored CLSID back into
running code at boot, and the schema-driven `\LOCAL\` persistence
framework these files are written through -- is documented in
[Architecture: persistence](../architecture/persistence.md).

## Page Sets

### What a page set is

The E80 presents its applications through **page sets**. There are
**five**: four pre-configured and named -- **Navigation**, **Situational
Awareness**, **Boat Systems**, and **Fishing** -- plus one initially
empty **Custom** set. Each page set contains exactly **five pages**, and
each page is divided into **one to four windows**. Every window shows a
single **application** (chart, radar, fishfinder, and so on). A page set
is a local, per-unit setting; it does not propagate across a networked
group of displays.

The PAGE button cycles through the pages of the active set; pressing and
holding it opens the set-selection screen. An individual page can be
switched off, in which case it is skipped while cycling.

### Page layouts

How a page is divided into windows is described by a short **layout
string** built from the four screen quadrants. The quadrants are
numbered **clockwise**: 1 = top-left, 2 = top-right, 3 = bottom-right,
4 = bottom-left. A layout string lists the windows separated by colons;
each window is the set of quadrants it spans (merged). The six layouts
the unit uses:

| Layout string | Windows | Arrangement                                |
| ------------- | ------- | ------------------------------------------ |
| "1234"        | 1       | single full-page window                    |
| "14:23"       | 2       | left / right (a vertical split)            |
| "12:34"       | 2       | top / bottom (a horizontal split)          |
| "1:2:3:4"     | 4       | four quadrants                             |
| "14:2:3"      | 3       | full-height left, two stacked on the right |
| "1:2:34"      | 3       | two on top, full-width bottom              |

### The five default page sets

When the unit is first used -- or whenever its stored configuration is
missing or fails its validity check -- it builds the five sets from a
built-in factory template, saves them, and from then on loads and edits
the saved copies. The factory page layouts are:

| Page set              | Page 1 | Page 2 | Page 3 | Page 4 | Page 5 |
| --------------------- | ------ | ------ | ------ | ------ | ------ |
| Navigation            | full   | full   | L/R    | L/R    | L/R    |
| Situational Awareness | L/R    | L/R    | L+2R   | L+2R   | L/R    |
| Boat Systems          | full   | T/B    | full   | full   | L+2R   |
| Fishing               | full   | L/R    | 2T+B   | T/B    | L/R    |
| Custom                | full   | T/B    | L/R    | quad   | 2T+B   |

Layout key: **full** = one full-page window; **L/R** = left/right split;
**T/B** = top/bottom split; **quad** = four quadrants; **L+2R** =
full-height left plus two stacked on the right; **2T+B** = two on top
plus a full-width bottom. Which application fills each window is given by
an application ID (see the App IDs section).

### Lifecycle and storage

The factory defaults are written once, on first use (or when the stored
copy is missing or invalid), and saved to the unit's internal flash.
After that the unit always loads the saved copies; editing a page set
re-saves it. The window layouts, the application assignments, and the
active-page selection are therefore all persistent across power cycles.

The page sets live on the unit's **internal flash file system**, which
is distinct from the CompactFlash card exposed by the FILESYS network
service -- the page-set files are not reachable through FILESYS. All of
CMainApp's persistent state is serialized into a **single consolidated
file**, `\local\slotless\CMainApp0.lp` (3009 bytes), with the items
packed in schema order:

```
offset 0x000  Main App Persistence Version    (4 B)
offset 0x004  Active Page Set                 (4 B -- index 0..4 of the active set)
offset 0x008  Navigation Page Set             (600 B)
offset 0x260  Situational Awareness Page Set  (600 B)
offset 0x4b8  Boat Systems Page Set           (600 B)
offset 0x710  Fishing Page Set                (600 B)
offset 0x968  Custom Page Set                 (600 B)
offset 0xbc0  Databar Present                 (1 B)
```

The page-set *bodies* are the 600-byte slices inside that blob (the
600-byte block layout is detailed below). The blob has been read back
remotely and decoded field-by-field, matching the on-screen layouts
byte-for-byte. A separate, empty `Custom Page Set.lp` (0 sectors) also
appears in `\local\slotless\` -- a firmware-encoded STAT query-stub for a
legacy per-slot path, **not** the page-set storage (see
[Architecture: persistence](../architecture/persistence.md)).

### The 600-byte page-set block

Each page-set block is a fixed **600 bytes** (0x258). The block is
five 112-byte page records followed by a small set-level trailer:

| Bytes (hex)   | Bytes (dec) | Size | Status  | Contents                                              |
| ------------- | ----------- | ---- | ------- | ----------------------------------------------------- |
| 0x000 - 0x22F | 0 - 559     | 560  | Known   | Five page records, 112 bytes each (one per page)      |
| 0x230 - 0x233 | 560 - 563   | 4    | Partial | A page-index value for the set (the active page); 0 by default |
| 0x234 - 0x237 | 564 - 567   | 4    | Known   | This page set's ID (0 - 4)                            |
| 0x238 - 0x250 | 568 - 592   | 25   | Known   | The page set's name, as text (e.g. "Navigation")      |
| 0x251 - 0x253 | 593 - 595   | 3    | Known   | Padding                                               |
| 0x254 - 0x257 | 596 - 599   | 4    | Known   | Identifier of the built-in default name for the set   |

Each **page record** is 112 bytes (0x70). Offsets below are relative to
the start of the record:

| Bytes (hex) | Size | Status  | Contents                                                                        |
| ----------- | ---- | ------- | ------------------------------------------------------------------------------- |
| 0x00 - 0x0B | 12   | Known   | Layout string (text), e.g. "14:23" -- how this page is split into windows       |
| 0x0C - 0x17 | 12   | Unknown | Not yet determined (zero in the factory defaults)                               |
| 0x18 - 0x1B | 4    | Known   | Number of windows on this page (0 - 4)                                          |
| 0x1C - 0x5B | 64   | Known   | Four 16-byte window slots, one per window in layout-string order; each holds the assigned application's **16-byte CLSID GUID**. At build time the factory resolves the small application ID (below) to this CLSID and writes it here; the CLSID is what persists. (See "How the application ID resolves to a class" below.) |
| 0x5C - 0x6B | 16   | Unknown | Not yet determined                                                              |
| 0x6C        | 1    | Known   | Page-enabled flag; a disabled page is skipped when cycling                      |
| 0x6D - 0x6F | 3    | Unknown | Not yet determined                                                              |

## App IDs

Each window in a page set names its application by a small integer
**application ID**. The same applications appear on the unit's Select
Application screen. The table pairs each ID with the **visible name**
shown on the unit and, where established, the firmware **application
class**.

The **CLSID** column is the application class's 16-byte GUID -- the
exact bytes a page-set window slot stores -- written as a 32-digit
hex stream in stored byte order.

| ID | Visible name | Application class | CLSID (16-byte GUID, hex)          | Notes                                        |
| -- | ------------ | ----------------- | ---------------------------------- | -------------------------------------------- |
| 0  | (none)       | --                | --                                 | empty / unassigned window                    |
| 1  | Chart        | ChartingApp       | `20d192f5f24cf649aeb6362397ba4fc3` |                                              |
| 2  | Radar        | RadarApp          | `4402a04264e3944cb91f075a35c4a7c7` |                                              |
| 3  | ---          | --                | --                                 | shown as a separator; not used in any default set |
| 4  | Data         | DataApp           | `c672ffe6e583ed4db309431281fa82e3` | hosts the recursive data panels (see Panels) |
| 5  | Video        | VideoApp          | `ea4c657044e67d4a90b83856220f9ddd` |                                              |
| 6  | CDI          | 3DChartApp        | `c753cb302caaeb4a90ee34e5ad7affb8` | label and behavior differ (see below)        |
| 7  | FishFinder   | FishFinderApp     | `8205c2766e9e1141800f524d832ae549` |                                              |
| 8  | 3DChart      | BathyChartApp     | `3d18f159966398438e5dadd4e1eda259` | label and behavior differ (see below)        |
| 9  | Engine       | EngineApp         | `c1d70afa70878d44af036e0fa894de7a` |                                              |
| 10 | Weather      | WeatherApp        | `72f839b9ab51244d887e766c61b38602` |                                              |

For two IDs the on-screen label and the application's actual behavior
diverge. **ID 6**, labeled "CDI" on the unit, presents a forward-looking
3D perspective view out the bow rather than a course-deviation
indicator. **ID 8**, labeled "3DChart" on the unit, presents a
bathymetric view. Note too that the text "3DChart" appears as ID 6's
application class and, separately, as ID 8's visible name -- the two
naming schemes are crossed for these entries.

### How the application ID resolves to a class

The small application ID is a **build-time index, not what is stored**.
When the factory template is expanded, the builder
(`CMainApp_buildPageSetFromTemplate`) hands each window's application ID
to the system class registry -- `CHSBClassInformation`, through its
`IClassInformation` interface (CLSID and IID are adjacent GUIDs at
`0x00e6478c` / `0x00e6479c`). The registry's resolver
(`CHSBClassInformation_getClsidByAppType`, the interface's vmethod at
offset 0x54) walks its table of registered classes, finds the one whose
registered application-type field matches the ID, and writes that
class's **16-byte CLSID GUID** into the window slot. From then on the
slot -- and the saved page-set file -- carries the CLSID, and the
application ID is no longer needed. The empty Custom set leaves its
windows unassigned (application ID 0, no CLSID written).

This is why the boot process can rebuild every page set from flash with
no template: each saved window slot already names its application by
CLSID, which the registry maps straight back to a class.

The resolver is `CHSBClassInformation_getClsidByAppType` (the
`IClassInformation` interface's vmethod at offset 0x54); its inverse,
`CHSBClassInformation_getAppTypeAndNameByClsid`, maps a CLSID back to its
application-type ID and internal name. Each app is described by a 36-byte
class-info record `{CLSID pointer, ..., appType (+0x1C), name pointer
(+0x20)}`. Reading those records gives the **firmware-authoritative**
mapping below -- the registry's own internal class name for each id,
which confirms the device-observed enum. (The CLSIDs themselves are the
hex column of the App IDs table above.)

| ID | Internal name    | Visible name |
| -- | ---------------- | ------------ |
| 1  | chart            | Chart        |
| 2  | radar            | Radar        |
| 4  | InstrumentApp    | Data         |
| 5  | Video            | Video        |
| 6  | CDIApplication   | CDI          |
| 7  | Sonar            | FishFinder   |
| 8  | Bathy            | 3DChart      |
| 9  | Engine           | Engine       |
| 10 | Weather          | Weather      |

ID 3 (the "---" separator) has no class-info record at all -- confirming
it is never a usable application. ID 0 is the empty/unassigned window.
The Data, CDI and Engine records are contiguous in memory: these three
are the panel-hosting applications (see Panels) that share the
`CInstrumentationApplicationBase` implementation.

The registry itself, and how a stored CLSID is resolved back to a class
at boot, is described in
[Architecture: persistence](../architecture/persistence.md) (section 2,
"The class registry").

To decode a saved page set, then, the procedure is mechanical: read each
112-byte page record, take its layout string and its four 16-byte window
slots, and match each non-zero slot against the CLSID column of the App
IDs table above. No template and no running device are needed -- the file
is self-describing down to the GUID.

## Panels

### What a panel is, and which applications have them

Three applications display **panels** of configurable readouts rather
than a fixed view: the **Data** application (ID 4), the **Engine
Monitor** (ID 9), and the **CDI** (ID 6). They share one common
implementation -- in the firmware all three derive from a single base
class, `CInstrumentationApplicationBase` -- which is why the manual
documents panel customization once (Ch. 8) and notes it "also" applies
to the Engine Monitor and CDI applications.

Each such application owns a small set of selectable **panels** (the
firmware interface is `IPanelSet`). The soft keys let the user pick
which panel is shown; each panel can be renamed (firmware
`CInstrumentPanelRenameDialog`). The pre-configured panel *types*
differ per application -- for the Data app the manual lists Navigation,
Waypoint, Route, Fishing and Sailing; for the Engine Monitor, Engine,
Engine & Fuel, Fuel resources, Engine & resources and Multi-engine.

### The application object and its interfaces

The three panel hosts are the three contiguous registry entries noted in
App IDs: application ID **4** (`InstrumentApp`, the Data application),
**6** (`CDIApplication`), and **9** (`Engine`) -- their CLSIDs are the
bytes that land in a page-set window slot when one of them is placed
(see Application CLSIDs above). All three are instances of the same
~3 KB C++ object built on `CInstrumentationApplicationBase`.

That object advertises its capabilities the COM way: it carries a
**QueryInterface map** of sixteen `{ interface-IID, sub-object-offset }`
entries -- the list of interfaces it implements. (This is a capability
table, *not* a description of stored data; mistaking the one for the
other is an easy trap, since both are tables of GUIDs.) The interfaces
name the application's machinery cleanly:

- `IPanelSet` -- the collection of selectable panels.
- `IInstrumentGridMergeAndSplitCallbacks` -- the SPLIT/MERGE cell
  operations.
- `IInstrumentApplicationGridSizes` -- the grid-dimension ladder
  (below).
- `IInstrumentManager`, `IInstrumentApplicationConfiguration`,
  `INewInstrumentApplicationConfiguration` -- panel/cell configuration.
- `IRayApplicationSetup`, `IRayAppProperties`, `IObserverSink` -- the
  generic application-framework interfaces every app carries.

The sixteen raw IIDs are recorded in the project notes; pairing each
remaining one to its interface name is the kind of detail this abstract
deliberately leaves below it.

### The cell grid

A panel is a **grid of cells**, and the grid is not free-form: its
dimensions come from a fixed ladder of presets held by the firmware
class `CInstrumentGridSizes` (the grid itself is `CInstrumentGrid`). The
preset table, read by `CInstrumentGridSizes_getDimensions(index,
orientation)`, is:

| Preset | Dimensions | Cells |
| ------ | ---------- | ----- |
| 0      | 1 x 1      | 1     |
| 1      | 1 x 2      | 2     |
| 2      | 2 x 2      | 4     |
| 3      | 2 x 4      | 8     |
| 4      | 4 x 4      | 16    |

The orientation argument transposes a preset (so 1 x 2 also serves as
2 x 1, and 2 x 4 as 4 x 2). The maximum resolution is therefore **4 x 4
= 16 cells**. This is the direct analogue of the page-set quadrant model
(which is fixed at 2 x 2), one resolution finer.

The user reshapes the grid through the interface
`IInstrumentGridMergeAndSplitCallbacks`:

- **SPLIT CELL** -- divide one cell into two, horizontally or
  vertically (the offered direction is shown on the soft key).
- **MERGE CELLS** -- the inverse, combining a cell with its neighbor.

Split and merge move a cell within the grid (a cell may span more than
one grid unit, exactly as a page-set window spans merged quadrants);
each leaf cell carries one data readout.

### Cell data and display format

Each cell is bound, through the firmware class `CInstrumentDataSource`,
to one **field type** from the instrument database. The field type is
the quantity itself; the full catalogue of them is the **Field Types**
section below, and the menu path that selects one (data group, then
item) is described there.

Within a cell, the chosen field is shown in a **display format**
appropriate to it: numeric, digits, gauge, or graphical, and for the
graph formats a time interval (1 s, 10 s, 1 min, 5 min). The manual's
example is Heading shown as a numeric bearing or as a graphical compass.
The format is a per-cell choice layered over the field type; the numeric
values of the format enumeration are string-resource-backed and were not
recovered from the static image.

### Persistence

The instrument applications persist in **two parts**. Their `\LOCAL`
named-file schema contains a **single** item -- the active-panel index, written
**per window** in a slot dir keyed by `{page set, page, window}`:

```
\local\slot<PSPGWW>\CInstrumentatio0.lp   (1 byte = the "Current Panel" index)
```

That 1-byte item -- named for the base class `CInstrumentationApplicationBase`
(truncated) -- is the only instrument-application entry in the `\LOCAL`
*named-file* layer, and it is **per window**: several Data windows on one page
each keep their own selector even though they share a single panel record
(below). The byte is the data-panel menu position; the values were characterized
on the device (2026-06): `0` = Navigation (the default, which writes **no** file),
`1` = Waypoint, `2` = Route, `4` = Sailing. The whole round-trip is proven --
writing `0x04` into one window's `CInstrumentatio0.lp` from outside the UI and
power-cycling brought that window up showing the Sailing panel.

The panel **layouts and cell contents** are not `\LOCAL` files: they persist as
a single **keyed record** in the flob store's by-key face -- one record per
application instance, the live ~3 KB heap object's recursive `CInstrumentGrid`
cells and per-cell `CInstrumentDataSource` bindings serialized whole. The
per-window selector and the shared panel record are **independent layers, and
both are needed to reproduce a screen**: a page set restored without the
selectors comes up with every instrument window defaulted to Navigation. The
keyed-store mechanism is
[Architecture: persistence](../architecture/persistence.md) (section 4, "the
keyed-object store").

Confirmed on the device (2026-06-01): a Data-panel customization (cell split,
data assignment) **survives a hard power-cut**, so panel layouts do persist --
they live in the Flob store, not a `\LOCAL` file. Each cell's data item is a
single **32-bit curated panel-item
code** at a fixed record slot (observed: Rudder = 16, Speed = 5), resolving to
a field type plus a display format through a runtime / string-resource-gated
registry. The panel record is **device-agnostic** -- only the Flob key carries
the owning unit's machine id -- so a panel-set blob can be copied between units
by re-keying. (Note: the application's 16-entry GUID table is its
COM **QueryInterface map** -- the list of interfaces it implements,
such as `IPanelSet` and `IInstrumentGridMergeAndSplitCallbacks` -- not a
table of serialized fields; it does not describe stored data.)

## Field Types

Every readout the unit can show in a data-panel cell, and every slot in
the data bar, draws from a single system-wide catalogue of **field
types** -- the instrument database. A field type *is* the quantity a
cell is bound to; the cell separately chooses a display *format*
(numeric, gauge, graphical), but that is orthogonal to the field itself.

### Anatomy of a field type

The firmware describes each field type with one template,
`TDBItem< unit-type, id, encoding >`, binding three things:

- a 16-bit **id** -- the stable identifier a cell or data-bar slot
  stores to name the field (13 = distance, 60 = position, and so on);
- a **unit-type** -- the physical meaning *and* the fixed-point scaling
  of the stored value (e.g. `SPEED_0_01_METRES_PER_SECOND`: the raw
  integer is in hundredths of a metre per second);
- an **encoding** -- how the value is stored and carried: a byte, short,
  or long (with signed variants), or a named packed structure for
  composite values such as a position.

The pairing of unit-type with a raw integer is what makes the database
self-describing. The stored number plus its unit-type fully determine
the physical quantity; the user's Units setup (knots vs mph, feet vs
metres) is purely a display-time conversion layered on top. Ids with bit
**0x8000** set are the signed variant of a quantity.

The complete enumeration -- **160 distinct ids** extracted from the
firmware's type metadata -- is given in full below, ordered by id. Read the names as the firmware
writes them: an `INSTRUMENTS::` entry is a measured value whose scaling
is embedded in its name (`SPEED_0_01_METRES_PER_SECOND` = hundredths of a
metre per second); a `PACKED_..._STRUCT` is a composite record carried
whole (a position, a GNSS fix, an NMEA sentence); a `UNITS::`,
`CHART_SETUP::` or similar entry is a setup enumeration; and the Encoding
column gives the stored width (byte / short / long, their signed
variants, or a named packed encoding). A few ids are reused by two
subsystems with different meanings (shown joined by `|`); every id with
bit 0x8000 set is the signed sibling of a quantity.

### The field-type catalogue

The complete enumeration -- **160 distinct ids**, each with its unit-type and
encoding -- is the same catalogue the [DB_DECODE](DB_DECODE.md) abstract carries (there
with hex, the DBNAV wire `type` value, and DBNAV decoder coverage per
row). The full table is not duplicated here. Representative rows:

| ID | Hex | Field type (unit-type) | Encoding |
| --- | --- | --- | --- |
| 1 | 0x0001 | INSTRUMENTS::SPEED_0_01_METRES_PER_SECOND | SHORT |
| 13 | 0x000d | INSTRUMENTS::DISTANCE_METRES | LONG |
| 42 | 0x002a | INSTRUMENTS::ANGLE_0_0001_RAD | SHORT |
| 60 | 0x003c | INSTRUMENT_DATA_ITEMS::PACKED_POSITION_STRUCT | POSITION |
| 175 | 0x00af | INSTRUMENTS::WAYPOINT_NAME | WAYPOINT_NAME |

Ids with bit **0x8000** set are the signed sibling of a quantity.

### Data groups


For selection, the user-facing items are organised into **data groups**
-- Vessel, Navigation, Depth, Environment, Wind, Time and Date, and
Engine (firmware `CInstrumentGroupSetupMenu` / `CInstrumentItemSetupMenu`).
The same grouping feeds the data bar. The group names are string-resource
ids rather than literal strings in the image, so the group-to-id
membership is taken from the manual and the device rather than recovered
statically; the field-type ids and their meanings beneath them, however,
are the firmware-exact catalogue above.

---


### Discovered \local\ directory tree

Although not specifically an abstract description, this is recorded here
in a high-level design document for easy reference.  What follows is
the first full directory listing of the /Local/ NOR (Flash) based filesystem
found:

Early (after factory reset) /local directory tree:

- slot000000\
  - RadarService0.lp          1
  - ChartingAppView255.lp     1
  - ChartingAppView0.lp       1
  - ChartingAppView1.lp       1
  - ChartingAppView2.lp       1
  - ChartingAppView3.lp       1
  - ChartingAppView4.lp       1
  - Custom Page Set.lp        0
  - ChartingAppView5.lp       3
  - MarpaTarget0-00.lp        1
  - CGeoAppView0.lp           1
- slotless\
  - Custom Page Set.lp        0
  - CDataBar0.lp              1
  - CSonarSetupMenu0.lp       1
  - CMainApp0.lp              6
  - CVideoSettings0.lp        1
  - CRadarDisplaySe0.lp       1
  - CNavtexDialog0.lp         1
  - CDisplaySetupMe0.lp       1
- slot040000\
  - RadarService0.lp          1
  - ChartingAppView255.lp     1
  - ChartingAppView0.lp       1
  - ChartingAppView1.lp       1
  - ChartingAppView2.lp       1
  - ChartingAppView3.lp       1
  - ChartingAppView4.lp       1
  - ChartingAppView5.lp       3
  - Custom Page Set.lp        0
  - CGeoAppView0.lp           1




**Next:** [Home (Abstracts)](readme.md) ...
