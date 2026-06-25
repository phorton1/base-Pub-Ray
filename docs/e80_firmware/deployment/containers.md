# Containers

**[Deployment](readme.md)** --
**containers** --
**[installer](installer.md)** --
**[bootloader](bootloader.md)** --
**[modification](modification.md)** --
**[mods](mods.md)** --
**[diagnostics](diagnostics.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Cleanroom](../cleanroom.md)**

Physical and data analysis of the firmware-distribution artifacts: the
DB1/DL1 container formats and every byte-level fact about the shipped files. This doc is a **dictionary of facts** -- structure, offsets,
field meanings, raw values. It deliberately describes no *behavior*: how
the installer acts on these bytes is in [installer](installer.md), the
presumed boot-time handling is in [bootloader](bootloader.md), and the
running image is in [runtime](../architecture/runtime.md).

## The shipped files

Two original CF-card files plus derivatives extracted from them. As of
2026-05-30 the entire firmware-upgrade path is unpacked: every block of
the `.pkg` is carved out and accounted for.

```
ORIGINALS (sacrosanct, byte-for-byte as Raymarine distributed them)
  autorun.dob       365,736 B   the standalone DB1 (Upgrade)
  E_App_Upg_Uni.pkg 9,919,444 B the DL1 envelope (the full installer)

DERIVATIVES (reproducible carves/inflations)
  autorun.bin       1,049,096 B inflated gzip from autorun.dob
  e80.bin          23,810,656 B inflated gzip from the E80/120_App block
  clearflash.bin        8,656 B ClearFlash block payload (type-4 stub)
  app2fsh.bin           9,172 B App2FSH action-stub (type-1 stub)
  reset2fsh.bin         9,172 B Reset2FSH action-stub (byte-identical to app2fsh)
  demo2fsh.bin          9,172 B Demo2FSH action-stub (byte-identical to app2fsh)
  factoryreset.bin     14,860 B FactoryReset action-stub (type-4 stub)
  demoslides.bin      626,056 B DemoSlides media payload (type-2)
```

The two originals are sacrosanct: never re-derived, renamed, or modified.
Every other file is a deterministic derivative -- a gzip inflation or a
byte-exact carve of a DB1 child -- reproducible from the originals (a complete SHA-256 manifest backs them). The three type-1 stubs are **byte-identical** (one shared hash).

`v5.69` is the final firmware version Raymarine released for the E80. The
shorthand `e80.bin` covers both the E80 and E120 -- the source DB1 child
is named `E80/120_App` and the firmware runs unchanged on both.

## DB1 and DL1 formats

Two related container formats, both plaintext at the header level:

| Extension | Magic at offset 0 | Role |
|-----------|-------------------|------|
| `.dob`    | `DB1 ` | A single Data Block. Standalone artifact on the CF card. |
| `.pkg`    | `DL1 ` | A Download envelope: one or more DB1 blocks laid end-to-end. |

Both share a 36-byte banner:

```
+0x00 .. +0x13   20-byte ASCII name field, right-padded with spaces
+0x14 .. +0x23   16-byte ASCII version field, right-padded with spaces
+0x24 .. +0x27   4-byte terminator: 0x0D 0x0A 0x1A 0x00
```

The terminator is the conventional DOS "stop the `type` command after the
banner" sequence -- the first 36 bytes of any DB1/DL1 are safe to print to
a console and reliably identify the artifact.

After the banner, a table of little-endian 32-bit words at `+0x28`.
(Throughout these docs, ARM convention: a "word" is 32 bits. The header
table fields are labelled `dword[N]`; the typed-record fields below are
labelled `word1/2/3`. Both mean the same 32-bit little-endian quantity --
which is why a single field can hold a 9 MB length.)

```
+0x28   dword[0]   FLAGS / TYPE       (clusters by block purpose; table below)
+0x2C   dword[1]   header length / payload-start offset (always 0x94 observed)
+0x30   dword[2]   ARM action-stub length          ("d2")
+0x34   dword[3]   typed-record total length        ("d3"; = 0x10 + data length)
+0x38   dword[4]   header checksum    (additive byte-sum)
+0x3C   dword[5]   payload checksum   (additive byte-sum)
```

