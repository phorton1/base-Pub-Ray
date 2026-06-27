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

Additional (unimplemented) services -- RAYDP catalog services whose wire
protocol is decoded here but which are not yet implemented in
/raymarine/NET. Linked from here and from the RAYDP catalog's Pub::Ray
column, but deliberately kept out of the header menu and the Next cycle
so services can be added without churning the navigation:

- **[FishHistory.md](FishHistory.md)** -- the fishfinder
  instrument-history service (firmware HistData, SID 0x16 / TCP
  2055); command structure and buffer
  geometry decoded; the project's name for the not-yet-implemented
  /NET service.
- **[AutoPilot.md](AutoPilot.md)** -- the autopilot service (firmware
  AutoPilot, SID 0x09 / UDP); the five-message protocol and the 61-byte
  NewPilotData report decoded, including the SetPilotStatus control path;
  a natural candidate for a /NET decoder.
- **[GPS.md](GPS.md)** -- the GPS service (firmware GPS, SID 0x08 / UDP);
  the ten-message protocol decoded -- one 626-byte UpdateGPSStatus report
  (scalar fix block + two 32-entry satellite tables) and nine receiver
  configuration commands.
- **[Compass.md](Compass.md)** -- the compass service (firmware Compass,
  SID 0x1a / UDP); the five-message protocol decoded -- a 25-byte
  UpdateCompassStatus report plus three calibration actions and a
  SetHeadingOffset command.
- **[Navtex.md](Navtex.md)** -- the NAVTEX service (firmware Navtex, SID
  0x1d / UDP); a message-store protocol -- chunked MessageUpdate reassembly
  plus AlertCleared / MessageDeleted mutations and a get-all replay.
- **[AIS.md](AIS.md)** -- the AIS service (firmware AIS, SID 0x1e / UDP);
  a thirteen-message database protocol -- target store, alarm list,
  safety-related messages and transceiver state, and six commands
  including a unicast GetAllSRMs reply.
- **[Sonar.md](Sonar.md)** -- the sonar / fishfinder service, both
  generations: Sonar2 (SID 0x18) and Sonar3 (SID 0x20), one user-facing
  "Fishfinder". The shared 0x18 ping/echo stream plus each generation's
  configuration messages decoded; report-only, no command surface.

Ancillary abstractions -- useful write-ups that are not RAYDP catalog
services, kept out of the header menu under the same rationale:

- **[TFTP.md](TFTP.md)** -- standard RFC 1350 TFTP server compiled
  into e80.bin; listener bound on UDP 69 (wire-confirmed); both GET
  and PUT implemented; transfers gated by a single-byte flag
  normally flipped via a debug-shell text-CLI menu. Not part of
  /raymarine/NET; a generic file-transfer surface alongside the
  Raymarine wire services.
- **[Config.md](Config.md)** -- configuration of the persistent
  page sets and the Data application's data panels: the five page
  sets and their 600-byte on-flash layout blocks (consolidated in
  `\local\slotless\CMainApp0.lp`), the page-layout grammar, the
  application-ID table, and a preliminary outline of the
  recursively-divided data panels.

---

**Next:** [RAYNET](RAYNET.md) ...
