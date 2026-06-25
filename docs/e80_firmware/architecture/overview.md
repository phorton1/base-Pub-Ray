# Overview of E80 Firmware

**[Architecture](readme.md)** --
**overview** --
**[runtime](runtime.md)** --
**[services](services.md)** --
**[instruments](instruments.md)** --
**[applications](applications.md)** --
**[persistence](persistence.md)**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

*The top-level structural picture of the E80 -- the device and the software it
runs -- distilled from four sources: the firmware (RTTI), the live
device (the mod001 channel + experiments), the E-Series manuals, and the author's
own twenty-year corpus (`/raymarine` protocol work + the FSH format; `/Boat`).
Aloof by design: it names the KINDS of thing and the ROLES they play, not
implementation classes or byte offsets. It is itself a source that can be wrong
-- not the arbiter of the docs beneath it.*

**Confidence.** An unmarked statement is **confirmed**. Marks flag the
exceptions: `[~]` inferred, `[?]` gap, `[!]` conflict not yet settled. Where a
fact is known from the manuals or the author's external work rather than the
firmware, it is noted in passing -- the architecture draws on all four sources
honestly.

---

## 1. What the E80 is (the crown)

The E80 is a **self-contained marine multifunction display** -- one of
Raymarine's *E-Series Networked Displays* (2006). With sensors attached it:

- **fuses** position, heading, depth, speed, wind, engine, and AIS data
  arriving over **four marine protocols** -- Seatalk1, NMEA 0183, NMEA 2000,
  and the ethernet **SeaTalkHS**;
- **networks** with peer E-Series displays through a SeaTalkHS switch, one unit
  acting as the **data master**;
- **presents** that world through ~11 applications -- Chart (Navionics), 3D
  Chart, Radar, Fishfinder, Data, Engine, CDI, Video, Weather, Navtex, AIS;
- is driven by a **fixed control panel** (PAGE, ACTIVE, WPTS, DATA, MOB, MENU,
  RANGE, OK, CANCEL) plus **soft-keys** and a **cursor**;
- **archives** the navigator's waypoints / routes / groups / tracks to a **CF
  card**, and keeps its settings in internal flash.

It is a functional thing a person owns and operates; the **application is its
soul**, and everything below exists to serve it. (Identity: the manuals.)

## 2. The shape: one frozen image, layered

The firmware is a single ARM image, frozen ~2006 and unchanging. Read
bottom-to-top it is three bands -- Raymarine's own code on top, the frameworks
it stands on in the middle, the chip and OS at the floor.

```
  ----- the Raymarine application (PROJECT) -----------------------------
   apps + services    the on-screen apps and the networked services
   instrument model   the unified data abstraction every consumer draws from
  ----- the frameworks it stands on (LIBRARY) ---------------------------
   CLNet     the networked-service pattern (the SeaTalkHS stack)
   RayCom    the object model -- classes, instances, interfaces, and a
             runtime registry that wires them together at boot
   PEG       graphics + windowing
   C++ STL   containers (the trees behind the indexes)
  ----- storage: a view over a store ------------------------------------
   named filesystem   a path-named VIEW of persisted objects ("\local")
   flob store         the bytes -- append-only flash-blobs (section 6)
  ----- the substrate (chip + OS) ---------------------------------------
   RTOS + filesystem  ThreadX + FileX + device drivers (NOR, CF, EEPROM)
   ARM32 CPU          little-endian; runs at address 0
```

The library banners name the real frameworks (ThreadX, FileX, PEG, the
InterNiche TCP/IP stack, the Dinkumware STL, zlib). RayCom's registry wires
objects **at runtime**, so those links are not in the image (section 8).

## 3. The heart: protocols -> instrument abstraction -> consumers

The architectural center is a **fusion**. Four protocol worlds feed **one
instrument-data abstraction**, and everything draws from that single model:

```
   Seatalk1 / NMEA0183 / NMEA2000 / SeaTalkHS
         |   (a sensor reading, whatever its wire)
         v
   instrument abstraction -- a local proxy per data source feeding a common
         |                   data-item model; a heading from a Seatalk compass
         |                   and a heading from an N2K sensor become the SAME
         v                   "data item"
   consumers: the apps, the data bar, the instrument panels, AND the networked
              services that re-broadcast it to peer displays
```

