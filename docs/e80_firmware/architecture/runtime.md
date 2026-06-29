# Runtime

**[Architecture](readme.md)** --
**[overview](overview.md)** --
**runtime** --
**[services](services.md)** --
**[instruments](instruments.md)** --
**[applications](applications.md)** --
**[persistence](persistence.md)**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The artifact in memory: image layout at runtime, .bss boundary,
exception vector table, boot prelude, the Green Hills MULTI
runtime-init driver.

Once stage-0 has inflated the firmware image into RAM and jumped
to its entry point, the firmware itself takes over. This doc
covers what happens then: the ARM exception vector table at the
head of the image, the shared reset prelude, the
position-independent linkage trick, the Green Hills MULTI
runtime-init driver, the runtime memory map, and the toolchain/
runtime identification visible from embedded library banners.

## How the image got here (upstream)

The running image at RAM `0x0` is the inflated `E80/120_App`,
decompressed from the copy in NOR at `0x500a0000` by stage-0 at
boot -- it does not run in place from flash (it is gzip-compressed
there). The construction of that compressed image is in
[containers](../deployment/containers.md); the inflate-to-RAM step and the
stage-0 that performs it are in [bootloader](../deployment/bootloader.md). This
doc takes the ARM as already set up and running the decoded
`e80.bin`.

## NOR (Flash) Filesystems

The **runtime view** of persistent storage. The picture below places all the
media; after it, **this section is about the NOR chips only** -- the on-board
store that survives power cycles. (The CF card and the RAM scratch volume appear
in the picture for context; the install/boot view of NOR is
[deployment/bootloader](../deployment/bootloader.md).)

The headline, confirmed by reading a live unit by key over the mod001 channel:
there is **one known runtime flob store** in NOR, and it holds **both the
configuration and the live navigation database (WGRT)**, separated only by key.
It is not a separate region per data class, and it does not grow toward the top
of the chip.

### The stack at a glance

```
  views          \local (path-named)            by-key records
                       \                         /
  .fsh stores              flobs.fsh        |    archive.fsh   (a ".fsh" = a flob store)
                              |                    (CF export)
  flob filesystem    CFlobFilesystem -- "RAYFLOB1": a ring of 64 KB flobs of keyed
                            |            records (FSH "blocks"); append-and-supersede + GC
  flash driver       raw NOR (localFlob_createNorDriver) | file-backed (CVirtualFlashDriver)
  storage            NOR chips @0x50000000 (CFI)  |  CF card (FAT)  |  RAM ("Baz FS")
```

### The NOR filesystem area

The installer writes nothing above the demo region; that span -- roughly
`0x50e40000 .. 0x51000000` (the top of the chip), the ~1.75 MB no install action
touches -- is The E80's **runtime filesystem area**. The one store we have
located, `flobs.fsh`, sits at its base; the rest is unaccounted for. The full
NOR map, runtime-side:

| NOR region | offset / size | contents |
|------------|---------------|----------|
| boot region | `0x50000000` | stage-0 (executed at reset) |
| config seed | `0x50080000` | factory-reset baseline (~15 KB) |
| application | `0x500a0000` | compressed image -> inflated to RAM at boot |
| demo content | `0x50c40000` | demo media (~625 KB) |
| **filesystem area** | **`~0x50e40000 .. 0x51000000` (~1.75 MB)** | **runtime flob storage:** |
| `- flobs.fsh` | `0x50e40000`, `0x180000` (1.5 MB) -- **fixed** | the single known local flob store (below) |

`flobs.fsh`'s base and size are pinned in code as compile-time constants
(`localFlob_createNorDriver`) -- it is fixed, not grown. It is the only flob
store we have located; the span above it (`~0x50fc0000 .. 0x51000000`, ~256 KB)
is unaccounted for, written by neither the installer nor the flob driver -- see
*open edges*.

### What a flob store is (`CFlobFilesystem`)

