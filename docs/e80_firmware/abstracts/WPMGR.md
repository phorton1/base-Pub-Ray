# WPMGR

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**WPMGR** --
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

Waypoint manager service. The project's long-term goal: WGRT
(waypoint/route/group/track) maintenance core.

WPMGR implements the firmware side of Waypoint, Route, and Group
management on the E80. This is the core
of WGRT maintenance -- the long-stated project goal that navMate
ultimately targets.

WPMGR runs as a TCP service. One connection per client; each
connection opens a per-client thread on the E80 that handles the
client's commands and emits notifications when relevant state
changes externally (another client modifying a waypoint, etc.).
The implementation cross-references to the
`%WPMGR_PARSE_RULES` table in `/raymarine/NET/e_wp_defs.pm`,
which is essentially complete on the request/notification side
that empirical observation could see.

## Command vocabulary

WPMGR speaks 32-bit command words encoding service+direction+
context+command. The cross-cutting structure is **W (context)**
crossed with **C (command nibble)**:

**W context:**
- Waypoint
- Route
- Group
- (additional ranges exist for Database operations)

**C command nibble:**
- 0 -- CONTEXT
- 3 -- ITEM
- 4 -- EXIST
- 5 -- EVENT
- 6 -- DATA
- 7 -- MODIFY
- 8 -- UUID
- c -- FIND
- d -- COUNT
- e -- EVERB (Route and Group only)
- f -- FVERB (Route only)

Almost all C-nibble commands exist in all three W contexts. The
firmware implements this as **template specialization**: one
handler concept per C-nibble parameterized by W context type,
with all specializations inlined into the per-Connection thread.
A given variable in the Waypoint specialization of (say)
ITEM has the same role as the corresponding variable in the Route
specialization -- the empirical findings for one context
extrapolate confidently to the others.

## The SEND CMD_EVENT discovery

The `%WPMGR_PARSE_RULES` table records `CMD_EVENT` (C=5) only on the
**RECV** direction -- the firmware emits events but client code is
not known to send them. The firmware exploration confirmed a real
handler at the **SEND** side for `CMD_EVENT` in all three W
contexts. This is exactly the kind of capability the firmware
exploration was hoped to surface: a client can potentially send
events TO the E80, which empirical observation (mimicking RNS)
never captured.

What the SEND CMD_EVENT actually does, what payload it expects,
and whether it has practical use on the /NET side is not yet
determined. The corresponding code path is
located in architecture/services.md.

## The per-Connection model

Each accepted client gets its own 16 KB-stack worker thread on
the E80, running a per-Connection serviceLoop. State per client
includes:

- A 10 KB persistent TCP-stream accumulator (the rx buffer the
  parser reads from across recv boundaries).
- Three RB-tree context dictionaries (one each for Waypoint,
  Route, Group), keyed by UUID -- the firmware's per-client view
  of in-flight transactional state.
- Three event-listener callbacks (one each for W/R/G) registered
  with the service factory; these fire when state changes
  externally and queue notifications to the per-client outbound
  stream.
- A 512-byte tx scratch buffer pre-loaded with the standard
  `01 02 0f 00` "INFO BUFFER Waypoint" header template.

The per-Connection thread runs an inlined dispatch loop (the
firmware's `serviceLoop`), which is large enough -- 27.5 KB,
6,888 instructions -- to confirm the template-specialization
inlining hypothesis above. Structural details and the decoded
jump tables are in architecture/services.md.

## What this means for /raymarine/NET

The empirical observations recorded in the existing `/NET`
implementation are essentially complete on the RECV (notification)
side and on the per-command request structures. The biggest
discovered gap is the SEND CMD_EVENT capability for each W context.

The structural confirmation that W contexts are template
specializations rather than three independent handler families
means the empirical findings for one context can be confidently
extrapolated to the others. Where exploration has fully exercised
Waypoint commands but only partially exercised Route or Group
variants of the same C-nibble, the missing variants almost
certainly behave the same way modulo the W-context-specific
payload shape.

---

**Next:** [TRACK](TRACK.md) ...
