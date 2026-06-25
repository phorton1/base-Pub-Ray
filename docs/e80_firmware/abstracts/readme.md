# Abstracts

**Abstracts** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**[DB_FIDS](DB_FIDS.md)** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The conceptual layer. The firmware's services and structures
described as they map to the /raymarine/NET protocol implementations
the project supports, plus other abstractions deemed useful to
remember. The umbrella doc (RAYNET) carries cross-cutting
synthesis -- threading model, timing implications, family-level
patterns. The per-service docs cover specific protocols, ordered by
project priority (WGRT maintenance is the core stated goal).

## Contents

Umbrella:

- [RAYNET.md](RAYNET.md) -- family-level synthesis: threading model, timing
  implications, common patterns across the SeatalkHS stack, and
  cross-cutting impacts on /raymarine/NET.

Per-service (priority-ordered):

- [RAYDP.md](RAYDP.md) -- service discovery and instantiation protocol;
  the complete service catalog mapped against observed SIDs; the
  gap surface of services that exist in firmware but are not yet
  implemented in /raymarine/NET.
- [WPMGR.md](WPMGR.md) -- waypoint manager service. The project's
  long-term goal: WGRT (waypoint/route/group/track) maintenance
  core.
- [TRACK.md](TRACK.md) -- track service, including the writer-mode
  discovery that enabled the first programmatic track upload to
  an E80 over Ethernet.
- [FILESYS.md](FILESYS.md) -- filesystem access service. Clean, usable wire
  interface; resolves negatively on the long-open question of
  whether FILESYS supports writing to the CF card.
- [DATABASE.md](DATABASE.md) -- database protocol: the transactional command
  envelope, registration mechanics, the 10/1 Hz tiered broadcast.
- [DB_FIDS.md](DB_FIDS.md) -- the FID catalogue the DATABASE/DBNAV
  protocol carries: the instrument-fid and application-fid tables, each
  with its ENC binding and meaning. A DATABASE component.
- [DB_DECODE.md](DB_DECODE.md) -- the record codec: the value-record byte
  anatomy, the ENC catalogue that decodes a value, and the A/B/X
  source-provenance stamp. A DATABASE component.

Ancillary abstractions (linked here, deliberately kept out of the
header menu and the Next cycle so further probes can be added
without churning the navigation):

- **[TFTP.md](TFTP.md)** -- standard RFC 1350 TFTP server compiled
  into e80.bin; listener bound on UDP 69 (wire-confirmed); both GET
  and PUT implemented; transfers gated by a single-byte flag
  normally flipped via a debug-shell text-CLI menu. Not part of
  /raymarine/NET; a generic file-transfer surface alongside the
  Raymarine wire services.
- **[FishHistory.md](FishHistory.md)** -- the fishfinder
  instrument-history service (firmware HistData, SID 0x16 / TCP
  2055, observed as `func22_t`); command structure and buffer
  geometry decoded; the project's name for the not-yet-implemented
  /NET service.
- **[Config.md](Config.md)** -- configuration of the persistent
  page sets and the Data application's data panels: the five page
  sets and their 600-byte on-flash layout blocks (consolidated in
  `\local\slotless\CMainApp0.lp`), the page-layout grammar, the
  application-ID table, and a preliminary outline of the
  recursively-divided data panels.

---

**Next:** [RAYNET](RAYNET.md) ...
