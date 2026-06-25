# E80

folders: **Home** --
**[Architecture](architecture/readme.md)** --
**[Abstracts](abstracts/readme.md)** --
**[Deployment](deployment/readme.md)** --
**[Cleanroom](cleanroom.md)**

This page is the entry point for the documentation of an independent study of
the Raymarine E80 multifunction-display firmware. The material is organized in
**five axes** around the firmware artifact. Two axes describe what the firmware
*is*; two cover how we *work on* it; one is for *hand-off*.

## What the firmware is

- [**Architecture**](architecture/readme.md) -- the top-level structural
  picture (the **crown**) and the **factored design documents** beneath it: the
  runtime substrate and object model, the networked-service stack, the
  instrument-data fusion, the application model, and persistence. Roles and
  structure, inside the running firmware.
- [**Abstracts**](abstracts/readme.md) -- the conceptual layer. Each firmware
  service and subsystem described as it maps to the `/raymarine/NET` protocol
  implementations the project supports. Priority-ordered around the WGRT
  maintenance goal: the RAYNET umbrella over RAYDP, WPMGR, TRACK, FILESYS,
  DATABASE, FIDS (plus the ancillary TFTP, FishHistory, Config).

Architecture and Abstracts are the **same systems at two altitudes** -- the
firmware-side *design* (what the binary is) and the conceptual *trip through*
each subsystem (what it means for interoperability). They are meant to be read
as pairs (e.g. architecture `services` <-> abstract `RAYNET`; architecture
`persistence` <-> abstract `Config`).

## Working on the artifact

- [**Deployment**](deployment/readme.md) -- how the frozen image ships,
  installs, boots, and is modified: the DB1/DL1 container formats, the
  installer, the inferred stage-0 bootloader, and the proven modification
  scheme. The physical-form view; it shares the **NOR map** fact with
  Architecture and meets it at the inflate-to-RAM boot seam. It also carries
  the **mod001 diagnostics** peek/poke/call instrument.

## Hand-off

- [**Cleanroom**](cleanroom.md) -- safely-transferable wire
  specifications in protocol-spec form: the wire behavior, command/response
  shapes, and edge cases an implementation needs, suitable for handoff to a
  separate clean-room implementation.

**Next:** [Architecture](architecture/readme.md)
