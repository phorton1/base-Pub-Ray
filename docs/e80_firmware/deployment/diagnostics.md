# Diagnostics -- the peek/poke/call instrument

**[Deployment](readme.md)** --
**[containers](containers.md)** --
**[installer](installer.md)** --
**[bootloader](bootloader.md)** --
**[modification](modification.md)** --
**[mods](mods.md)** --
**diagnostics**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Cleanroom](../cleanroom.md)**

The instrument the project reads the **live device** with: a peek / poke / call
channel that answers the runtime questions static reading cannot reach (past
[the wall](../architecture/overview.md), section 8).

**This is OURS, not a device feature.** The native E80 exposes no such channel.
It exists only because of a modification we made (`mod001`) that re-purposes the
firmware's unadvertised Diagnostics service. It is named throughout the docs as
*how* the confirmed device facts were confirmed -- never as something the stock
firmware offers.

---

## 1. What it is built on (the native service)

The firmware hosts an **unadvertised** Diagnostics service -- a
`CLNetDiagnosticsServer` on **UDP 6667**, with a separate **echo-only TCP companion on 6668**, with no
`ServiceInfo`, so it never advertises and carries no catalog SID. Its wire frame
is the familiar RAYNET shape (command word with service id `0xdddd` in the high
half; reply-port carried in the request). Natively the **UDP** path dispatches exactly three opcodes -- ECHO (`0x00`),
CHECKSUM-VERIFY (`0x05`), and N2K-bus PGN insertion (`0x06`); the TCP companion
handles **ECHO only** (every other command word is silently dropped). The native service and its protocol are documented in
[abstracts/RAYDP](../abstracts/RAYDP.md); this doc is about what we did to it.

## 2. The modification (how the channel was made)

`mod001` re-purposes the silent **CHECKSUM-VERIFY** command (`0xdddd0005`),
which has no wire response and no observable side effect, into a debug handler.
The edit is length-preserving and every byte was verified against the
binary:

- The command's two helpers -- `verifyChecksumCmd` (`0x0053a808`) and
  `computeXorChecksum` (`0x0053a878`), **260 contiguous bytes** whose only xrefs
  are each other and the silent branch -- are overwritten with a hand-assembled
  ARM **peek/poke/call** handler.
- The silent branch at `0x0053af78` is rewritten to run the handler and then
  **fall into the existing echo path**, which already builds and sends the
  reply. No new transport code is written. Because that echo path is
  string-oriented, the handler returns its bytes **hex-encoded** (2 ASCII chars
  per byte) -- which is why a single peek reply is capped near 512 raw bytes
  (512 -> 1024 hex chars + frame approaches the Ethernet MTU); request-side bytes
  (poke/call tails) are raw.
- The other commands are untouched: the dispatch, the `0xdddd0006` N2K-insertion
  command, and the `0xdddd0000` ECHO command all still work (`r4`=0 and `r5`=this
  are callee-saved across the handler, so echo runs intact). Handler = 48
  instructions + 17 NOP pad = exactly 260 bytes.

It is built and installed through the standard pipeline (see
[deployment/modification](../deployment/modification.md)): the edit record,
the apply and build steps, manual CF install.

## 3. The three operations

Over the diagnostics frame, the handler implements:

- **peek** -- read N bytes of memory at an address;
- **poke** -- write bytes to an address;
- **call** -- call a function at an address (with arguments), returning its
  result.

Because the firmware runs `e80.bin` in place at VMA 0 (see
[architecture/runtime](../architecture/runtime.md)), an address in the binary is
the same address live -- a peek reads exactly the in-image bytes, and a call can
exercise a firmware routine on the running unit.

## 4. The client tooling

A small set of client tools drives the channel: a peek/poke/call client;
directory-tree and keyed-store listers built on it (walking the `\local` and
keyed faces over the wire); page-set and panelset read/write tools (a page set
through the path face, a panelset by key through the keyed face); a general
`\local` file reader/writer by path (STAT/size/read/hexdump, STAT-guarded write),
with which the per-window `CInstrumentatio0.lp` selector round-trip was proven
(the cached directory tree can lag NOR, so STAT-by-path is trusted over the
listing); and a runtime key resolver that walks `guidObjectRegistry` to each live
instrument app and reports its cached panelset key (`app+0xa88`) -- panelset keys
are volatile storage addresses, not fixed.

## 5. What it has settled

The instrument is the project's empirical channel past the runtime-wiring wall:

- **The live `\local` persistence, read off NOR over the wire.** The consolidated
  `\local\slotless\CMainApp0.lp` blob was peeked from the running unit, decoded
  field by field against [abstracts/Config](../abstracts/Config.md), and matched
  both the on-screen layouts and the live RAM copy **byte-for-byte** (History,
  2026-06-01) -- the finding that retired the old per-file page-set model (see
  [architecture/persistence](../architecture/persistence.md)).
- **N2K injection drives the display.** The native `0xdddd0006` command laid PGN
  128267 (Water Depth) onto the internal dispatch path and moved the on-screen
  depth, with no N2K hardware attached -- one of the wire proofs of the
  [instrument fusion](../architecture/instruments.md) (History, 2026-05-29).
- **Per-window panel selection is a 1-byte `\local` file, and a written one takes
  effect.** Poking `0x04` into a Data window's
  `\local\slot040203\CInstrumentatio0.lp` and power-cycling brought that window up
  on the **Sailing** panel (2026-06) -- proving the third persistence layer (the
  per-window selector) and the full write round-trip through the storage path, plus
  that panelset records are self-minted on instantiation at runtime-resolved keys.
  See [architecture/persistence](../architecture/persistence.md).
- **The unit's owner-id rides the reply header.** Every UDP reply stamps the
  unit's RAYNET source id -- the `[0xb2 | 24-bit unit]` owner-id that also prefixes
  its keyed-store records -- into the reply frame's `id` field (bytes 4-7), sourced
  from the system-info singleton (`SysInfo+0x50`). So the owner-id needed to re-key
  a panelset is readable with **zero peeks** from any reply; the echo-only TCP
  companion on 6668 does **not** stamp it (it zeroes those bytes).
- **The full config round-trip is proven end-to-end -- so no second firmware mod is
  needed.** Reading and restoring all three persisted layers was demonstrated on E80-2
  over this one channel: write a page set, power-cycle so the apps self-mint default
  panelsets at runtime-resolved keys, overwrite a minted panelset at its key, write the
  per-window selectors, power-cycle to apply -- and a customization a default panel can
  never have (a date field where the default shows cross-track error) duly appeared. The
  config backup/restore capability is therefore fully realized *through* `mod001`; the
  intended deliverable is a client library over this channel, **not** a second firmware
  modification. See [architecture/persistence](../architecture/persistence.md).

## 6. Scope and posture

The handler's capability is peek **and** poke **and** call. The live-device
exploration was read-only for a long stretch; it has since made its first
**writes** to NOR -- restoring a page set through the firmware's own write path,
verified byte-exact on hardware. Writing remains a separate, deliberate decision: capability is not a license to
use it. Each write is cooperative with the design (the firmware's own write
methods, reaching states the UI already reaches) and in service of preservation
-- not taken merely because the capability exists.

---

**Next:** [Home](readme.md) ...
