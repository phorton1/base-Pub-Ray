# Installer

**[Deployment](readme.md)** --
**[containers](containers.md)** --
**installer** --
**[bootloader](bootloader.md)** --
**[modification](modification.md)** --
**[mods](mods.md)** --
**[diagnostics](diagnostics.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Cleanroom](../cleanroom.md)**

How the upgrade actually runs: a denormalized picture of the installer's
behaviour, built on the container facts in [containers](containers.md).
The installer is `autorun.bin` (inflated from `autorun.dob`); it is loaded
and run from RAM by stage-0 (see [bootloader](bootloader.md)), non-
destructively, when a CF card is present.

## The operator-facing flow (hardware-observed)

Booting the installer presents an upgrade UI: a list of available packages
(showing `E80/120_App v5.69`), an "Upgrade Package Details" panel (title,
build time), and a "Local Unit Details" panel (product name, family, ID,
serial, worldmap versions, installed application version). Softkeys observed:

```
1 = Upgrade This Unit
2 = Upgrade Remote Unit
4 = Data Extraction   (writes/updates ARCHIVE.FSH to the CF card)
5 = Reboot
```

There is **no** "Factory Reset" softkey in this UI; FactoryReset is reached
by a different trigger (likely a held key at boot). "Data Extraction"
writing `ARCHIVE.FSH` is the operator-facing complement to the FSH ("Flash")
serialization of the WGRT/config region.

## What happens when you press "Upgrade This Unit"

**What is traced, and what is not.** The per-block stubs are decoded (the
flasher arithmetic below). The installer's **top-level sequencing** -- which
stubs "Upgrade This Unit" actually runs, and in what order -- is **not yet
traced**; it lives in autorun.bin's UI handler, unread. The list below is
therefore the mechanism, with the orchestration marked open.

What is solid:

1. **Select the package.** The chosen `.pkg` (DL1 envelope) on the CF card;
   the UI parsed its DB1 children to populate the list.
2. **Verify before writing.** The two byte-sum checksums (header then
   payload) are recomputed and gate the write; a mismatch aborts with
   "Checksum failed". (Whether all seven children are verified up front or
   each is verified as it runs is not established.)
3. **Run one or more action stubs.** Each stub is the embedded ARM code at
   its block's `+0x94`, handed its own typed record. A stub computes its
   NOR destination as `0x50000000 + offset`, bounds-checks `offset+length`
   against flash size, then drives the AMD/Spansion **erase + write**
   command sequence directly on the memory-mapped NOR (no RTOS/filesystem
   -- none exists in the installer context).
4. **Reboot.** stage-0 then finds the written application at `0x500a0000`,
   inflates it to RAM, and runs it (see [bootloader](bootloader.md)).

Because the three type-1 stubs are **byte-identical**, App2FSH, Reset2FSH,
and Demo2FSH perform the **same operation** -- erase the target region then
write their data into it: one flasher, one operation. The
application is the App2FSH case: its data
region *is* the following `E80/120_App` block, so App2FSH is what lays the
~9 MB compressed application into NOR at `0x500a0000`. The application is stored
**compressed**; boot-time stage-0, not the installer, inflates it.

**Open / corrected (do not treat the file order as the run order):**

- "Upgrade This Unit" almost certainly does **not** run all five stubs. The
  installer UI has no "Factory Reset" softkey, so `FactoryReset` is a
  separately-triggered action, not part of the upgrade. The five stubs are
  independent actions, not one ordered pipeline -- there is no run in which
  Reset2FSH writes a seed that FactoryReset then erases.
- The **`*2FSH` naming** = "X to Flash": `App2FSH` writes the application to flash,
  `Demo2FSH` the demo, and `Reset2FSH` the factory-reset baseline to flash.
  So `Reset2FSH` installs the reset *defaults* into NOR; the separate
  `FactoryReset` block is the erase action a user-triggered factory reset
  runs. How a running E80 invokes FactoryReset (the softkey-at-boot path)
  is an e80.bin question, not yet traced.
- `ClearFlash` erases a region at `0x50070000` whose contents we have **not**
  identified (it sits just above the inferred boot region). Calling it a
  "scratch region" earlier was a guess with no evidence.
- Whether each stub erases before writing on *every* run, or the
  erase/write extent semantics (the type-4 `word3`), is **not traced** --
  see the caution further below.

Tracing autorun.bin's UI handler would replace this open section with the
real per-softkey action list; that is the next step if the install
orchestration matters.

"Upgrade Remote Unit" (softkey 2) runs the same verification but ships the
blocks to another unit over Ethernet/NMEA/Seatalk/ST2/Radar rather than
flashing locally; the per-transport machinery is in the package's
`SoftwareUpgrades` code but is not covered here.