A `.fsh` store -- the class `CFlobFilesystem` -- is a **circular buffer (ring) of
64 KB "RAYFLOB1" flobs** with a free-space / reclamation scheme. (The ring
advance, dead-record reclamation, and a periodic fullness monitor are confirmed;
the exact free-list mechanism is not fully decoded -- we know it exists.) Within
a flob the data is a packed series of **records** -- a *block* in the
raymarine/FSH terminology -- each a ~14-byte block header (key, type, length,
live/dead flag) followed by the record body. Records are keyed by an 8-byte key
`{owner machine-id, type, record-id}`, indexed in an in-RAM red-black tree
(`CFlobGuidList`, rebuilt by scanning the flobs at mount), and updated by
**append-and-supersede** (a new copy is written and the old marked dead, so the
current value of a key is its latest live record). Primitives: `readByKey`
(`0x004bbff4`) / `writeByKey`. The on-flash block layout is exactly the
raymarine/FSH format. On NOR the store is driven through the memory-mapped window
(`localFlob_createNorDriver`); the identical format **as a file** on a FAT volume
(CF, or the RAM "Baz FS") is opened file-backed by `CVirtualFlashDriver`.
`CFlobFilesystem` is the one store *type*; the `.fsh` files are its instances.

### `flobs.fsh` -- the single known local flob store

The fixed 1.5 MB store at `0x50e40000`. It holds **both the configuration and the
live navigation database (WGRT)** -- one store, reached **two ways**:

- **by path (`\local`)** -- `CLocalPersistenceService` maps
  `\LOCAL\<class>\slot<XXYYZZ>\<item>.lp` onto records through a path filesystem
  (`CFileSystem`); this is where the CMainApp page-sets blob and the
  Current-Panel byte live. (Configuration-persistence detail:
  [configuration persistence](persistence.md).)
- **by key** -- records addressed by an 8-byte key, best understood not as two
  schemes but as **one 64-bit GUID address space** (the `CFlobGuidList` tree)
  deliberately **partitioned by a leading marker byte**. The key is two 32-bit
  halves: an **owner word** and a **value**. The E80's own persisted objects carry
  the owner word `[0xb2 | 24-bit unit id]` -- the `0xb2` an **E80-model constant**
  shared by every E80, the 24-bit remainder the unit-specific identity (persistent
  across factory resets). The low 32 bits are **one monotonic odometer per owner**:
  what earlier looked like separate `type` and `object-id` 16-bit fields are simply
  that counter's **high and low halves** (`type:objid` = `0xTTTToooo`, one number).
  It only ever **increases** and is **never reused** (a superseding write reuses
  the same key and consumes no number), so the apparent "`type` migrating
  `0x0004` -> `0x0009` -> `0x000a` across resets" is just the high half carrying --
  **not** a re-keying allocator. And it is **one** counter shared by **every**
  consumer of this store -- the keyed config records, the WGRT database, *and* the
  `\local` named `.lp` files -- which is why even a reset that writes only a few
  hundred objects still advances `type`, and why `0x0042` is merely one unit's
  current high-water region (an E80 carries hundreds of these objects, the
  panelsets being a few). The practical consequence: because the odometer only
  climbs and never descends to reuse, **any still-free value below the current
  high-water mark is permanently safe to occupy** -- the bedrock the cleanroom
  backup tool's key allocator stands on ([cleanroom](../cleanroom.md)). An
  app does **not** compute its key -- it **caches** the key of its current record
  (resolved at runtime when minted or loaded, then superseded in place); a backup/
  restore tool must likewise **resolve keys at runtime** -- walk the live app and
  read its cached key (`app+0xa88`), or enumerate the live store -- never hardcode
  one. Only the **owner** word is fixed (hardware-stable across resets).
  WGRT items (waypoints, routes, groups, tracks) occupy the same space as **full
  64-bit GUIDs** -- **not** owner-word-prefixed, with the W/G/R/T type in the
  record body, not the key; E80-native ones are minted owner-seeded, while an
  external minter such as **navMate** deliberately reserves a **different marker
  byte** (`0x4e`) so two independent minters never collide in the one store. (Being
  non-owner-prefixed, they fall outside any one owner's odometer and are simply
  avoided when choosing a free value.) Confirmed live off the unit: the
  instrument-app **panelsets** (a GUID-serialized `0x0042` record per app) and
  **WGRT** items (whose flob keys match the unit's on-screen UUIDs byte-for-byte).
  All of it is read **and** written through the same read-by-key / write-by-key
  primitives.

The path face and the key face are the same flob store, addressed two ways; the
unit identity in the owner word is sourced from the system-info singleton -- the
same word the diagnostics reply stamps as its source id
([diagnostics](../deployment/diagnostics.md)).

### Reaching the live store object at runtime

`readByKey` / `writeByKey` / `deleteByKey` take the store object (`this`) as their
first argument, so any client that drives the store from outside must hold that
pointer. The `CFlobFilesystem` object is **heap-allocated** -- its constructor
`rm_malloc`s a 0x48-byte object -- so its address is **per-boot and per-unit** and
must be **resolved at runtime, never hardcoded**. The local NOR store's live `this`
is reached through a stable mount-state pointer:

```
store this = *( *(0x000942f0) + 4 )
```

`0x000942f0` (`localFlob_mountState_ptr`) points to a two-word mount-state struct
`{ init_flag, CFlobFilesystem* }`; `localFlob_mount` builds the store
(`localFlob_createFilesystem`, over the raw-NOR driver) on first use and caches its
pointer in slot `+4`. A resolved object is integrity-checked by its word0 vtable,
`0x0155e214` (the `CFlobFilesystem` vtable). The record primitives are non-virtual:
`readByKey` `0x004bbff4`, `writeByKey` `0x004bbda4`, `deleteByKey` `0x004bccd8`,
each called as `(store this, ...)`.

One near-namesake to avoid: `flobStore_getInstance` (the pointer at `0x004c0170`)
returns a **different** object -- a flob tag-index manager (vtable `0x0155e54c`),
not this keyed store. Resolve the store only through the mount-state path above.

### Open edges

The store mechanics, and the finding that WGRT shares this store, are
**confirmed** -- static analysis plus a live read-by-key off the unit (a
uniquely-named waypoint, pulled back and decoded as an FSH waypoint). What
remains:

- **Scale.** One waypoint demonstrably lands in `flobs.fsh`; whether a *large*
  WGRT load stays within 1.5 MB, hits the fullness gate, or spills is untested.
  Next: push hundreds of waypoints from navMate, re-read, watch the monitor.
- **Other stores.** `flobs.fsh` is the only flob store located; the ~16 MB above
  it appears unused. Whether any other persistent store exists is unconfirmed.
- A WGRT record's **type** (waypoint / route / group / track) lives in the record
  body, not the key -- the key is the item's 64-bit UUID. (The key's middle
  `0x0003`/`0x0004`/`0x0005` bytes are UUID bytes, not type tags: a group and two
  waypoints carried `0003`/`0004`/`0005`, so they cannot be a type field.)
