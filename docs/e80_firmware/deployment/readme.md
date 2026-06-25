# Deployment

**Deployment** --
**[containers](containers.md)** --
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

How the frozen firmware image **ships, installs, boots, and is modified** -- the
artifact in its physical, deployable form, mapped to load addresses rather than
to objects.

This is the **deployment / physical-form** projection of the artifact. The
[Architecture](../architecture/readme.md) axis is the other projection (the
running object model). They are not rival roots: they **meet at one seam** -- at
boot the image is inflated from NOR into RAM -- and **share one fact**, the NOR
flash map.

## Contents

The story runs outside-in: the bytes, then how they are written, then how they
boot, then how we make our own.

- [**containers.md**](containers.md) -- a dictionary of byte-level facts about
  the DB1/DL1 container formats and every shipped file: banner, dword table,
  typed records, checksums, the loader+gzip layout. No behavior.
- [**installer.md**](installer.md) -- how the upgrade runs: the two byte-sum
  checksum gates, the length-prefixed DOB walk, the byte-identical flasher
  stubs, `dest = 0x50000000 + offset`, and the install actions. Denormalizes the
  container facts into behavior.
- [**bootloader.md**](bootloader.md) -- the inferred stage-0: the protected NOR
  boot region, the NOR residency map, and the inflate-to-RAM primitive shared by
  the installer and normal boot. Largely presumed (stage-0 is beyond the
  artifact horizon).
- [**modification.md**](modification.md) -- the proven scheme for producing a
  modified image and installing it on the owner's own hardware: the record format,
  the build pipeline, the safe-targeting floor, and the hardware-confirmed boot.
  Cooperative with the design, additive, and bounded (see its Posture).
- [**mods.md**](mods.md) -- the catalog of the specific mods: the index (mod001
  diagnostics, mod002 screen grab, mod003 timed tracks), the version assignments, what each package
  contains, and the per-mod design pages.

---

**Next:** [containers](containers.md) ...