The firmware realizes this as a **proxy per source** (GPS, compass, autopilot,
AIS, radar, sonar, fishfinder-history, depth / speed / wind) over a common
data-source / data-item layer; the `/Boat` library mirrors it exactly
(Seatalk / 0183 / 2000 parsers feeding depth / wind / gps / compass / engine
instruments), and the pipeline has been **walked on the wire** -- a Seatalk or
N2K depth fed in appears both on the display and on the network broadcast.

## 4. The application (what's on the glass)

The display is three zones: a **data bar** (a few lines at the top, with a
status area), the **five soft-keys** (bottom), and the **Page** between them.

The application is organized **data-master -> page set -> page -> window ->
app**: five page sets, five pages each, 1-4 windows per page, one app per
window; one page set active, one of its pages shown. Three apps -- Data,
Engine, CDI ("instrument apps") -- fill their window with a **panel**: a grid
of up to 16 cells, each cell bound to one data item.

A real **configuration-UX layer** sits alongside: editing page sets, editing
panels (the configure-data / configure-panel applets), customizing the data
bar, and selecting data items through multi-tier setup menus and dialogs. (The
specific menus and dialogs are Design detail, not architecture.)

## 5. The networked services (the SeaTalkHS stack)

A large, uniform service family -- equal in weight to anything else here. Each
service is built from the same roles: a **server** (the listening endpoint), a
**source** (the client adapter), a **discovery descriptor** (what it
advertises), and -- for stateful services -- a **per-connection** state machine
on its own thread. Discovery is its own protocol (**RAYDP**): a unit advertises
what it hosts and listens for others, dispatching each to a factory. There is
no central dispatcher; each service runs its own threads.

The catalogue a unit serves includes **waypoints / routes / groups, tracks, the
navigation database** (with a live value broadcast), CF-card file access,
fishfinder history, navigation, GPS, autopilot, alarms -- plus radar / sonar
when the hardware is present. Most are read-and-subscribe; a **write path**
exists, proven end-to-end for tracks (a client uploads a track and the unit
stores and re-broadcasts it) and latent for waypoints and the database. Every
broadcast value carries both its **field type** (FID) and its **encoding type**
(ENC) from the firmware's own data dictionary. A unit consumes a few services it
never serves (blob storage, chart
data, newer radar) -- those it talks to only as a client.

## 6. Persistence: one flob model, two media