- `live.fsh` is **not** the WGRT store -- it appears to be the **simulator's**
  sensor-data image (a `CDataBase`, a separate class), out of scope here.

## Toolchain and runtime identification



Both inflated images contain definite signs of versioned,
publicly known commercial libraries that identify the target
and toolchain:

- **ThreadX G4.0.4.0** (ARM9 / Green Hills) -- both images
- **FileX G3.0.3.0** (ARM9 / Green Hills) -- both images
- **InterNiche Portable TCP/IP v1.91** -- both images
- **PEG Library 1.82** -- both images
- **zlib 1.1.4** -- `e80.bin` only
- **Dinkumware C++ standard library** -- `e80.bin` only

Combined with the reset prelude documented below, both images
sit on a 32-bit ARM9 target, built with the Green Hills MULTI
compiler, against an Express Logic RTOS/filesystem with the
InterNiche TCP/IP stack and the Swell Software PEG GUI library.
`autorun.bin` is a complete ThreadX application built on the
same shared RTOS/UI/network stack, not a thin loader stub.
`e80.bin` additionally contains zlib and the Dinkumware C++
standard library, and the application layer that sits on this
stack is the COM/ATL-flavored RayCom framework.

The Raymarine hardware codename embedded in source paths is
**"Pandora"**. No technical protection measure surfaces at the
framework-banner level.

## ARM exception vector table

The first 32 bytes of both `autorun.bin` and `e80.bin` form an
ARM32 little-endian exception vector table: eight consecutive
32-bit unconditional branch (B) instructions. The branch
targets differ between the two images, as expected for images
of different sizes (~1 MB vs ~23 MB).

Exception vector targets cluster tightly in each image,
consistent with a single RTOS exception module linked as a unit:

| Image | Handler region | Span |
|-------|----------------|------|
| `e80.bin` | `0x17639c..0x17fe94` | ~38 KB |
| `autorun.bin` | `0x63d5c..0x67880` | ~15 KB |

## The shared reset prelude

The 32 bytes immediately following the vector table (offset
`0x20`) are **byte-identical** between the two images. Decoded
as ARM32, this is a textbook ARM reset prelude:

```
00 00 A0 E3    MOV r0, #0
15 0F 07 EE    MCR p15, 0, r0, c7, c5, 0    ; invalidate instruction cache
0D 10 A0 E1    MOV r1, sp
D3 00 A0 E3    MOV r0, #0xD3                ; SVC mode, IRQ+FIQ disabled
00 F0 2F E1    MSR cpsr_c, r0
01 D0 A0 E1    MOV sp, r1
84 0B A0 E3    MOV r0, #0x21000
C0 04 80 E2    ADD r0, r0, #0xC0000000      ; build base address (= 0xC0021000)
```

Both inflated images are 32-bit ARM firmware sharing a common
bootstrap convention written by the same author for both.

## Position-independent linkage at VMA 0

Both images are linked at virtual address `0x00000000` and
discover their actual runtime load address at startup. The
trick, identical in both images at file offsets `0x120..0x124`:

```
e59f5050    LDR r5, [pc, #80]    ; r5 = literal at +0x178 = 0x0000012c
e04f5005    SUB r5, pc, r5       ; r5 = pc - 0x12c = runtime_base
```

The literal `0x12c` is the linker's PC value at the SUB
instruction when linked at base 0. At runtime, `r5` is set to
the actual load base, after which file offsets convert to
runtime VMAs by adding `r5`.

**Both images actually run at runtime VMA 0.** The
position-independent linkage is a boilerplate-correctness
mechanism rather than an indication that the images are
loaded at arbitrary addresses. Evidence:

- They are linked at VMA 0; file offset equals linker VMA in
  both images.
- They begin with an ARM exception vector table. On ARM9 with
  the default V=0 configuration, the exception vector base is
  virtual address 0; the alternative HIVECS region at
  `0xFFFF0000` cannot hold either of these images.
- `autorun.bin`'s reset handler explicitly **clobbers** `r5`
  (the computed runtime base) at offset `0x154` before invoking
  the dispatcher at `0xa0810`. The dispatcher therefore does
  not receive the runtime base in a register; it recovers
  position via its own `add ptr, ptr, pc` PC-relative
  mechanism.
- Stored stack-top values are absolute runtime addresses, not
  PC-relative.

The two images do not coexist in RAM. They share VMA 0 but at
different times: `autorun.bin` is the upgrade-process
application (run from RAM by stage-0 when a CF card is present);
on a normal boot stage-0 instead inflates `e80.bin` to the same
address space and jumps to its reset vector. See
[bootloader](../deployment/bootloader.md) for the two-scenario boot model.

## Stack-top literals per image

The literal at file offset `0x180` in each image is the runtime
stack-top address used by that image:

| Image | Stack-top literal | Approximate region |
|-------|-------------------|-------------------|
| `autorun.bin` | `0x0071b320` | ~7.4 MB |
| `e80.bin` | `0x07b25ec0` | ~123 MB |

The two images live in entirely separate runtime memory
regions: `autorun.bin` low in RAM, `e80.bin` high. Consistent
with `autorun.bin` being loaded and run first, and being what
loads `e80.bin` into its own memory area.

## Boot descriptor at file offset 0x184

After computing the runtime base, both reset handlers call a
runtime-init function with `r0` pointing at file offset `0x184`.
The four words there form a boot descriptor with the same
structure in both images:

| Word offset | `e80.bin`     | `autorun.bin` |
|-------------|---------------|---------------|
| `0x184`     | `0x00000001`  | `0x00000001`  |
| `0x188`     | `0x00000100`  | `0x00000100`  |
| `0x18c`     | `0x00000000`  | `0x00000000`  |
| `0x190`     | `0x01442280`  | `0x000f8040`  |

The first word is a tag that selects a path in the init
dispatcher. The fourth word is a per-image linker-VMA pointer
into image-internal data used by the init driver.

When the tag is 1, the init function reads at least eight words
of the descriptor (`0x184..0x1a0`), revising the documented
descriptor size upward from 4 words.

## The Green Hills MULTI runtime-init driver

The reset handler in `e80.bin` transfers control to a
runtime-init function at file offset `0x2afe8c`. The function
has the structural fingerprint of a Green Hills MULTI
compressed-initialization-table driver:

- Three distinct loops, each walking a table of init records
  and dispatching to a helper via an indirect-call thunk at
  `0xbf43a4` (`bx ip`).
- A fourth section at file offset `0x2b0158` that decodes a
  compressed byte stream with bit-flag-driven control. This
  is precisely a position-independent relocation/fixup walker:
  control byte + 4-slot base table + unaligned-access target
  patching; flag bits select base slot, alignment, optional
  `<<2`/`>>2` shift, and per-record skip.

The three helpers, loaded by the init function as PC-relative
constants:

| File offset | Function |
|-------------|----------|
| `0x2afb9c`  | ARM memset (byte-align then bulk word fill) |
| `0x2afc4c`  | memcpy variant |
| `0x2b0770`  | memcpy variant |

The function at `0x2afe8c` is a four-argument trampoline.
`param_1` is the boot-descriptor pointer; `param_2..param_4`
pass through unchanged and reach a final call
`0xbf43a4(param_2, param_3, param_4)` at the end of the
function, handing control to a caller-specified destination.

Indirect calls through `0xbf43a4` cannot be statically resolved. The second memcpy variant at `0x2b0770` is not
identified as a function by direct-call analysis because nothing directly calls it
-- it is reached only through the thunk with `ip` pre-set.
Helpers reached only via `0xbf43a4` must be marked
by hand before their decompilations or xrefs become usable. The
pattern is the standard GHS MULTI calling convention for
relocated helpers and is expected to be widespread across the
image.

## The runtime memory map

The four passes of the runtime-init driver are nearly empty in
this image: pass 2 and pass 3 contain zero records, and pass 4
(the position-independent relocation walker) runs 445 records
with all four bias slots equal to zero, so every patch is a
no-op. The image was built to run in-place at VMA 0 and all
link-VMAs equal runtime-VMAs.

The one non-empty pass-1 entry is the `.bss` clear:

```
memset(dest=0x016b5260, value=0, len=0x03060c60)
```

`0x016b5260` is the exact size of `e80.bin` -- the `.bss`
region begins immediately after the image in RAM and runs for
50,766,432 bytes (~48.4 MB).

Combined with the stack-top literal at file offset `0x180`
(`0x07b25ec0`), the boot-time runtime memory map for `e80.bin`:

| Range                       |    Size | Meaning                                                |
|-----------------------------|--------:|--------------------------------------------------------|
| `0x00000000..0x016b5260`    | 23.8 MB | Image in flash/RAM: code + rodata + data initializers  |
| `0x016b5260..0x04715ec0`    | 48.4 MB | `.bss` (cleared at boot)                               |
| `0x04715ec0..0x07b25ec0`    | 52.1 MB | Heap / unallocated RAM gap                             |
| `0x07b25ec0`                |         | Stack top                                              |

The dispatcher does **not** carry information about `.text`,
`.rodata`, or `.data` boundaries within the image -- because no
flash-to-RAM section copies are performed, no source/destination
range records are emitted. Section boundaries inside the image
have to be recovered by other means (anchor-string xrefs,
code/data pattern transitions).

The pointer in the boot descriptor at `0x190` (= `0x01442280`)
is used by the dispatcher only as the zero-bias base for slot
3 of the relocation walker. The structured data at
`0x01442280` is C++ runtime metadata (vtable / typeinfo /
global-ctor registration), consumed elsewhere by the C++
runtime support, not a section descriptor.

## The SysInfo singleton

A single **`.bss` global** holds the unit's identity and build stamp -- the
system-info singleton named above as the source of the keyed store's owner word
and of the diagnostics reply's source id
([diagnostics](../deployment/diagnostics.md)). It sits at `0x016b55c4` --
`0x364` into the `.bss` region established above -- so it is a **fixed address in
this final-firmware image**, read at the same place every boot. A mod001
peek / poke / call client ([mod001](../deployment/mod001.md)) reads the record
directly off the running unit.

The fields below are labeled by **what they decode to**; the stripped image
attests none of these names. Offsets are from the singleton base; the string
fields are NUL-terminated single-byte ASCII.

| offset  | type      | field                      | decode |
|---------|-----------|----------------------------|--------|
| `+0x50` | uint32 LE | unit identity (machine id) | the unit's 32-bit machine id -- see [the machine id](overview.md) and the owner word above |
| `+0x60` | char[16]  | model                      | text as stored |
| `+0x88` | uint16    | version code               | `vMAJOR.MINOR`: major = code / 100, minor = code % 100 -- the stamp the [mod001 version record](../deployment/mod001.md) bumps |
| `+0xdc` | char[32]  | build date                 | text as stored |
| `+0xfc` | char[32]  | build descriptor           | text as stored |
| `+0x11c`| char[16]  | build host                 | text as stored |

The record body extends past these fields (a peek of `0x18c` bytes from the base
captures them all). The string fields hold build-environment text; only their
**offsets and types** are documented here, never their contents.

---

**Next:** [services](services.md) ...
