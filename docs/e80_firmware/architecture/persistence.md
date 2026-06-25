# Configuration Persistence

**[Architecture](readme.md)** --
**[overview](overview.md)** --
**[runtime](runtime.md)** --
**[services](services.md)** --
**[instruments](instruments.md)** --
**[applications](applications.md)** --
**persistence**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

How some of the E80's **configuration** persists across power cycles: the **screen
layout** (the page sets, and the apps placed in their windows), the **instrument
panels**, the **data bar**, and the **system / network settings**. It describes
the *machinery* that serializes those settings and rebuilds them at boot -- the
RayCom object model, the class registry that turns a stored identity back into
running code, and the **two faces** of the one local store the settings are
written through: a path-named `\local` framework (page sets, data bar, system
settings) and a by-key **keyed-object store** (the instrument panels).

This is the configuration layer; the storage substrate it writes to (the flob
store and its files) is [runtime: NOR filesystems](runtime.md). It pairs with
the user-facing [Config](../abstracts/Config.md) abstract (the *what* and the
byte layout), and builds on the RTTI/vtable catalog and framework layering.

---

## 1. The RayCom component model

Almost everything above the ThreadX/PEG layer is built as **RayCom**
components -- a compact, in-process COM-like object system. Three
template families, visible all over the RTTI, define it:

- `RayComObject<C>` / `RayComCoClass<C, &CLSID_C>` -- a concrete
  creatable class `C` with a globally unique **CLSID** (a 16-byte GUID).
- `CRayObject<C>` / `CRayObjectFy<C, ...>` -- object wrappers and
  per-class factories.
- Interfaces named `I<Name>` (e.g. `IPanelSet`, `IClassInformation`,
  `IInstrumentManager`), each with a 16-byte **IID**.

### Object layout and QueryInterface

A RayCom object is a C++ object with (usually multiple-inheritance)
vtables. Like COM, every interface exposes the `IUnknown` trio
(QueryInterface / AddRef / Release) in its first slots, and an object
can be asked for any interface it implements via **QueryInterface(IID)**.

Each class carries a static **interface map** -- a table of
`{ IID-pointer, sub-object-offset, flags }` triples. QueryInterface
walks it, and on a match returns `this + offset`, the pointer to that
interface's vtable sub-object. The offsets in the map are exactly the
offsets at which the object's constructor installs its secondary
vtable pointers, and each secondary vtable records that same value as
its "offset-to-top". (Worked example: the instrument application's
interface map at `0x00e6c9e8` lists 16 interfaces -- IPanelSet,
IInstrumentGridMergeAndSplitCallbacks, IInstrumentManager,
IInstrumentApplicationConfiguration, IRayApplicationSetup, and so on --
each paired with the object offset of its vtable.)

The practical consequence for analysis: a list of `{GUID, offset}`
pairs that lines up with vtable-pointer installation sites is an
**interface map** (a capability list), not stored data. This matters
because it is easy to mistake for a serialization field table.

### vtable shape

The compiler (Green Hills, ARM) emits RayCom vtables as a `type_info`
pointer slot followed by the virtual-function pointers; secondary
(multiple-inheritance) vtables additionally carry an offset-to-top.
A virtual call written `(*(*obj + 0xNN))(...)` indexes the vtable by
the raw byte offset `0xNN` from the pointer stored in the object. The
type descriptors themselves are 4-word records
`{ ti-class-vtable (0x0153e180), name-pointer, sequence-id, base-descriptor }`
chained by the last field.

---

## 2. The class registry: identity that survives a reboot

Creatable classes register themselves, at startup, into a single
system **class registry**. The registry is the concrete class
**`CHSBClassInformation`** ("HSB" = the SeatalkHS high-speed bus),
reached through its **`IClassInformation`** interface. (Its own CLSID
is the static GUID at `0x00e6478c`; the IID is the adjacent GUID at
`0x00e6479c`. The CLSID is copied into a RAM slot at init by a small
stub, which is why early analysis saw only a RAM address here.)

The registry is a balanced (red-black) tree of **class-info records**.
Each record is 36 bytes (0x24):