The checksum-covered payload is `[dword[1], dword[1] + dword[2] +
dword[3])`: the `dword[2]` action-stub immediately followed by the
`dword[3]`-byte typed record. `dword[2]` and `dword[3]` are two distinct
lengths -- the action-stub length and the typed-record length, not two
halves of one size.

`dword[0]` clusters by block purpose -- a type/capability field, not a
checksum:

| dword[0] (LE hex) | Blocks |
|-------------------|--------|
| `0x00000001` | Upgrade (autorun.dob), App2FSH |
| `0x00000004` | ClearFlash, Reset2FSH, FactoryReset |
| `0x00001000` | Demo2FSH, DemoSlides |
| `0x80000000` | E80/120_App (the main firmware image) |

The metadata fields after the dword table carry plaintext build
descriptors in fixed ASCII fields. Two are pinned (2026-05-31):

```
+0x40 .. +0x5F   32-byte build DATE, e.g. "Tue 29 May 2012 13:50:10 GMT"
                 (strftime "%a %d %b %Y %H:%M:%S GMT"), space-padded + NUL
+0x60 .. +0x6F   16-byte build MACHINE/host, e.g. "gbLinux", space-padded + NUL
```

Both lie inside the header-checksum range `[0x00, dword[1])`, so editing
them requires recomputing `dword[4]` (the relabel step does this -- see
[installer](installer.md)). They appear in the DL1 envelope header
(base 0) and in every DB1 child header. No technical protection
measure -- no encryption, signature, or opaque blob -- is present. The
only integrity mechanism is the pair of additive byte-sum checksums
(fields `dword[4]`/`dword[5]`; the installer's verification of them is in
[installer](installer.md)).

## Checksum fields (facts)

Two independent additive byte-sums, accumulated into a 32-bit int -- no
CRC polynomial, no keyed MAC, no signature; error-detection only, and
recomputable by anyone.

- **Header checksum** (`dword[4]`, `+0x38`): sum of header bytes
  `[0x00, dword[1])` excluding the 4 bytes of the stored value at `+0x38`.
- **Payload checksum** (`dword[5]`, `+0x3C`): sum of the payload bytes
  `[dword[1], dword[1] + dword[2] + dword[3])`.

Empirically confirmed against `E_App_Upg_Uni.pkg` (2026-05-30): for
all seven DB1 children both recomputed sums equal the stored values
(14/14); `dword[1]` is `0x94` for every child. (The installer recomputes and gates on
these -- see [installer](installer.md).)

## Typed record (the per-block descriptor)

Every DB1 block is `[0x94 header][dword[2] bytes ARM stub][typed record
of dword[3] bytes]`. The typed record begins with a 16-byte head:

```
+0x00   tag      low16 = TYPE, high16 = data offset within record (0x10 normal)
+0x04   word1
+0x08   word2
+0x0C   word3
+0x10   data     (for data-bearing types; data length = dword[3] - 0x10)
```

The 16-byte "transition header" of the gzip blocks (below) is the **same
structure** -- one mechanism, not two. `0x00100003` at the front of a gzip
block is this tag: type 3, data at +0x10.

Observed record types, with **raw** word values (interpretation -- how
these drive flash writes -- is in [installer](installer.md); the words
here are stated only as facts):

| Type | Blocks | word1 | word2 | word3 |
|------|--------|-------|-------|-------|
| 1 | Reset2FSH, App2FSH, Demo2FSH | data length | `0x50000000` | (varies) |
| 3 | E80/120_App, autorun.dob | gzip length | 0 | 0 |
| 4 | ClearFlash, FactoryReset | `0x50000000` | (varies) | (varies) |
| 2 | DemoSlides | `0x0c` | `0xdf64` | `0xed4c` |

Per-block raw words (the varying fields):

```
            tag         word1       word2       word3
ClearFlash  type4       0x50000000  0x00070000  0x00070010
Reset2FSH   type1       0x00003ab0  0x50000000  0x00080000
FactoryReset type4      0x50000000  0x00080000  0x01000000
App2FSH     type1       0x008d022e  0x50000000  0x000a0000
E80/120_App type3       0x008cd69a  0x00000000  0x00000000
Demo2FSH    type1       0x0009 8e5c 0x50000000  0x00c40000
DemoSlides  type2       0x0000000c  0x0000df64  0x0000ed4c
```

