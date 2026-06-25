# Architecture

**Architecture** --
**[overview](overview.md)** --
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

What the firmware binary IS, once it is running. This axis is a **highest-level
design** -- the crown -- and the **factored design documents** beneath it, one
per major structural concern of the running artifact.

Two views of the artifact live in their own axes: how the frozen image is
packaged, installed, and booted is [Deployment](../deployment/readme.md) (the
physical-form view, which shares the NOR map with this one).

## The crown

- [**overview.md**](overview.md) -- the top-level structural picture of
  the E80, device and software, distilled from all four sources (firmware,
  device, manuals, the external corpus). Aloof by design: it names the *kinds*
  of thing and the *roles* they play. It is the reading test for everything
  below; a noun with nowhere to hang is a defect in a sentence, not a gap in the
  reader.

## The factored design documents

- [**runtime.md**](runtime.md) -- the running artifact: image layout and `.bss`,
  the reset prelude and position-independent linkage, the Green Hills MULTI
  init driver, the toolchain/runtime banners, and the **RayCom** object model
  (the in-process COM-like component system the application layer is built from)
  plus the class registry that survives a reboot.
- [**services.md**](services.md) -- the networked-service architecture: the
  `CLNet*` family, the per-service Server/Source/ServiceInfo/Connection roles,
  the RAYDP discovery dispatcher, the ThreadX wrapper layer, the two-object
  pattern, and the inlined-serviceLoop dispatch. (Pairs with the conceptual
  [abstracts/RAYNET](../abstracts/RAYNET.md).)
- [**instruments.md**](instruments.md) -- the **heart**: how four protocol
  worlds (Seatalk1 / NMEA0183 / NMEA2000 / SeaTalkHS) fuse into one
  instrument-data model via a proxy-per-source, and how every consumer draws
  from it.
- [**applications.md**](applications.md) -- the on-screen model: the
  page-set / page / window / app containment, the ~11 applications, the
  instrument-app panel grid, and the configuration-UX layer. (Pairs with the
  conceptual [abstracts/Config](../abstracts/Config.md).)
- [**persistence.md**](persistence.md) -- how settings survive power cycles: the
  schema-driven `\local` framework, the flob keyed store, the consolidated
  page-set blob, the slot context key, and the instrument database. (Pairs with
  [abstracts/Config](../abstracts/Config.md).)

Architecture and [Abstracts](../abstracts/readme.md) describe the **same systems
at two altitudes** -- the firmware-side design here, the conceptual trip through
each subsystem there. Read them as pairs.

---

**Next:** [overview.md (the crown)](overview.md) ...
