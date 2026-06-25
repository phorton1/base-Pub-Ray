# Bootloader

**[Deployment](readme.md)** --
**[containers](containers.md)** --
**[installer](installer.md)** --
**bootloader** --
**[modification](modification.md)** --
**[mods](mods.md)** --
**[diagnostics](diagnostics.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Cleanroom](../cleanroom.md)**

Stage-0: the resident boot code that runs from reset, owns the NOR flash
layout, and performs the **inflate-to-RAM** primitive that both the
installer and normal boot depend on. It lives in the bottom of the internal
NOR, below the application, and loads every program -- the splash, the
application, the installer -- as a DB1 "DOB" through a single run primitive
(below). The mechanism here is established; where a detail is still
inference it is marked.

## Why stage-0 is separate from the application

`e80.bin` contains none of the update-loading vocabulary -- no `autorun`,
`.dob`, `DB1`, `DL1`, or `upgrade` strings. So the running application is
not what detects a CF card or chain-loads the installer. Something earlier
does, and it is in neither `e80.bin` (the *output* of inflation) nor the
install-time stubs (which run only during an upgrade). This earlier code
is **stage-0**.

## Where stage-0 lives

The internal NOR is a single 16 MB AM29LV128M -- the E-series ships with
only one flash chip populated (the board carries pads for a second, left
unpopulated on production units). The installer's
write actions populate these offsets (see [installer](installer.md) for
the decode):

```
NOR base 0x50000000   (16 MB total, single AM29LV128M)
  +0x000000 .. 0x070000  (448 KB) -- written by NOTHING in the package
  +0x070000              ClearFlash erase target (contents not identified)
  +0x080000              install-time config seed (Reset2FSH writes ~15 KB)
  +0x0a0000              the application (compressed)
  +0xc40000             demo content (ends ~0xcd8000)
  +0xcd8000 .. 0x1000000 (~3.2 MB) -- written by NOTHING in the package
```

The bottom **448 KB (`0x50000000 .. 0x50070000`) is written by no action
in the upgrade package.** That is the signature of a protected boot region:
the place stage-0 itself lives, which the package deliberately never
rewrites so an upgrade cannot brick the bootloader. NOR is memory-mapped
and execute-in-place, so the ARM can fetch from it at reset (the reset
vector aliased/remapped into this region).

The application being **not** at offset 0, and the bottom region being left
untouched by the upgrade, both follow from how the boot code works: it
resides in this bottom region, scans the rest of NOR for the `DB1 `
programs, and inflates the application to RAM (the reason the application is
not stored at offset 0). The upgrade never rewrites this bottom region, so
an upgrade cannot brick the boot code.

## The NOR residency map (what permanently lives in flash)

After an install, NOR holds the following. Only the **install-written**
regions have decoded start addresses; the region above the demo content the
installer does not touch -- it is likely NOR managed by the runtime (see
[runtime](../architecture/runtime.md)).

| NOR region | offset | contents | accessed as |
|------------|--------|----------|-------------|
| boot region | `0x50000000` | **stage-0** (inferred) | executed at reset |
| config seed | `0x50080000` | small install-time seed (~15 KB written) | data |
| application | `0x500a0000` | compressed application image | inflated to RAM at boot |
| demo content | `0x50c40000` | demo media (~625 KB) | data, read by application |
| runtime region | above the demo region | likely NOR managed by the runtime | not written by the installer |

The install seed at `0x50080000` is just a ~15 KB factory-reset baseline
(Reset2FSH), not a live store. Everything above the demo region
(`~0x50cd8000 .. 0x51000000`) the package leaves alone -- likely NOR managed
by the runtime; its driver and bounds are a runtime concern (see
[runtime](../architecture/runtime.md)).

The boot runs a short sequence of DOBs (splash, FactoryReset, demo, then the
application), but only the **application** stays resident -- the earlier
programs run and hand back, releasing any RAM they used (see the DOB-run
primitive below). The config and
demo regions are **data** the running application reads (settings /
navigation data via the runtime filesystem; demo media drawn by the
application). Region *start* addresses are code-confirmed (installer.md); the
runtime filesystem's driver and bounds are a runtime concern, covered in
[runtime](../architecture/runtime.md).

## The DOB-run primitive (one mechanism, every program)

Stage-0 contains no decompressor of its own. Every program it loads is a DB1
container (a "DOB") that carries its **own** loader stub -- the ~10 KB ARM
deflate decoder documented in [containers](containers.md). Stage-0's job is
to find each DOB, verify it, and hand off to that stub:

1. Verify the container's two additive byte-sum checksums (header + payload).
2. Get the stub somewhere it can run. A NOR-resident **read-only** program
   (the app, splash, demo) runs **in place** -- NOR is memory-mapped, so the
   stub executes straight from flash and reads its gzip from flash. A program
   that *can't* run in place is copied into RAM first: the installer (read off
   the CF, which is not memory-mapped) and the flasher blocks (which erase NOR,
   so they cannot run from it).
3. Call the stub's `0x94` cold-start entry; the stub inflates the gzip payload
   to its destination and runs it.

So the only thing that necessarily lands in RAM is each program's **inflated
output** -- the compressed container of a NOR program never enters RAM. The
RAM-copied programs are small (the installer, the ~15 KB flashers), fit in
stage-0's small heap, and release that RAM when they finish. This one
primitive serves both situations:

1. **Installer boot** (CF card present): stage-0 opens the CF "Boot FS"
   volume, reads `autorun.dob` into RAM, and runs it through the primitive.
   **Hardware-confirmed non-destructive**: it runs from RAM and is never
   flashed over the application.
2. **Normal boot** (no CF, the everyday case): stage-0 scans NOR for the
   `DB1 ` programs and runs them in priority order -- the splash and
   FactoryReset programs first, the demo and the application last.

The application must be inflated because it cannot run in place (gzip in
NOR) and is far too large to store uncompressed (~23.8 MB inflated vs an
~11.6 MB NOR slot). Its stub -- running in place from flash -- inflates it to RAM
**`0x00000000`** (the base
`e80.bin` is built for -- see [runtime](../architecture/runtime.md)) and
jumps in; the application never returns, so it is the resident final image.

## What stage-0 knows

- How to find each program: it scans NOR for the `DB1 ` signature, and reads
  `autorun.dob` from the CF "Boot FS" volume.
- Where to place the inflated application (RAM `0x0`) and to jump there.

Factory Reset **is** a distinct boot program: dedicated FactoryReset DOBs sit
early in the NOR scan and run before the application. What arms the soft-key
countdown is still being characterized. Demo is a persistent flag the
already-running application reads (hardware-confirmed -- the application runs
underneath the slideshow, simulating); the DemoSlides block supplies its
media. There is one application image; runtime behaviour is selected by flags
and by which data regions the application reads.

## Status (established vs open)

The DOB-run mechanism above -- the CF/NOR program finder, the per-DOB
verify and hand-off (copy to RAM only where a program can't run in place),
and the inflate-to-RAM step done by the container's own loader stub -- is
established. The boot-time inflater **is** the install
loader stub (the same `d2` decompressor documented in
[containers](containers.md)); there is not a second, separate decompressor.
What remains open is narrower: the exact power-on/standby discrimination, and
the trigger path of the soft-key Factory Reset countdown (the FactoryReset
DOBs that run early are identified; what arms them is not yet pinned).

---

**Next:** [modification](modification.md) ...