## Package verification (the checksum gate)

Before committing any block, the installer recomputes the two additive
byte-sum checksums defined in [containers](containers.md) and gates on
them, in two stages:

- **Stage 1 -- header checksum** (`FUN_0007fcc4` in autorun.bin). Runs
  while cataloguing blocks; gated to a header < 0x400 bytes (else reject).
  Sums header bytes `[0x00, dword[1])` except the 4 stored bytes at `+0x38`;
  compares to `dword[4]`. Guards against trusting a corrupt header's
  size/offset fields before acting on them.
- **Stage 2 -- payload checksum** (`FUN_0007fd94`). Sums the full payload
  `[dword[1], dword[1]+dword[2]+dword[3])` in 0x80000-byte (512 KB) chunks,
  kicking the watchdog between chunks; compares to `dword[5]`.

Either failure produces "Error : Checksum failed - Upgrade pakage is
corrupt" (the firmware's own spelling) and aborts. These are error-
detection sums only -- no signature, no crypto; recomputable by anyone.

The header checksum's range `[0x00, dword[1])` minus the 4 bytes at `+0x38`
**includes** the payload-checksum field at `+0x3C`: the header sum covers
(and so protects) the payload sum. The practical consequence for producing
a valid package is ordering -- the payload checksum must be computed and
stored before the header checksum is summed over it.

## How the installer walks the DOBs (two different walkers)

There are **two** ways the installer traverses a package's DOBs, and they are
not the same -- which matters enormously for a rebuild:

- **Listing (UI):** `FUN_0007f7e4` scans for the `DB1 ` magic on a 4-byte grid
  and validates the header checksum. This populates "Upgrade Packages
  Available". It finds a DOB wherever its (4-aligned) magic is, so a rebuild
  with valid checksums *lists* fine regardless of the length table.
- **Flashing (the one that matters):** `FUN_00080ee0` does **not** scan. The
  package is a **length-prefixed list** (count at DL1 `+0x38`, table at `+0x3c`
  = `0xBC`); each DOB has a 4-byte length immediately before it and the walk is
  `next = this + prefix + 4`, with `prefix = align_up(DOB covered, 4)`. The
  upgrade state machine (`FUN_000019d4`) fetches DOB *i* via this walk and
  flashes it.

The hard requirement for a rebuild, **independent of the checksums**: if you
change a DOB's size you must update **its length-prefix** (the 4 bytes before
the *next* DOB, i.e. at `align_up(prev covered, 4)`). A stale prefix makes the
flash walk overshoot into the middle of the previous DOB's data -- the walker
then reads garbage as the next DOB and the upgrade aborts with **"Upgrade DOB
ended unexpectedly"** even though the package lists and checksums perfectly.
This was the actual cause of the hardware rejections (App2FSH's prefix at
`0x8250` left at its stock value while the application payload grew); see
history (2026-05-30). Because the prefixes are 4-aligned and
each DOB follows its prefix, every list DOB also lands 4-aligned -- the
"alignment" seen earlier is a *consequence* of this structure, not a separate
rule.

## The payload length is stored twice, and both copies must agree

A type-1/type-3 block records its payload length in **two independent
fields**, and the installer reads them with **different** code paths:

- **header `dword[3]`** (`+0x34`, `= 0x10 + data length`) -- the payload
  checksum (`FUN_0007fd94`) sums `[dword[1], dword[1]+dword[2]+dword[3])` and
  compares to `dword[5]`. This is the *verification* path.
- **typed-record `word1`** (`record+0x04`, `= data length`) -- the flasher
  stub loads this (`ldr r4,[r5,#4]` in the type-1 stub) and uses it as the
  NOR bounds check, the write byte-count, and the progress denominator. This
  is the *flashing* path.

In every stock block the two agree (`word1 == dword[3] - 0x10`). If a rebuild
updates one but not the other, the package still passes all checksums (those
only consult `dword[3]`), but the flasher writes `word1` bytes -- so a stale
`word1` writes a **truncated** payload, and the DOB ends short of its declared
size, which the handler reports as **"Upgrade DOB ended unexpectedly"**
(`FUN_00001e1c`). This was the actual cause of the first hardware rejection,
and the truncated application was the resulting unbootable image; see
history (2026-05-30). For App2FSH (whose data region is the
E80/120_App block) a resize must update **both** fields.

A structural audit enforces both requirements
(4-byte alignment + `word1 == dword[3]-0x10` for every type-1/3 block) that
runs on every rebuild, independent of the checksums.

