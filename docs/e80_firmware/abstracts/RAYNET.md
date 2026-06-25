# RAYNET

**[Abstracts](readme.md)** --
**RAYNET** --
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

Family-level synthesis: threading model, timing implications, common
patterns across the SeatalkHS stack, and cross-cutting impacts on
/raymarine/NET.

RAYNET is the umbrella term for the whole SeatalkHS
ethernet protocol family -- the collection of UDP, TCP, and
multicast protocols Raymarine's E-series chartplotters speak
over their proprietary networking layer. In the firmware this
is the `CLNet*` class family (the "LNet" vocabulary), and the
per-service docs in this folder cover each individual protocol
in detail. This doc is the **family-level synthesis**: things
that cross individual services, structural patterns that
recur, and the cross-cutting implications for the
`/raymarine/NET` implementation.

The per-service docs ([RAYDP](RAYDP.md), [WPMGR](WPMGR.md),
[TRACK](TRACK.md), [FILESYS](FILESYS.md),
[DATABASE](DATABASE.md), [DB_FIDS](DB_FIDS.md),\n[DB_DECODE](DB_DECODE.md)) live alongside this
umbrella; the firmware-side implementation patterns are
documented in [architecture/services](../architecture/services.md).
This doc is intentionally short -- it covers what doesn't
belong in any single per-service doc.

## Threading model

RAYNET runs on **ThreadX**, Green Hills's RTOS for embedded
ARM systems. Every RAYNET service has dedicated threads. For
TCP services (WPMGR, TRACK, DATABASE, Navigation, etc.):

- **One listener thread per service** -- polls the listening
  socket for incoming TCP connections. Constructs a
  per-Connection object when a client connects and starts a
  new thread for that connection's lifetime.
- **One notify thread per service** -- drains an outbound
  message queue (block-pool-backed) and dispatches
  notifications either to a specific Connection or broadcasts
  to all via the connections RB-tree.
- **One worker thread per accepted Connection** -- runs the
  per-Connection `serviceLoop` for the lifetime of the client
  session. Stack size varies by service (16 KB for WPMGR, 8
  KB for TRACK).

UDP services (FILESYS, and likely the multicast arms of DBNAV
and RAYDP itself) collapse this to **one recvfrom-loop thread
per service** with no per-Connection objects. State, if any,
lives in RB-trees on the Server keyed by client_ip.

DBNAV's broadcaster adds **one dedicated multicast-send
thread** on the Source object that wakes every 100 ms,
emitting heading-family values every wake and other
subscribed values every tenth wake (the 10 Hz / 1 Hz tiered
broadcast).

## Timing implications for /raymarine/NET

The 100 ms / 1 second broadcast cadence has practical
consequences:

- **Heading freshness is bounded by ~100 ms latency.** Any
  client consuming HEADING from DBNAV gets values at 10 Hz
  with negligible queue delay (the broadcaster wakes,
  serializes, and sends in one tick).
- **Other field values arrive at 1 Hz.** SPEED, SOG, COG,
  LATLON, and any client-subscribed fid via CMD_FIELD all
  arrive on the same 1 Hz tick. The arrival burst is
  bounded by the MTU/packet-size limit (~1000 bytes); large
  subscription sets produce multiple packets in a single
  tick.
- **There is no "real-time" path** for field values. If a
  client needs sub-second latency on a non-heading field,
  RAYNET doesn't expose it. The TCP CMD_QUERY one-shot path
  in DATABASE has tighter latency but doesn't push -- the
  client must poll.

ThreadX priority assignments matter when multiple services
compete for cycles. The `rm_threadCreate` wrapper quantizes
priority via a `(<6 -> 0, <8 -> 10, else -> 20)` mapping;
WPMGR's per-Connection thread runs at priority 5, TRACK's
at 7. Higher-priority services preempt; the notify thread
typically runs at lower priority than its listener.

## Common patterns across services