| Offset | Field                                              |
| ------ | -------------------------------------------------- |
| 0x00   | pointer to the class's 16-byte **CLSID** GUID      |
| 0x04   | class factory / create function                    |
| 0x08   | second create function                             |
| 0x14   | shared helper (common to all app records)          |
| 0x18   | flag (1)                                            |
| 0x1C   | **application-type id** (the small page-set app ID)|
| 0x20   | pointer to the class's internal **name** string    |

Two lookups over this tree are the hinge of the whole scheme:

- `CHSBClassInformation_getClsidByAppType` (the `IClassInformation`
  method at vtable offset 0x54): given a small application-type id,
  find the record whose `+0x1C` matches and return its 16-byte CLSID.
- `CHSBClassInformation_getAppTypeAndNameByClsid`: the inverse -- given
  a CLSID, return its application-type id and internal name.

This is precisely why **the device can rebuild every page set and panel
from flash with no template at boot**: a saved configuration stores a
class's *CLSID*, and the registry maps that CLSID straight back to a
live class (and, in reverse, an application-type id back to a CLSID
when expanding a factory default). The identity is durable; the small
integer IDs are only convenient lookup keys used while building.

The firmware-authoritative application-type table (the nine page-set
applications, their internal class names, and their CLSIDs as stored in
a page-set window slot) is summarized in the
[Config App IDs](../abstracts/Config.md) section.

---

## 3. The local-persistence framework (the path-named face)