## Rebuilding a package (the inverse of the gate)

Producing a package that *passes* the gate above has been implemented and
exercised end-to-end on an **unmodified** payload (a null rebuild -- no
patch, bench only, nothing written to a device). This establishes that the container can be taken
apart and put back together with the checksums recomputed correctly,
independent of any modification.

Two rebuilds of `E_App_Upg_Uni.pkg`, both reassembled from carved parts:

- **Identity** (reusing the original gzip stream) reproduces the original
  package **byte-for-byte** (SHA-256 match) and verifies 14/14. Because the
  output -- every checksum field included -- equals Raymarine's own file,
  this proves the carve and checksum-recompute code reproduce the stored
  checksums exactly.
- **Resize** (inflate the application, confirm it equals `e80.bin`, re-gzip
  with a different compressor, rebuild) yields a gzip stream +1430 bytes
  larger, round-trips bit-exact back to the application, and the rebuilt
  package verifies 14/14 at the shifted child offsets.

The resize case is the meaningful one: it exercises the full length and
checksum **cascade** a real patch would trigger, and confirms it is handled
correctly:

- **E80/120_App block** -- typed-record gzip length (`+0x2B88`), header
  `dword[3]` (`= 0x10 + gzip length`), header checksum, payload checksum.
- **App2FSH block** -- header `dword[3]` and both checksums. App2FSH's
  forward-spanning data region *is* the E80/120_App block, so any change to
  that block's size and bytes propagates into App2FSH's record and sums.
- **Downstream offsets** -- `Demo2FSH` and `DemoSlides` shift by the size
  delta; their (unchanged) bytes re-verify at the new offsets.

What the bench alone could not establish -- whether the device's
boot-time inflater (see [bootloader](bootloader.md)) tolerates a
compressed payload of a length different from stock -- has since been
**settled on hardware**: a resized / re-compressed package installed and
booted (see *Building a modified package* below). It was never a checksum
question.

## Building a modified package

The bench rebuild above became an actual modification process. The build logic
lives in the cleanroom library `e80Firmware.pm` (the in-process engine navMate
uses); a thin command-line wrapper over it takes an input binary and an output
label (with optional stock-package, output-directory, builder, and version flags). It:

1. re-gzips the patched application image (the per-mod output of the byte patcher),
2. rebuilds the DL1 around it -- the full length/checksum cascade above
   (E80 record gzip length + `dword[3]`, App2FSH `dword[3]` + `word1` +
   its 4-byte length-prefix, downstream offset shift, both checksums per
   child), with the structural audit,
3. relabels the build descriptors -- build MACHINE / builder signature (header
   `+0x60`, 16 bytes) and build DATE (current GMT, `+0x40`, 32 bytes,
   stock format `"%a %d %b %Y %H:%M:%S GMT"`) into the DL1 header and all
   seven DB1 child headers -- then recomputes the byte-sum checksums in
   span-safe order.

There is no SHA or signature anywhere in the package (see *Package
verification*); a build only ever recomputes the additive byte-sum
checksums and fixes the length fields.

**Hardware-confirmed.** (This `e80_mod001` was a previous mod, since
reverted; the name is reused for the new mod. The build/boot proof here
stands on its own.) `e80_mod001` -- a single same-width ARM
instruction edit in the application (the TFTP enable gate, `beq -> b` at
`0x0029d650`) -- was built this way, installed, and booted on E80-4
(2026-05-31): the installer accepted it, stage-0 inflated the resized
application, the unit booted, Unit Info showed the builder signature + the build date, and
the user config was retained. So the relabel is booted-visible -- the
running application reads its build descriptors from the package header in NOR --
and, with the 2026-05-30 resize-pkg boot, the boot-time inflater is
confirmed to tolerate a resized / re-compressed gzip.

(What the modification *unlocked* is a separate question from whether it
installed: in this instance the enabled TFTP server turned out to serve
no files -- see [TFTP](../abstracts/TFTP.md). The build/flash mechanics
are proven regardless.)

## The action stubs

Each DB1 block carries an ARM **action stub** (the `dword[2]` code region)
that the installer runs to perform that block's operation. Two stub kinds:

- **type-1 "write-to-FSH" flasher** -- Reset2FSH, App2FSH, Demo2FSH. These
  three stubs are **byte-identical** (one shared SHA-256): a single generic
  flasher, parameterized entirely by its block's typed record. Each embeds
  a complete AMD/Spansion (AM29LV128M) NOR driver.
- **type-4 erase flasher** -- ClearFlash, FactoryReset. Similar to each
  other (not byte-identical to the type-1). Also embed the AMD command set.