Several structural patterns recur across every CLNet service
and are worth knowing once at the umbrella level:

**The five-class set.** Every service is implemented as
some subset of `Server` + `Source` + `ServiceInfo` +
`Connection` + `Backup`/`Cache`. The server is the
listening endpoint; the source is the outbound message
construction; ServiceInfo is the RAYDP discovery payload;
Connection is per-client TCP session state (TCP services
only); Backup/Cache is persistence (EEPROM, CF card).

**The two-object pattern.** Each TCP service has a
lightweight (80-byte) RAYDP-side registration object plus a
heavyweight (~600-byte) Server object. The factory builds
the lightweight; the Server constructor builds the
heavyweight; the two are linked.

**The inlined serviceLoop.** TCP per-Connection threads run
a single monolithic function -- the result of aggressive
compiler inlining of per-command handlers. WPMGR's is
27.5 KB; TRACK's is 9.2 KB. Each case body has its own
exclusive block of stack slots (98.7% slot exclusivity in
WPMGR), confirming the inlining of what was originally
template-specialized handler code.

**Inline halfword jump tables.** Dispatch within a
serviceLoop uses `add pc, pc, rN, lsl #2` with halfword
offset tables embedded in the function body. 4-byte
pointer-table scans miss them.

**STL-style RB-tree dictionaries.** Per-Connection state
uses `std::map<UUID,T>`-equivalent containers, with the
same shared helpers (`uuid_lessThan`, `dict_findOrInsert`,
`dict_erase`) recurring across services.

All of these are documented in detail in
[architecture/services](../architecture/services.md); the umbrella
mention here is so that the family-level reader knows
they exist.

## The "writer-mode" pattern

TRACK's writer-mode discovery -- a previously-unused SEND
command (NO_REPLY_11) triggers a per-Connection role change,
batched data uploads through the INFO frames, and auto-save
when capacity is reached -- has a structural analog in WPMGR:
each W context (Waypoint/Route/Group) has a SEND CMD_EVENT
handler in the firmware that empirical exploration
never exercised (RNS only sent EVENT in the RECV direction).

DATABASE has its own analog: three new SEND commands
(0x06/0x07/0x08) that open transaction sub-protocols for
FIELD/UUID/QUERY updates, with INFO_START/CHUNK/END to deliver
the payload.

The pattern is the same across all three services: **a SEND
command unused by RNS triggers a state machine that lets the
client push data into the E80**. TRACK has been verified
end-to-end. WPMGR and DATABASE write-paths are documented but
not yet exercised. If a future need arises (waypoint-write
without round-tripping through RNS, database-write to push a
custom field to subscribers), the firmware-side path exists
for both.

## Cross-cutting impacts on `/raymarine/NET`

A few framings worth holding across services:

- **The empirical observations are essentially complete on
  the RECV/notification side.** The existing /NET
  decoders are accurate for what RNS-and-friends actually
  send. The firmware exploration's contribution is mostly
  on the SEND side -- gaps where the firmware has more
  capability than RNS exercised.
- **Service architecture is uniform enough that one
  implementation pattern scales.** The per-service
  Perl modules already follow the
  `c_RAYDP.pm`/`d_<SERVICE>.pm` template. The firmware
  confirms this maps cleanly to the firmware's own per-service
  Server/Source/Connection structure.
- **The data dictionary is in the firmware.** The Field
  Type (FID) is carried on the wire with every DBNAV
  broadcast, along with its ENC encoding type. See
  [DB_FIDS](DB_FIDS.md).
- **The CF-card writes depend on per-service
  paths, not FILESYS.** FILESYS is read-only at the wire
  level. Writing to the E80's CF card happens through
  per-domain RAYNET services (the WPMGR-side waypoint
  writes, the TRACK writer-mode upload, the DATABASE
  transaction sub-protocol) that route through CCFArchive
  internally.

---

**Next:** [RAYDP](RAYDP.md) ...