`0x50000000` recurs as a constant; the other varying words include
`0x80000`, `0xa0000`, `0xc40000`, `0x01000000`. What these *mean* as flash
addresses/sizes is decoded in [installer](installer.md) and the resident
picture is in [bootloader](bootloader.md). Note (fact, not yet
interpreted): the `0x01000000` in FactoryReset's word3 equals 16 MB = one
AM29LV128M chip; its role is not established and should not be read as an
erase size (see installer.md caution).

Two structural facts about the data-bearing types:

- A type-1 block's data region begins exactly at the **next block's
  boundary** (its data pointer lands on the next `DB1 ` magic). Reset2FSH's
  data starts at FactoryReset, App2FSH's at E80/120_App, Demo2FSH's at
  DemoSlides. So the package is laid out as **stub+payload pairs**: a small
  action stub followed by the bytes it operates on. App2FSH's data region
  (`0x8d022e` bytes) **is** the entire E80/120_App block (hence their
  near-identical payload checksums).
- `dword[3]` for a type-1 block therefore spans forward into the following
  block; the checksum still verifies because it is computed over that same
  forward span.

## DL1 envelope of `E_App_Upg_Uni.pkg`

The DL1 envelope occupies the first 0xC0 (192) bytes and is a **length-prefixed
list** of DOBs (download objects = DB1 children). The DL1 header carries the
list bookkeeping: `dword` at `+0x38` = **DOB count** (`0x04` here), `+0x3c` =
**offset to the length table** (`0xBC`). At `0xBC` sits the first DOB's 4-byte
length; each DOB is immediately preceded by its own 4-byte length, and the
upgrade walks them as `next = this + prefix + 4`, where
`prefix = align_up(DOB covered length, 4)` (the upgrade's `FUN_00080ee0` --
see [installer](installer.md)). So the bytes between one DOB's checksum-covered
region and the next DOB are **not padding** -- they are `[0-3 align bytes][the
next DOB's 4-byte length-prefix]`. (Only **four** DOBs are in the list:
`FactoryReset`, `E80/120_App`, and `DemoSlides` are not list entries -- they
are the forward-spanning *data* of the type-1/type-3 DOB before them. A
separate magic-scanning walk, `FUN_0007f7e4`, is used only for *listing* the
package in the UI.) Every list DOB starts 4-aligned as a consequence of the
4-aligned prefixes.

| # | Offset (file) | Name           | Version | dword[0]     | Block size |
|---|---------------|----------------|---------|--------------|-----------:|
| 1 | `0x000000C0`  | `ClearFlash`   | v0.01   | `0x00000004` |      8,808 |
| 2 | `0x00002328`  | `Reset2FSH`    | v0.01   | `0x00000004` |      9,336 |
| 3 | `0x000047A0`  | `FactoryReset` | v0.01   | `0x00000004` |     15,028 |
| 4 | `0x00008254`  | `App2FSH`      | v5.69   | `0x00000001` |      9,336 |
| 5 | `0x0000A6CC`  | `E80/120_App`  | v5.69   | `0x80000000` |  9,241,140 |
| 6 | `0x008DA900`  | `Demo2FSH`     | v0.01   | `0x00001000` |      9,336 |
| 7 | `0x008DCD78`  | `DemoSlides`   | v0.01   | `0x00001000` |    626,268 |

"Block size" is the physical span to the next block (so it includes each
block's trailing align bytes + the next block's 4-byte length-prefix); for the
final `DemoSlides` block it is the span to end-of-file. Sum of the seven block
sizes plus the 192-byte DL1 header is exactly **9,919,444 bytes = the file
size** -- there is no tail.
The version field is `v0.01` on every block except the two app-bearing ones
(`App2FSH`, `E80/120_App` = `v5.69`): the scaffold is stable and only the
application carries real version churn.

## Block contents (facts)

- **ClearFlash** (type 4) -- ~8.6 KB ARM stub embedding an AMD/Spansion
  NOR command set; record `{0x50000000, 0x70000, 0x70010}`, no data.
- **Reset2FSH / App2FSH / Demo2FSH** (type 1) -- byte-identical ~9.2 KB ARM
  stubs (one shared SHA-256); each has a record naming `0x50000000` and a
  per-block varying word, plus a forward-spanning data region.