The embedded NOR driver is the classic AMD/Spansion sequence: unlock cycles
to `0xAAA`/`0x554`, command bytes `0xAA/0x55/0xA0`(word-write)`/0x80`(erase
setup)`/0xF0`(reset), with a CP15 `cr7,cr6` cache-line clean + `cr1`/IRQ-
mask around each access (you cannot fetch from NOR while it is in command
mode). The stubs are self-contained -- they run at install time before any
RTOS or filesystem exists.

## Flash addressing: `dest = 0x50000000 + offset`

The destination of every flash operation is computed from the typed-record
words as **NOR base + byte offset** (`0x50000000` is the memory-mapped NOR
window; the offset is the per-block varying word). Confirmed in code
(2026-05-30), a literal `add` in both stub kinds:

```
type 1 (erase+write), stub main:
    r1 = record.word2  (= 0x50000000, base)
    r0 = record.word3  (= region offset)
    r6 = r0 + r1                  ; dest = 0x50000000 + offset
type 4 (erase), stub main:
    r6 = record.word2  (= 0x50000000, base)
    r3 = record.word1  (= region offset)
    r6 = r3 + r6                  ; dest = 0x50000000 + offset
```

(Type 1 and type 4 hold base/offset in different word slots; the
arithmetic is identical.) Both stubs **bounds-check** `offset + length`
against the flash size before issuing any erase/write -- an out-of-range
offset is rejected (a real safety property).

## The install actions (operations, not residency)

This table is **what each action does**, not what lives in flash (for the
residency map see [bootloader](bootloader.md)). Region *start* addresses
are code-confirmed; **erase extents are NOT fully traced** (see caution).

| Action | kind | start addr | operation (per-stub; run order NOT established) |
|--------|------|------------|-----------|
| ClearFlash   | erase (type 4) | `0x50070000` | erase a region just above the boot region; contents there not identified |
| Reset2FSH    | erase+write (type 1) | `0x50080000` | write the factory-reset baseline ("Reset to Flash"), ~15 KB |
| FactoryReset | erase (type 4) | `0x50080000` | erase that baseline region; a user-triggered factory reset, NOT part of an upgrade |
| App2FSH      | erase+write (type 1) | `0x500a0000` | write the application image ("App to Flash"); its record data **is** the E80/120_App block |
| Demo2FSH     | erase+write (type 1) | `0x50c40000` | write the demo content ("Demo to Flash") |

(Reset2FSH / App2FSH / Demo2FSH are the one byte-identical type-1 flasher,
so their "operation" is necessarily the same op -- erase+write --
differing only in the record that parameterizes it.)

App2FSH is the action that installs the application: its record's data
region is the entire E80/120_App block, which it erases-then-writes into
NOR at `0x500a0000`. As traced, App2FSH lays the (compressed) block into
NOR; it was not shown inflating during install. The boot-time inflation is
a separate, stage-0 concern (see [bootloader](bootloader.md)).

### Caution: erase extents are not decoded

The type-4 erase records carry words whose role as *extents* is **not
established**, and a naive reading is self-contradictory:

- FactoryReset `{0x50000000, 0x80000, 0x01000000}` read naively as
  "erase from `0x50080000` for ~15.5 MB" would run to `0x51000000` and wipe
  the application at `0x500a0000` -- but hardware proves a Factory Reset
  **preserves the application**. So that reading is wrong.
- ClearFlash's analogous arithmetic yields an "extent" of `0x10` (16
  bytes), absurd for a sector erase.

So the erase loop does something other than "erase N bytes from start"
(a sector list, an end marker, a masked range that skips the application -- not
yet traced). `0x01000000` = 16 MB = one AM29LV128M chip and is more likely
a boundary/marker than a region size. **No erase extent or WGRT-capacity
figure should be inferred from these words** until the erase loop is read.

(Terminology note: throughout these docs the NOR operations are called
**erase** and **write**. The chip's own command for writing a word is named
"Program" in the AMD/Spansion datasheet, but "write" is used here to avoid
confusion with the ARM-as-programmer and with the *program* the NOR
contains.)

## The bricking floor (stated carefully)

A wrong **flasher stub** or a wrong **dest/region field** could misflash --
but since the erase-extent encoding is not fully decoded, this is a caution,
not a precise bound. A wrong byte in the **application payload** (the E80/120_App
data) only yields a bad application image, recoverable by reflashing the
stock package, because the recovery actors (ClearFlash, App2FSH) are
independent of the application image's content. The modificational plan (patch the
application, rewrap, reflash) inherits the stock package's safe targeting because
it never touches the stubs or the dest fields.

---

**Next:** [bootloader](bootloader.md) ...
