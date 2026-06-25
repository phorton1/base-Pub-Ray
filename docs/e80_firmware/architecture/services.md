# Networked Services

**[Architecture](readme.md)** --
**[overview](overview.md)** --
**[runtime](runtime.md)** --
**services** --
**[instruments](instruments.md)** --
**[applications](applications.md)** --
**[persistence](persistence.md)**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The SeatalkHS ethernet service stack as implemented in firmware:
the CLNet pattern (Server + Source + ServiceInfo + Connection),
dispatch machinery, ThreadX wrappers, message-loop topology.

The SeatalkHS ethernet service stack -- termed
RAYNET on the wire and "LNet" in firmware vocabulary -- is
implemented by the **`CLNet*` class family**. Roughly 100
classes, organized by a uniform per-service triplet pattern and
supported by a small set of infrastructure classes that ARE the
firmware's RAYDP discovery layer. This doc covers the
firmware-side architecture: the class pattern, the discovery
dispatcher, the ThreadX wrapper layer, the typical
service-construction flow, and the dispatch jump-table pattern
that recurs across services.

## The CLNet class triplet pattern

For each advertised service `Xxx`:

- **`CLNetXxxServer`** -- server-side implementation: the
  listening endpoint that handles the protocol.
- **`CLNetXxxSource`** -- client-side adapter: consumes the
  service from elsewhere on the network.
- **`CLNetXxxServiceInfo`** -- discovery-payload object: carries
  the SID, port, transport, advertised by `CLNetServiceManager`.

Stateful protocols add:

- **`CLNetXxxConnection`** -- per-connection state machine (TCP
  services only; UDP services don't use Connection objects).
- **`CLNetXxxConnection::CXxxChange`** -- per-event/change
  subtypes.
- **`CLNetXxxBackup`** / **`CLNetXxxCache`** -- persistence
  helpers.

For Waypoint specifically the five-class set is
`CLNetWaypointServer`, `CLNetWaypointSource`,
`CLNetWaypointServiceInfo`, `CLNetWaypointConnection`,
`CLNetWaypointBackup`, plus a template instantiated three times
for the three W contexts:
`TLNetWaypointItemCache<CWaypoint>`,
`TLNetWaypointItemCache<CWaypointRoute>`,
`TLNetWaypointItemCache<CWaypointGroup>`. Other services follow
the same shape.

## Infrastructure classes (the RAYDP machinery)

These are the firmware's service-registry and discovery layer --
the equivalent of `c_RAYDP.pm`:

- `CLNetServiceManager` -- service registry; IS the firmware-side
  RAYDP discovery layer.
- `CLNetServerList` -- catalog of local servers.
- `CLNetSourceList` -- catalog of local sources.
- `CLNetSourceFactory` -- factory for `*Source` clients.
- `CLNetConnectionFactory` -- per-connection factory.
- `CLNetTransportInfo` -- port/transport descriptor.
- `CLNetSource` -- base class for all `*Source` clients.
- `CLNetSyncNetworkCall` -- synchronous network call helper.
- `CLNetInfo` -- top-level network info.
- `CLNetDiagnostics` -- diagnostics infrastructure.

**There is no centralized RAYNET message dispatcher.** Each
service runs its own threads with its own per-service dispatch
logic inside. The "framework" at the address range where one
might expect a framework dispatcher (`0x0016xxxx`) is actually
the ThreadX kernel-wrapper layer, not a protocol-dispatch layer.

## The RAYDP advertisement dispatcher

`RAYDP_dispatchAdvertisement` at `0x00503260` is the firmware's
RAYDP service-advertisement dispatcher. It receives a parsed
RAYDP advertisement packet (per `c_RAYDP.pm`) and switches on
the `service_id` field at offset +8. Each case dispatches to a
per-service factory function, passing the runtime label string
`"LNet <Name> Source"` as an argument. The case alphabet of this
switch IS the firmware's service catalog -- see
[abstracts/RAYDP](../abstracts/RAYDP.md) for the catalog from
the protocol side.

Before invoking the per-service factory, the dispatcher calls
`RAYDP_allocService` at `0x00508c88` -- a service-allocator that
performs an RB-tree lookup-or-insert keyed by device_id and
returns a packed handle. The sub-type word (`0x1000` for
Waypoint, `0x1003` for CFAccessController/FILESYS, etc.) is a
firmware-side service-class identifier used at this allocation
step; distinct from the on-the-wire RAYDP service_id.

## The two-object pattern per service

Each TCP RAYNET service is represented in the firmware by **two
distinct objects**, not one:

**Object A -- lightweight RAYDP registration (80 bytes).** Built
by the per-service factory (e.g. `WPMGR_factory` at `0x004f88ec`)
inside `RAYDP_dispatchAdvertisement`. Layout:

```
+0x00  uint    sub_type        (0x1000 for Waypoint, etc.)
+0x04  uint    flag            (always 1 from the dispatcher)
+0x08  uint    packed_handle   (from RAYDP_allocService)
+0x0c  char*   name_string     (malloc'd "LNet <Name> Source")
+0x10  void*   vtable          (initially DAT_004f826c -- shared
                                CLNetService base vtable, used by
                                9+ service factories)
+0x14  ...     Source sub-object (per-service)
+0x1c  void*   secondary_vtable
```

This is the **identity / registration** object. Small, lives in
the RAYDP service-manager's RB-tree (indexed by device_id).

**Object B -- heavyweight Server (620 bytes for WPMGR).** Built
by the per-service Server constructor (e.g.
`WPMGR_Server_constructor` at `0x004f6f5c`). Has its own vtable,
its own worker threads, its own connection table -- the actual
working machine where TCP accept happens, where messages are
dispatched, where connections are tracked.

The two objects are linked: Object B holds Object A as its
parent-context pointer (at server+0x264 in WPMGR's case).

## ThreadX kernel-wrapper layer

The CLNet server constructors call two Raymarine-internal
wrappers around ThreadX kernel primitives:

- **`rm_blockPoolCreate`** at `0x0016ecbc` -- wraps
  `_tx_block_pool_create`. Allocates a TX_BLOCK_POOL (0x44 bytes),
  allocates backing memory, registers the pool, translates
  ThreadX error codes to Raymarine codes.
- **`rm_threadCreate`** at `0x0016e288` -- wraps
  `_tx_thread_create`. Zeros a TX_THREAD (0x104 bytes, slightly
  larger than vanilla ThreadX to accommodate Raymarine
  bookkeeping), allocates two stack regions, updates global
  thread counters at `DAT_0016ee94`, quantizes priority via a
  (<6 -> 0, <8 -> 10, else -> 20) mapping, and calls the kernel.

A leaf helper used by Server threads:

- **`rm_threadIsRunning`** at `0x0016e59c` -- 8-byte leaf,
  returns `*(TCB+0xa8)`. NOT a sync primitive; the run-flag
  check used by every server thread's main loop.

The `rm_*` wrappers are general infrastructure used across the
firmware, not RAYNET-specific. The actual ThreadX kernel
functions are at much higher addresses
(`_tx_block_pool_create` ~ `0x0026a0e0`,
`_tx_thread_create` ~ `0x0026add0`,
`tx_byte_allocate` ~ `0x00268838`).

## Typical TCP service construction flow

For TCP services (WPMGR, TRACK, DATABASE, Navigation), the
construction pattern:

```
WPMGR_Server_constructor creates:
  - 1 block pool (10 x 4 bytes) backing the notify-thread queue
  - 1 listener thread (TCP accept loop)
  - 1 notify thread (outbound event dispatcher)
  - 1 listening socket abstraction (polled by listener thread)
  - 1 connections RB-tree (keyed by client identity)
  - 1 parent-context back-pointer to Object A

Per accepted client:
  - listener thread creates a CLNetXxxConnection
  - Connection allocates its own 16 KB-stack worker thread
  - Connection runs serviceLoop on that thread
```

The notify thread reads 4-byte messages from a queue and either
delivers to a specific Connection via its typed-message
self-deliver vmethod, or broadcasts via tree walk.

## Typical UDP service architecture

UDP services (FILESYS, and likely the multicast arms of DBNAV
and RAYDP itself) follow a different shape. No per-client
Connection objects, no accept loop. The Server creates two
sockets (one bound for receive, one unbound for sendto) and a
single thread that loops on recvfrom. Per-client session state,
if any, lives in RB-trees on the Server keyed by client_ip.

The factory/Server-constructor relationship is inverted from
the TCP pattern: in WPMGR/TRACK the factory calls a separate
Server constructor; in FILESYS the Server constructor calls the
factory inline for its RAYDP-registration sub-object. This is
consistent with FILESYS being instantiated once from boot rather
than from a RAYDP advertisement dispatch.

## The serviceLoop and inlined-dispatch pattern

Per-Connection serviceLoops in TCP services are large monolithic
functions, the result of aggressive compiler inlining:

- `WPMGR_Connection_serviceLoop` (`0x00577b9c`): 27,552 bytes,
  6,888 instructions, single prologue, single return, 5 KB+ of
  stack-resident locals in one frame.
- `TRACK_Connection_serviceLoop`: ~9.2 KB (about 1/3 of WPMGR's
  scale).

Static analysis of stack-slot distribution confirms the
inlining: 545 of 552 unique stack offsets in WPMGR's
serviceLoop are exclusive to one case body (98.7%). Each case
references its own contiguous block of stack slots; only seven
offsets are shared (cmd_word, payload_len, request-staging
area, and four small W-context-shared slots).

Per-C-nibble symmetry across W contexts confirms template
specialization: the same C-nibble case has identical slot counts
in all three W contexts (C=3 ITEM = 26 slots in W/R/G; C=5
EVENT = 27 slots in W/R/G; etc.). The Route EXIST +1 slot
difference (36 vs 35) is the structural "tell" -- Route's
CMD_EXIST takes two waypoint UUIDs (start and end of the route
segment) instead of one. The "30 case bodies" model reduces to
"~10 source-level handler types x 3 W contexts" -- each handler
type encapsulates one (direction, command) protocol semantic,
parameterized by W context type, all specializations inlined
into the serviceLoop's stack frame.

## Inline halfword jump tables

The dispatch inside serviceLoops is implemented as **inline
halfword-offset jump tables**, not 4-byte pointer tables. The
compiler emitted:

```
adr  r10, <table_base>       ; address of inline table
mov  r0,  r0, lsl #0x1       ; index *= 2 (each entry is 2 bytes)
ldrh r10, [r10, r0]          ; load 16-bit offset
add  pc,  pc, r10, lsl #0x2  ; jump: pc += offset * 4
```

The halfword * 4 dispatch saves space (each handler is within
~256 KB of the dispatch site). **No 4-byte pointer table exists;
pointer-table scans return nothing.** The inline halfword data between the dispatch instructions is
what's actually dispatching.

WPMGR's outer dispatch is a nested range-check:

- `cmd_word in [0x000f0100, 0x000f013f]` -> Waypoint handlers
- `cmd_word in [0x000f0140, 0x000f017f]` -> Route handlers
- `cmd_word in [0x000f0180, ...)` -> Group/Database handlers

Inside each W range, an inner jump table dispatches on the
command nibble. The per-service jump tables differ in entry
count (Waypoint 14, Route 16, Group/Database not yet fully
decoded) but the dispatch mechanism is the same.

The Waypoint SEND jump table at `DAT_00577c78` (14 entries) and
the Route SEND jump table at `DAT_00577cac` (16 entries) are
the decoded examples; the Group table at `LAB_00577ccc` and
the Database handler at `LAB_00577d10` are located but not yet
fully decoded.

## STL-style associative-container helpers

The serviceLoops use STL-style RB-tree dictionaries extensively,
with shared helpers (named during WPMGR exploration; the
patterns recur across services):

- **`WPMGR_uuid_lessThan`** at `0x005747f8` -- 8-byte UUID
  lexicographic compare; `std::less<UUID>` equivalent.
- **`WPMGR_dict_findOrInsert`** at `0x00574b74` --
  `std::map<UUID,T>::insert` pattern. Returns (node,
  was_inserted) pair.
- **`WPMGR_dict_erase`** at `0x00574d18` --
  `std::map::erase` with full RB-tree rebalancing. References
  `s_invalid_map_set<T>_iterator_005750c4` -- definitive proof
  the dictionaries are STL-style containers.

## Connection internals (the 476-byte WPMGR pattern)

The per-Connection object layout for WPMGR, as a reference for
the pattern other services follow:

```
+0x00  vtable
+0x04, +0x08, +0x0c  3 callback objects (W/R/G event listeners)
+0x10  factory_token
+0x14  parent_server (CLNetWaypointServer)
+0x18  client_handle (TCP socket)
+0x20, +0x70  two mutexes
+0x6c  rx_buffer: malloc(10000) -- TCP stream accumulator
+0xa0  msg_scratch: 20-byte object with 512-byte tx buffer
       pre-loaded with the standard message header template
+0xa5, +0xb1, +0xbd  3 RB-tree dictionaries (W/R/G context,
                     UUID-keyed)
+0xc8  per-Connection thread TCB
```

TRACK uses a similar but smaller Connection object (fewer W
context dimensions); DATABASE uses a richer one.

---

**Next:** [instruments](instruments.md) ...