- **FactoryReset** (type 4) -- ~14.9 KB ARM stub; record
  `{0x50000000, 0x80000, 0x01000000}`, no data.
- **E80/120_App** (type 3) -- the gzip-compressed application
  (~9 MB compressed -> `e80.bin`, 23.8 MB inflated).
- **DemoSlides** (type 2) -- ~626 KB media payload; record data offset is
  `0x38` (not `0x10`); content begins `0xFF`-filled; internal format not
  identified.

## The loader+header+gzip layout (gzip blocks)

`autorun.dob` and the `E80/120_App` block share this block-relative
layout:

- `0x00..0x93` -- container header
- `0x94..0x2B83` -- ~10 KB ARM32 decompression loader stub
- `0x2B84..0x2B93` -- 16-byte transition header (= the typed record, type 3)
- `0x2B94..end` -- RFC 1952 gzip stream

The transition header:

```
+0x2B84  LE32 tag      = 0x00100003   (type 3, data at +0x10)
+0x2B88  LE32 length   = byte length of the gzip stream that follows
+0x2B8C  8 reserved zeros
```

The `+0x2B88` length is verified to be the exact gzip-stream length:
truncating to it and inflating yields a clean single-member RFC 1952
stream whose trailer CRC32 and ISIZE both check. For `autorun.dob` the
gzip fills the rest of the file; for `E80/120_App` there are 6 bytes of
padding (`00 00 D4 B2 09 00`) before the next child (origin unknown).

gzip OS field and FNAME differ by build host:

| Source | gzip OS | FNAME |
|--------|---------|-------|
| `autorun.dob` | 11 (NTFS) | `upgrade.mem` |
| `E80/120_App` | 3 (Unix) | `app.bin` |

## The loader stub (facts)

The ~10 KB region `[0x94..0x2B83]` is **byte-for-byte identical** between
`autorun.dob` and `E80/120_App`; the only diff in the stub+header region is
the LE32 length at `+0x2B88`. Same code, parameterized per payload. It is
a self-contained Green Hills MULTI ARM application:

- Cold-start entry at `0x94`: reads TTBR (CP15 c2,c0,0), derives a
  workspace base (`r9`) and stack from the page-table base, then `bl` to a
  function at `0x1900`.
- `0x1900` is the GHS MULTI init dispatcher -- byte-identical in prologue
  and PC-relative table walking to the dispatcher at `0x2afe8c` of
  `e80.bin`; invoked with `r0` -> a static boot descriptor at `0x1948`
  (all zeros observed).
- A deflate decoder (gzip-flag parse, 32 KB window at workspace `+0x715`,
  Huffman builder, byte-emitter at `+0x5e8`) occupies the bulk.
- A separate entry at `0xd0` takes a "blob record" pointer and invokes the
  decoder. The boot-time invoker is now identified: the resident boot code
  verifies the two byte-sum checksums and calls the `0x94` cold-start entry
  with the record pointer. A NOR-resident, read-only program (the app, the
  splash, the demo) runs **in place from flash** -- NOR is memory-mapped, so
  the stub executes straight out of NOR; only the installer (`autorun.dob`,
  read off the CF) and the NOR-erasing flasher blocks are first copied into
  RAM. One DOB-run primitive either way -- see [bootloader](bootloader.md).

## Heuristic for unfamiliar DB1 blocks

- Size >= ~12 KB: likely loader+header+gzip. Check `+0x2B84` starts
  `03 00 10 00`, read LE32 length at `+0x2B88`, validate gzip at `+0x2B94`.
  The embedded FNAME says what the block delivers.
- Size < ~12 KB: too small for that pattern; likely pure ARM stub with no
  embedded compressed payload.

## What's not characterized

- The 6 bytes of padding after the `E80/120_App` gzip stream.
- `DemoSlides` internal format (no gzip/xz/bzip2/pkzip magic).
- Whether the five small stubs carry a 16-byte transition header (all under
  the ~11 KB gzip minimum, so probably not).
- The meaning of `word3`/`word2` extents for the erase (type 4) records --
  raw values only; see [installer](installer.md).

---

**Next:** [installer](installer.md) ...