The persistence substrate is **one format on two media**. A **flob** store is
an append-only series of 64 KB flash-blobs holding **UUID-keyed records**; a
record is updated not by overwrite but by **appending a new copy and marking the
old one superseded** (an active flag). The current state is therefore the latest
live record per key, and the store is literally an archive of its own history.
Each key is an **owner word** (the unit's machine id) plus a **per-owner monotonic
counter** that only climbs and never reuses a value -- so any still-free value
below the unit's high-water mark is permanently safe for an external tool to place
a record at; the full key model is in [runtime](runtime.md).

That one model appears in two places:

- **Internal NOR flash**, seen through the path-named `\local` view -- the
  unit's **settings**: the consolidated page-set layouts; the instrument
  **panels** (each app's panel-set is a keyed record; a panel cell's binding is
  a single curated 32-bit item code); per-window view state under per-window
  **slots**; the data bar. Confirmed on the device -- a panel edit survives a
  hard power-cut.
- **The CF card**, as `ARCHIVE.FSH` -- the **navigator's data**: waypoints,
  routes, groups, tracks, as flob blocks. A managed archive subsystem
  (save / retrieve / erase, with per-type conflict resolution) writes it. (FSH
  format: the `/raymarine` corpus.)

The **WGRT** (waypoint / route / group / track) data is a **live object model in
RAM**, served by the waypoint / track / database services. It is **write-through to
the NOR flob store** -- the *same* `flobs.fsh` that holds the settings, confirmed by a
live read-by-key off the unit (a uniquely-named waypoint pulled back and decoded;
[runtime](runtime.md)) -- **and** producible as the CF `ARCHIVE.FSH` archive. One
object model, one flob format: the track and waypoint records on the wire, in NOR, and
in the CF archive are the **same records** `[~]`. `[! the live-vs-archive write topology
-- which writes land in NOR vs CF, and whether a large WGRT load stays within the 1.5 MB
store -- is not yet settled]`.

Two stores stay outside the flob model: the **system / network configuration**
(IP, ports) -- schema known, live store `[? unlocated]`, IP likely fixed in
`[~ EEPROM]` -- and **NMEA 0183 baud / N2K filters / alarms / units /
calibration**, `[? unlocated]`.

## 7. The substrate, the projections, and the seam

There is one architecture, seen two ways. The **runtime / object-model** view is
everything above (class <-> instance). The **deployment / physical-form** view
-- how the frozen image is packaged, classified, bootloaded, and installed --
maps to load addresses, not objects.

They are not rival roots: they **meet at one seam** (at boot the image is
inflated from NOR into RAM) and **share one fact**, the **NOR map**. Persistent
state physically lives in NOR regions the application **reads as data** -- the
compressed image, the flob store (`\local`), the demo media it overlays on a UX
flag -- plus the CF card. Those region *roles* belong here; their *offsets and
formats* are deployment Design.

## 8. The wall, provenance, and how we know

RayCom wires objects at boot through a GUID-keyed **runtime registry**: a class
asks for an interface and is handed an object. So the wiring is assembled at
runtime and is **not in the image**. RTTI kept the class names (the boxes) but
not the connections (the arrows). Past this wall, knowledge is **empirical** --
and drawing the wall is the point: it bounds what static reading can ever yield.

What we hold rests on four foundations, marked when it matters:

- **Firmware** -- the RTTI class names, plus ~a dozen of our own semantic renames
  where the **naming is the architecture** (`RAYDP_*` discovery, the persistence
  and instrument-app renames).
- **The live device** -- read via a **modification we made**, `mod001`, which
  re-purposes the unadvertised Diagnostics service into a peek / poke / call
  channel. **`mod001` is ours, not a device feature** -- the native E80 exposes
  no such channel (and serves no blob storage over the wire at all); it is named
  only as *how* the confirmed facts were confirmed.
- **The manuals** -- the crown, the apps, the operating model.
- **The author's external corpus** -- the protocol decoders, the FSH archive
  format, the Boat instrument model, and the wire experiments that predate and
  exceed the firmware dive.

The marks are the whole point: the document's worth is that it never launders a
guess into a fact, nor a manual statement into a firmware finding.

## Concept dictionary

(Roles and kinds; implementation class names live in the Design tier.)

| term | one line |
| ---- | -------- |
| E-Series Networked Display | the product the E80 is: a networked marine MFD |
| application | the E80 firmware running as a whole ("The E80"); cf. *app* |
| app | a class instance placed in a window |
| window app | one of ~11 apps (Chart, Radar, Fishfinder, Data, Engine ...) |
| instrument app | the 3 that host panels: Data, Engine, CDI |
| instrument abstraction | the unified data model all consumers draw from |
| proxy | the local stand-in for one data source (GPS, compass, radar ...) |
| data item | one displayable quantity; what fills a panel cell |
| data bar | the strip of values across the top of the display |
| soft-keys | the five context buttons at the bottom |
| Page | the windowed region between the data bar and the soft-keys |
| page set / page / window | the layout containers (5 / 5 / 1-4) |
| panel | a grid of up to 16 cells inside an instrument app |
| data master | the one networked unit that owns shared state |
| service | a networked provider (waypoints, tracks, database ...) |
| service-port | a service's RAYDP-advertised endpoint: a protocol + address + port a client reaches it at |
| RAYDP | the service discovery / advertisement protocol |
| flob store | append-only 64 KB flash-blobs of UUID-keyed records (NOR or CF) |
| named filesystem | the path-named view of NOR flob records ("\local") |
| WGRT | waypoint / route / group / track -- the navigator's data |
| ARCHIVE.FSH | the CF-card flob archive of the WGRT history |
| slot | a per-instance store key = {page set, page, window} |
| machine id | the unit's own 32-bit identity (SysInfo+0x50); the keyed-store owner field, the WGRT GUID seed, and the RAYDP wire id alike -- not RAYDP-specific |
| the wall | RayCom's runtime registry; why the wiring isn't in the image |
| mod001 | OUR modification (re-purposed Diagnostics); how we read the device; not native |

---

*Pass 4 -- distilled from firmware + device + manuals + the external corpus.
Confidence defaults to confirmed; only exceptions are marked. The one
load-bearing open item is the NOR-vs-CF write topology (the live-WGRT NOR
location is now confirmed: the shared `flobs.fsh` store). Read the prose first
as the comprehension test: a noun with nowhere
to hang is a defect in the sentence, not a gap in the reader.*

---

**Next:** [runtime](runtime.md) ...