Most user-visible, per-display settings persist through a
**schema-driven** framework that writes individual `.lp` ("local
persistence") files to the unit's internal flash -- the **path-named** face
of the store. (The instrument panels are the exception: their layouts use the
**by-key** face, section 4.)

### Where it lives, and what it is not

Persistent items live on the internal flash filesystem, mounted at
`\LOCAL\` and backed by `CFlashFlobFsDriver`. This is **distinct** from
the CompactFlash card served by the FILESYS network service
(`CFAccessController`) -- different driver, different volume. Empirically
confirmed: a FILESYS directory listing of `\LOCAL\` fails, so the
persisted settings are **not** reachable over the wire through FILESYS.
See [FILESYS](../abstracts/FILESYS.md).

### Path construction

`CLocalPersistenceService_buildPath` composes every path from the owning
client's class name (stored on the client at +0x14) and an item name,
in one of four shapes:

```
\<class>\slotless\                      (no slot, no item)
\<class>\slotless\<item>.lp             (no slot, with item)
\<class>\slotXXYYZZ\                     (3-byte slot key, no item)
\<class>\slotXXYYZZ\<item>.lp            (3-byte slot key, with item)
```

The firmware format is `\%s\slot%02X%02X%02X\%s.lp`, so a slot key is six hex
digits (e.g. `slot040001`). The three bytes are a per-instance **context key =
{page set, page, window}**, and all three are now **confirmed**: byte 0 is the
page-set index (`00` Navigation, `04` Custom), byte 1 the page index, byte 2 the
window index. This was proven by mapping a unit's full slot namespace onto its
page-set layout -- `slot040201/040202/040203` are exactly the three Data windows
of Custom page 2, `slot0404xx` the four windows of the four-Data page, and so on,
a clean bijection -- and confirmed dynamically (2026-06): editing two windows of
Custom page 2 created precisely `slot040202` and `slot040203`, while the window
left at its default stayed absent. The "slotless" variant is the single-instance
case (the consolidated page-set state); the slot variants let several view-state
instances of one class persist side by side.

Caveat on the in-RAM directory cache: the accessor's cached directory tree can
**lag** what is actually in NOR -- freshly created slot files were durably present
(confirmed by a STAT-by-path) while still absent from the cached tree listing. So
"absent from the directory listing" is not "absent from NOR"; trust STAT-by-path.

### Creating entries

Every `\local` node -- directory or file -- is a single tree node: a freshly minted
64-bit GUID (from the `Guid64Gen` singleton), a kind word (`0x1c` root / `0x1d`
directory / `0x1e` file), and the entry name. Each directory holds two balanced trees
of children, one for subdirectories and one for files. A "directory" is therefore just
a named, GUID-keyed, **zero-length** node -- there is no separate directory medium.

Two creation paths exist, both through the FS accessor:

- **Files** are created as a *side effect of STAT-by-path* (`0x00bc49ac`): when the
  target directory exists but the named file does not, STAT mints a zero-length file
  node (`fsAccessor_createFileInDir`, `0x00bc39c4`) and returns success. This is the
  origin of the bodyless 0-sector `.lp` marker noted under client #1 -- the STAT probe
  itself creates it. STAT does **not** create directories: if the directory is absent
  it returns `0x80040001`.
- **Directories** are created by `fsAccessor_createSubdirInDir` (`0x00bc3644`), which
  inserts a kind-`0x1d` node into the parent's subdirectory tree. The by-path wrapper
  `fsAccessor_createDirByPath` (`0x00bc4754`) walks to the parent and creates only the
  final component, so a deep path is built one level at a time.

`CLocalPersistenceService_save` (`0x007c35c0`) shows the first-write order: ensure each
directory level, STAT the file path (which creates the empty file), then write the body.

### The schema

Each persistence client owns a **schema table**: a static template that
is copied to a RAM working copy on first use. Every entry is 20 bytes
(5 words):

| Word | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| w0   | pointer to the item-name string (becomes the `.lp` file name) |
| w1   | offset of the data within the owning object                   |
| w2   | reserved (0)                                                  |
| w3   | size in bytes                                                 |
| w4   | low byte = type flag: 0 = inline, 1 = pointer indirection     |

A zero entry terminates the table. To save, the serializer walks the
schema and gathers every field into one buffer; load is the inverse.
**For `CMainApp` that buffer is written and read as a single consolidated
file** (`CMainApp0.lp`, below), so the schema item-names label the fields
*within* that blob rather than naming one file each. The firmware does
still compose per-item `\<class>\slotless\<item>.lp` paths from those names
via `buildPath`, and a bodyless `Custom Page Set.lp` is present in the
volume -- so the once-assumed "persisted files = named schema entries"
invariant holds for *paths the firmware can form*, but **not** for where
the bodies live: the page-set bodies are consolidated, and the empty
per-item file is a firmware-encoded STAT query-stub (see under client #1).

### Decoded client #1 -- CMainApp (page sets and the data bar)

The `CMainApp` persistence client (`LocalPersistenceClient_CMainApp`,
schema template at `0x015e0944`, 9 entries) serializes its eight data
items into a **single consolidated file**, observed live and read back
remotely (2026-06-01) as **`\local\slotless\CMainApp0.lp`** -- 6 sectors =
**3009 bytes**, the items packed in schema order:

| Offset | Size | Item                                            |
| ------ | ---- | ----------------------------------------------- |
| 0x000  | 4    | Main App Persistence Version (= 0x11, "valid")  |
| 0x004  | 4    | Active Page Set (index 0..4; 4 = Custom)        |
| 0x008  | 600  | Navigation Page Set                             |
| 0x260  | 600  | Situational Awareness Page Set                  |
| 0x4b8  | 600  | Boat Systems Page Set                           |
| 0x710  | 600  | Fishing Page Set                                |
| 0x968  | 600  | Custom Page Set                                 |
| 0xbc0  | 1    | Databar Present                                 |

The 600-byte page-set block is fully decoded in
[Config](../abstracts/Config.md); each of its four per-page window slots
holds a 16-byte CLSID resolved from the class registry (section 2). The
consolidated blob was verified end-to-end: `CMainApp0.lp` was read over the
diagnostics primitive and decoded field by field -- Navigation (page 1
full/Chart, page 2 full/Radar, page 3 L/R) and Custom (page 1 top/bottom,
Chart over Data) both matched the on-screen layouts byte for byte, and
matched the live RAM copy at `CMainApp + 0x1240`.

**The empty per-item file (characterized).** A separate `Custom Page Set.lp`
of **0 sectors** also exists in this directory (and in the per-instance slot
dirs) -- the only per-item page-set file present, carrying no body. Its name
is composed and used by the firmware, so it is a real artifact, not a
phantom. It is a **STAT query-stub**: the page-set manager forms and probes
this legacy per-slot path -- a vestige of the pre-consolidation per-slot
scheme, where (pre-reset) a `slot020100\Custom Page Set.lp` once held a real
600-byte body -- and today it resolves to a bodyless 0-sector marker `[~]`.
The live page-set bodies are all inside the consolidated `CMainApp0.lp` blob
above.

### Decoded client #2 -- the instrument applications (the `Current Panel` byte)

The Data, Engine-monitor, and CDI applications share one base implementation
(`CInstrumentationApplicationBase`) and each window instance persists a
**single** `\local` named item: `Current Panel`, a **1-byte data-panel selector
index**, written **per window** as `\local\slot<PSPGWW>\CInstrumentatio0.lp`.
This is a *per-window* selection, distinct from the panel definitions: several
Data windows on one page each get their own slot file even though they share a
single panelset record (section 4). Characterized on the device (2026-06): the
byte is the data-panel menu position -- observed `0` = Navigation (the default,
which writes **no** file at all), `1` = Waypoint, `2` = Route, `4` = Sailing.
The full write round-trip was proven: poking `0x04` into one window's
`CInstrumentatio0.lp` through the storage layer and power-cycling brought that
window up showing **Sailing** -- so the device reads and applies a selector
written entirely from outside the UI.

That byte is the *only* part of an instrument application that uses the `\local`
path framework. The panel **layouts and cell contents** are **not** `\local`
files -- they persist as keyed records in the flob store's by-key face (section
4). The two are independent layers, and **both** are needed to reproduce a
screen: a page set written without the per-window selectors comes up with every
instrument window defaulted to Navigation (observed -- writing the rich Custom
page set alone left all three of its Data windows on the default panel).

### A second, different schema -- system / network configuration

A separate schema (table at `0x00c608fc`) persists the unit's system
and network configuration with a *different* per-entry layout
(`{ size, default-data-pointer, reserved, type-id, name-pointer }`) and
a one-way **legacy -> modern migration** pattern (it reads old-format
items on boot and writes new-format ones). Notable items include the IP
address / subnet / gateway (defaults 10.0.0.4 / 255.0.0.0 / 10.0.0.1),
the MAC and ARCNet addresses, the serial number, the DataMaster live
state, and the "Legacy LNet Diagnostics Port" flag tied to the
[Diagnostics](../abstracts/RAYDP.md) service.

---

## 4. The keyed-object (flob) store: persistence by key

The `\local` framework above is the **path-named** face of persistence. There
is a second, co-equal face: a **keyed-object store** in which a record is
addressed not by a path but by an 8-byte **key** -- two 32-bit halves,
`[owner-id][value]`. The owner word is `[0xb2 E80-model tag | 24-bit unit id]`
(the `0xb2` constant across all E80s, the 24-bit remainder the reset-stable unit
identity); the value is a **monotonic per-owner counter** (what earlier looked
like separate `type` and `record-id` 16-bit fields are its high and low halves),
one point in the unit's reserved region of a single partitioned GUID address
space ([runtime: NOR filesystems](runtime.md), which carries the full key model).
The instrument applications' **panel layouts** persist here -- not as `\local`
files.

Both faces sit on the **same** flob store in NOR (`flobs.fsh`, the single known
local flob store at `0x50e40000`). Its engine -- a circular ring of 64 KB
"RAYFLOB1" flobs holding append-and-supersede *records* (a *block* in the
raymarine/FSH terminology), indexed by an in-RAM red-black tree -- is documented
in [runtime: NOR filesystems](runtime.md); `\local` is just a path translator
layered over that same store. This section is the **by-key** view of it.

### Panels as keyed records

Each instrument application (Data, Engine, CDI) persists its whole **panelset**
as a **single keyed record** -- one record per application instance (on the E80-4
the Data app's record was read at key `{66af81b2, 0x0042, 0x999e}`, 1864 bytes).
The `0x0042` high half is **not** a panel type but just that unit's current
high-water region of the per-owner counter -- the store holds hundreds of objects
there and the panelsets are a few. The record carries *all* of the app's
selectable panels at once (for the Data app: Navigation / Waypoint / Route /
Fishing / Sailing), so an individual panel is a sub-structure of it, not a record
of its own. The record is the
**GUID-serialized** panel state: the application's recursive `CInstrumentGrid`
cells and their per-cell `CInstrumentDataSource` bindings, each cell carrying a
single 32-bit curated panel-item code (observed Rudder = 16, Speed = 5). The
record is **device-agnostic** -- only the key's owner-id carries the owning
unit's machine id -- so a panel set can be moved between units by re-keying.

Confirmed on the device (2026-06-01): a Data-panel customization (cell split,
data assignment) survives a hard power-cut, read back from this store -- the
layouts are keyed records here, not `\local` files.

**Creation and keying (2026-06).** A panelset record is **not** pre-placed: an
instrument application **mints its own** record the first time it is instantiated
on screen, self-allocating the key and writing a default panelset; customizing it
later supersedes that record in place. This was watched live -- writing the rich
Custom page set and rebooting caused the active page's Data windows to instantiate
and self-mint a (default) panelset record. The key's **value** half is not a
stable identifier but a position on the store's **monotonic, never-reused** counter
(section above): it only climbs, so the same Data panelset was observed at value
`0x0004xxxx`, then `0x0009xxxx`, then `0x000axxxx` on successive resets -- the high
half carrying, not a re-keying allocator -- and `0x0042` is just one unit's current
high-water region. So the key must be **resolved at runtime** from the live
application, never hardcoded -- the mechanics are in
[runtime: NOR filesystems](runtime.md).

The find is **owner-scoped**: an application loads (or mints) its panelset under its
*own* unit's owner-id and does **not** adopt a record left under a foreign owner -- the
complement of the device-agnostic record above (to move a panel set to another unit, the
record is re-keyed to *that* unit's owner). Confirmed on the device (2026-06): a valid
panelset written under a foreign owner-id was ignored, and the application minted its own
default under its real owner instead.

### Scope

This document is the **application-configuration** view of the store -- page
sets by path (section 3) and panels by key (above). The same flob store also
carries the live **navigation database (WGRT)** -- waypoints, routes, groups,
tracks -- each as a full 64-bit-GUID-keyed record whose W/G/R/T type lives in the
record **body**, not the key; that tenant, and the store's full mechanics, are
[runtime: NOR filesystems](runtime.md), not here.

---

## 5. The instrument database (data items)

The quantities the system can display or store are the
**`INSTRUMENT_DATA_ITEMS`** enumeration. The firmware describes each one
in RTTI via the template
`TDBItem< <unit-type>, (UINT16)<id>, INSTRUMENT_DATA_ITEMS::<encoding> >`:
a 16-bit **id**, a **unit-type** giving physical meaning and scaling
(`INSTRUMENTS::SPEED_0_01_METRES_PER_SECOND_T`, `..::ANGLE_0_0001_RAD_T`,
packed structs such as `PACKED_POSITION_STRUCT_T`, and so on), and a db
**encoding** (byte/short/long, signed variants, position/waypoint-name
strings). The full 160-item enumeration is extracted from the image.
Ids with bit 0x8000 set are signed variants. This vocabulary is what a
data-panel cell or a data-bar field binds to.

---

## 6. How it assembles at boot

Putting the pieces together, the sequence that produces the first
screen under the splash is:

1. Static initializers register every creatable class into the
   `CHSBClassInformation` registry (CLSID + application-type id + name).
2. `CMainApp` starts and asks its persistence client to load. If the
   stored state is valid it reads the single consolidated
   `\local\slotless\CMainApp0.lp` blob (version + active-set + the five
   page sets + databar); if missing or invalid it expands the built-in
   factory template (resolving each window's application-type id to a
   CLSID via the registry) and saves the result.
3. For each visible window, the stored 16-byte CLSID is handed to the
   object manager's CreateInstance, which the registry resolves to the
   application class; the application is instantiated and drawn.
4. Instrument (Data / Engine / CDI) applications additionally load their
   1-byte `Current Panel` index from `\LOCAL` and deserialize their saved
   panel layouts from the Flob keyed store (one record per application).

This rebuild happens **at boot**, and only at boot: the inflated panel objects
are built from NOR once and reused for the session, so a configuration record
written from outside (over the storage path) takes effect on the **next
power-cycle**, not immediately. Navigating between pages re-creates a window's
view instance but rebinds it to the already-built panel; it does not re-read NOR.
Confirmed both ways on the device (2026-06) -- a written per-window selector and an
overwritten panel record each became visible only after a reboot.

Nothing here is arbitrary: every stored byte is either a fixed-format
record (the 600-byte page-set block) or a CLSID that the registry
deterministically maps to code. That determinism is the whole reason
the unit can reconstruct its exact prior appearance from a handful of
small flash files.

---

**Next:** [Home (Architecture)](readme.md) ...
