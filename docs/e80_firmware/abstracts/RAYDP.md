# RAYDP

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**RAYDP** --
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

Service discovery and instantiation protocol; the complete service
catalog mapped against observed SIDs; the consume-vs-serve
distinction; the gap surface of services that exist in firmware
but are not yet implemented in /raymarine/NET.

RAYDP is the SeatalkHS service-discovery and instantiation
protocol -- the same role on both sides: in
`c_RAYDP.pm` (the client receiver and decoder of RAYDP
advertisements) and in the firmware (where service
advertisements dispatch to per-service factories that build
per-service Source objects). This doc is the conceptual
view: the service catalog, the consume-vs-serve distinction, the
cross-reference between observed and named services, the gap
surface for /raymarine/NET, and the packet-length variants.

The firmware names in the service catalog below were derived from types of the form `CLNet*Server`, where `*` is the
firmware name. Example: `CLNetWaypointServer` gives "Waypoint".

## Consume vs serve

A service appearing in the dispatcher's case alphabet means the
E80 knows how to **consume** that service when *another* device
advertises it. The dispatcher creates a `CLNet*Source` (client)
object. Whether the E80 also **serves** that protocol -- hosts
its own `CLNet*Server` and broadcasts itself -- is a separate
firmware-side fact, determined by whether a `CLNet*Server` class
exists in the catalog and is instantiated on boot.

The two are independent. Most services the E80 knows about are
both consumable AND served (Waypoint, Track, Database, etc.).
A few are consume-only -- the E80 can use them from external
devices but doesn't host them.

## The complete service catalog

The firmware's RAYDP advertisement dispatcher has 20 cases,
one per consumable service. 11 of these have been observed
on the wire. Of the 20, **17 are also served** by the E80 (have
a `CLNet*Server` class); **3 are consume-only**.

The table below is the headline view.

| sid | hex    | firmware name      | serve? |   tcp    |   udp    |  mcast   | Pub::Ray name                 | E80 Service Name |
| --- | ------ | ------------------ | :----: | :------: | :------: | :------: | ----------------------------- | ---------------- |
| 1   | 0x01   | Radar              |   Y    |          |  2056+   |  2563+   | Radar                         | Radar            |
| 5   | 0x05   | CFAccessController |   Y    |          | **2049** | **2561** | [FILESYS](FILESYS.md)         | CF Access        |
| 7   | 0x07   | Navigation         |   Y    | **2054** |          |          | Navig                         | Navigation       |
| 8   | 0x08   | GPS                |   Y    |          |  2056+   |  2563+   | [Gps](GPS.md)                 | GPS              |
| 9   | 0x09   | AutoPilot          |   Y    |          |  2056+   |  2563+   | [AutoPilot](AutoPilot.md)     | Auto Pilot       |
| 15  | 0x0f   | Waypoint           |   Y    | **2052** |          |          | [WPMGR](WPMGR.md)             | Waypoint         |
| 16  | 0x10   | Database           |   Y    | **2050** | **2051** | **2562** | [DB + DBNAV](DATABASE.md)     | Database         |
| 19  | 0x13   | Track              |   Y    | **2053** |          |          | [TRACK](TRACK.md)             | Track            |
| 20  | 0x14   | Flob               | **N**  |          |          |          | (consume only)                | --               |
| 21  | 0x15   | DGPS               |   Y    |          |  2056+   |  2563+   | Dgps                          | DGPS             |
| 22  | 0x16   | HistData           |   Y    | **2055** |          |          | [FishHistory](FishHistory.md) | --               |
| 23  | 0x17   | NavionicsChart     | **N**  |          |          |          | (consume only)                | Chart            |
| 24  | 0x18   | Sonar2             |   Y    |          |  2056+   |  2563+   | [Sonar2](Sonar.md)            | Fishfinder       |
| 26  | 0x1a   | Compass            |   Y    |          |  2056+   |  2563+   | [Compass](Compass.md)         | Compass          |
| 27  | 0x1b   | Alarm              |   Y    |          | **5802** | **5801** | Alarm                         | Alarm            |
| 28  | 0x1c   | DigitalRadar       | **N**  |          |          |          | (consume only)                | --               |
| 29  | 0x1d   | Navtex             |   Y    |          |  2056+   |  2563+   | [Navtex](Navtex.md)           | Navtex           |
| 30  | 0x1e   | AIS                |   Y    |          |  2056+   |  2563+   | [Ais](AIS.md)                 | AIS              |
| 32  | 0x20   | Sonar3             |   Y    |          |  2056+   |  2563+   | [Sonar3](Sonar.md)            | Fishfinder       |
| 35  | 0x23   | DataMaster         |   Y    |          | **2048** | **2560** | DataMaster                    | --               |
| --  | 0xdddd | Diagnostics        |   Y    |          | **6667** |          | Diagnostics                   | --               |
| --  | 0xdddd | DiagnosticTCP      |   Y    | **6668** |          |          | DiagnosticTCP                 | --               |

**E80 Service Name.** The `E80 Service Name` column is the label the unit shows
for each service on its own diagnostics screen (*Setup > System Diagnostics >
External Interfaces > SeaTalk HS (Ethernet) > Services*). That screen enumerates
services by an internal diagnostics service-type index that is independent of the
SID; the names are the unit's own (note the spacing differences from the firmware
class names -- "CF Access" vs `CFAccessController`, "Auto Pilot" vs `AutoPilot`).
Two consequences:

- **One name can span two SIDs, and consume-only services still appear.** Sonar2
  (24) and Sonar3 (32) share the single **Fishfinder** slot, so the same name
  sits on both rows. **Chart** is the consume-only NavionicsChart (23) -- the
  screen counts consumed traffic, so a consume-only service is still listed.
- **`--` means the service is not on that screen.** Flob (20) and DigitalRadar
  (28) are consume-only and never tracked there; DataMaster (35), HistData (22),
  and the Diagnostics / DiagnosticTCP binds use diagnostics service-types outside
  the screen's range. The screen additionally lists five E80-internal services
  that carry no SID -- Sys, GVM, Monitor, Keyboard, and RML Monitors -- so they
  have no row in this SID catalog.

**Serve-side ports.** The `tcp` / `udp` / `mcast` columns are the unit's own listening ports per
served service. **Bold** = firmware-confirmed: read directly from the unit's live service registry,
or (the diagnostics binds) fixed in code. Plain = observed on the wire or a dynamic value; a blank
cell means the service does not present that transport.

Served services split into two classes by *when* they construct:

- **Always-on (fixed ports).** Eight services construct unconditionally at boot, claiming unicast
  slots **2048-2055** and the first three mcast slots **2560-2562** in a fixed construction order
  (DataMaster, FILESYS, DataBase, DBNAV, Waypoint, Track, Navigation, HistData). All eight unicast
  ports are firmware-confirmed: 2048-2050 and 2052-2055 read directly from the live service
  registry; 2051 (DBNAV, DataBase's broadcaster) is the one unicast slot claimed by a sub-server
  that does not separately register, identified via the allocator's claim bitmap. The three mcast
  slots are DataMaster 2560, FILESYS 2561, and DataBase/DBNAV 2562.
- **On-demand (dynamic ports, written `N+`).** The instrument/sensor services -- GPS, AutoPilot,
  Radar, Sonar2/3, DGPS, Compass, Navtex, AIS -- construct **only when their data or hardware first
  appears**, each claiming the *next free* unicast slot from **2056+** and mcast slot from **2563+**.
  The exact number is therefore not fixed per service: it depends on the unit's configuration and
  the order instruments come up. Demonstrated on the bench -- with GPS+AutoPilot both fed they took
  2056/2057; with AutoPilot alone it moved to 2056. These services present **udp + mcast** (the
  unicast is udp -- confirmed for GPS/AutoPilot; the rest share the identical source constructor).

The diagnostics binds (**6667** / **6668**) are fixed in code, not allocator-assigned; Alarm uses
fixed ports **5801** (mcast) / **5802** (udp), also outside the allocator. DataMaster presents no
tcp port: it binds udp source endpoints (not an InterNiche TCP listener), so its 0x28 advertisement
carries its udp and mcast ports, not a tcp+udp pair.

The firmware uses CapFirst single-token names for services in
its internal source code. The `/raymarine/NET` docs sometimes use slightly
different spellings (e.g. "FILESYS" for the firmware's
"CFAccessController", "WPMGR" for "Waypoint", "Auto Pilot"
with a space vs the firmware's "AutoPilot"). The
/raymarine/NET docs have been the long-running source of truth
for the client-side naming.

**A caveat on the serve? column.** The Y in "serve?" means
"a `CLNet*Server` class for this service exists in the firmware
catalog." That's necessary but not sufficient -- a Server class
could exist in code but not be instantiated on a given build.
For all 8 services connected to over the wire (Radar via
piRadar plugin only, FILESYS, Navigation, GPS, AutoPilot via
empirical port observation, WPMGR, Database, Track, Alarm,
HistData), the corresponding Server class is in the catalog --
that confirms the structural test for the cases that can be verified.

## Multicast group addressing

A served service's multicast **port** is a fixed, allocator-assigned number
(the bold `mcast` cells above -- DataMaster 2560, FILESYS 2561, Database/DBNAV
2562, and the instrument tail from 2563). Its multicast **IP group** is *not* a
constant: the firmware derives it from the unit's own IP address, so it cannot
be a column here -- two E80s on one network serve the same service on the same
mcast port but on different groups. (This is separate from the fixed RAYDP
*discovery* group 224.0.0.1:5800, which every unit shares.)

The firmware (`RAYDP_allocMcastIp`) computes each group as:

```
mcast_ip = 224.0.0.0 + (unit_low16 << 5) + (mcast_port - 2559)
```

`unit_low16` is the low 16 bits of the unit's IPv4 address -- its last two
octets, `(octet3 << 8) | octet4`. (Equivalently the firmware adds `slot + 1`,
where `slot = mcast_port - 2560` is the service's mcast construction index.)
Every group lands inside `224.0.0.0/8`, and each unit gets its own block keyed
by its address, so units never collide.

Worked example for an E80 at **10.0.240.83** (`unit_low16 = 0xF053`):

| Service          | Mcast port | Group (this unit) |
| ---------------- | :--------: | ----------------- |
| DataMaster       |    2560    | 224.30.10.97      |
| FILESYS          |    2561    | 224.30.10.98      |
| Database / DBNAV |    2562    | 224.30.10.99      |

Those groups are specific to that one unit's address -- recompute from the
formula for any other unit (the same rule covers the dynamic instrument tail on
2563+). A client receives a service's stream by joining `group:mcast_port` on
its E80-facing interface.

## The consume-only services

The three consume-only services have a structural rather than
hardware explanation:

- **Flob (sid 20)** -- network-shared blob storage. The E80
  consumes Flob from external storage-class devices (likely
  RNS, dedicated chartplotters with larger flash). The E80's
  internal blob storage uses the same family (`CFlashFlobFsDriver`
  backs `\LOCAL\` persistence) but is not exposed over the
  wire from this device.
- **NavionicsChart (sid 23)** -- chart data. The E80 consumes
  Navionics chart streams from a chart-source service; doesn't
  host its own.
- **DigitalRadar (sid 28)** -- newer-generation digital radar
  units. The E80 talks to them as a client; it doesn't
  emulate a digital radar.

For these three, "not observed" is the architectural answer:
the E80 will *never* advertise them no matter what hardware is
attached, because no Server class exists in the firmware.

## E80 Services

Read in the order the unit's own "Services" diagnostics screen presents them
(see the `E80 Service Name` column above), the twenty entries map back to SIDs
as follows. This is the screen's fixed order -- the firmware's internal
diagnostics service-type index, a numbering of its own that is unrelated to the
SID.

| Named Service | sid(s) |
| ------------- | ------ |
| Radar         | 1      |
| Fishfinder    | 24, 32 |
| Database      | 16     |
| Waypoint      | 15     |
| Track         | 19     |
| Navigation    | 7      |
| Chart         | 23     |
| CF Access     | 5      |
| GPS           | 8      |
| DGPS          | 21     |
| Compass       | 26     |
| Navtex        | 29     |
| AIS           | 30     |
| Auto Pilot    | 9      |
| Alarm         | 27     |
| Sys           | --     |
| GVM           | --     |
| Monitor       | --     |
| Keyboard      | --     |
| RML Monitors  | --     |

The first fifteen are the advertised services from the catalog above
(Fishfinder spans both sonar SIDs; Chart is the consume-only NavionicsChart).
The **last five -- Sys, GVM, Monitor, Keyboard, RML Monitors -- carry no
advertised SID**: they have no `CLNet*ServiceInfo` and never pass through
`RAYDP_dispatchAdvertisement`, so the service-discovery catalog cannot see them.
That absence is itself a lead -- the unit is accounting network traffic for
interfaces or protocols not yet identified here (an external-keyboard function
of some kind, plus four other internal channels), whose wire form remains to be
determined.

## Unadvertised Services

The services below exist on the wire but are unadvertised --
they have no `CLNet*ServiceInfo` and do not appear in
`RAYDP_dispatchAdvertisement` -- yet both bind sockets and accept
connections, reachable on the wire if you know where to look.

### Diagnostics

An unadvertised service (sid `0xdddd`) reachable on UDP 6667. It
hosts its own `CLNetDiagnosticsServer` with a paired
`CLNetDiagnosticsConnection` -- the standard CLNet wire-service
shape, minus the `CLNet*ServiceInfo` (which is why it carries no
catalog sid and does not advertise). The wire protocol is decoded
and wire-tested, with a live round-trip verified against E80-4.

Its command structure is the familiar RAYNET shape, very close to
FILESYS: a 4-byte command word whose high word is the service id,
followed by the reply port carried IN the request -- the same
reply-port-in-request convention FILESYS uses, where the client
binds a UDP listener on a chosen local port and puts that port in
the request, and the server replies there rather than to the UDP
source port. (The one simplification relative to FILESYS is that
no sequence field is carried.)

A request laid out as it appears on the wire (little-endian) --
here the ECHO command with an example reply port 11000 and an
8-byte payload:

```
00 00 DD DD F8 2A 08 00 DE AD BE EF 01 02 03 04
^^ ^^                                             <- opcode 0x0000 (ECHO) -- low word of command word
      ^^ ^^                                       <- service id 0xdddd -- high word of command word
            ^^ ^^                                 <- reply port 11000 = 0x2AF8 (v, LE), carried in the request
                  ^^ ^^                           <- payload length 8 (v, LE)
                        ^^ ^^ ^^ ^^ ^^ ^^ ^^ ^^   <- 8-byte payload (echoed back)
```

The first four bytes form the command word `0xdddd0000`: the high
word `0xdddd` is the service id -- the same slot where FILESYS
carries `0x0005` -- and the low word is the opcode. Responses for
commands that reply carry magic `0xdddd0100`, then the device's
4-byte RAYDP ID, then `length(2) + payload`.

Three opcodes are characterized:

- **0x00 -- ECHO.** Bounces the payload back to the reply port.
  Safe; used to confirm reachability.
- **0x05 -- CHECKSUM-VERIFY.** Computes an XOR checksum over the
  payload and returns a bool to the caller; no wire response, no
  observable side effect.
- **0x06 -- N2K-BUS PGN INSERTION.** The 12-byte payload (4-byte
  CAN identifier LE + 8 data bytes) is laid into an internal CAN
  frame and handed to `n2kBus_dispatchFrame` -- the same routine
  the on-device N2K worker thread calls after dequeueing from the
  CAN ISR's RX queue. A single unauthenticated UDP datagram places
  an arbitrary well-formed frame onto the device's internal
  dispatch path with no attached hardware. Confirmed against
  E80-4 -- PGN 128267 (Water Depth) carrying 12.34 m drove the
  on-screen depth to 40.5 ft, re-confirmed on a fresh boot with no
  external N2K node present, so the insertion needs no live source
  on the bus and no prior address-claim for the frame's source
  address. For PDU2 broadcast PGNs the source address is not
  filtered; the only gates are the device's own N2K being active
  and the target PGN having a registered handler. The inserted
  frame is NOT re-broadcast onto the physical CAN wire -- the TX
  scheduler only periodically broadcasts the device's own measured
  PGNs.

The listener dispatches exactly these three opcodes; any other
command word falls through and is silently ignored. `0x01`..`0x04`
and `0x07`+ are not hidden operations -- there are no other
commands on this listener.

### DiagnosticTCP

The unadvertised TCP companion to Diagnostics, on TCP 6668. The
same `CLNetDiagnosticsServer` that hosts the UDP 6667 listener
also binds a stream (TCP) socket on 6668 (`listen` backlog 5) and
runs an accept loop; each accepted connection gets its own worker
thread. Wire-tested against E80-4.

The message is the SAME diagnostics frame as Diagnostics, but
wrapped in a 2-byte little-endian length prefix (both
directions), and only the `0xdddd0000` ECHO command is
implemented -- any other command word is read and silently
dropped. This is why a casual TCP probe sees nothing: only a
correctly-framed ECHO elicits a reply.

A confirmed ECHO round-trip (payload "ECHO-6668-TEST"):

```
request:
16 00 00 00 dd dd 00 00 0e 00 45 43 48 4f ...
^^ ^^                                          <- frame length 0x0016 (LE): bytes that follow
      ^^ ^^ ^^ ^^                              <- command word 0xdddd0000
                  ^^ ^^                        <- offset 4-5 (UDP reply-port slot; unused over TCP)
                        ^^ ^^                  <- payload length 0x000e = 14 (LE)
                              ^^ ^^ ...         <- payload

response:
18 00 00 01 dd dd 00 00 00 00 0e 00 45 43 48 4f ...
^^ ^^                                                <- frame length 0x0018 = 24 (LE)
      ^^ ^^ ^^ ^^                                    <- magic 0xdddd0100
                  ^^ ^^ ^^ ^^                        <- device id (0x00000000 over TCP)
                              ^^ ^^                  <- payload length 0x000e = 14 (LE)
                                    ^^ ^^ ...         <- echoed payload
```

The inner frame after the length prefix is identical in shape to
the UDP 6667 protocol. One divergence from the UDP path: the
4-byte device-id field comes back zero over TCP, whereas the UDP
echo returns the device's RAYDP ID.

## The gap surface

What this catalog gives is **completeness** plus the
serve-vs-consume distinction. Of the services in the
firmware's case alphabet:

- **Implemented in /raymarine/NET (consumed
  from the E80):** WPMGR, TRACK, FILESYS, Database (+DBNAV),
  Navigation, Alarm. Each is both consumed AND served by the
  E80; the wire protocols are decoded, with Perl-side
  machinery.
- **Previously observed-only (now named):** GPS, AutoPilot,
  DataMaster. Each is served by the E80; traffic has been observed
  but no decoders exist yet. The firmware-side machinery is the standard
  CLNet pattern; see
  [architecture/services](../architecture/services.md).
- **Decoded but not yet implemented in /raymarine/NET:** HistData
  (see [FishHistory](FishHistory.md)) -- command structure and
  buffer geometry decoded from firmware; no /NET decoder yet.
- **Served by the E80 but not observed (hardware-dependent):**
  Radar, Sonar2, Sonar3, AIS. Attaching the corresponding
  hardware would cause the E80 to start advertising. DGPS,
  Compass, Navtex may also fall in this category, possibly
  with software-dependent triggers.
- **Consume-only (will never advertise):** Flob, NavionicsChart,
  DigitalRadar -- listed above.
- **Unadvertised wire services:** see [Services not documented in
  specific *.md files] above. The Diagnostics service (UDP 6667)
  and DiagnosticTCP (TCP 6668) -- both protocol-decoded and
  wire-tested -- exist outside the SID catalog; reachable but not
  surface-able via the standard dispatcher's case alphabet.

The most concrete near-term opportunities are the
previously-observed-served services (GPS, AutoPilot,
DataMaster). Each is a candidate for a new /NET decoder.

## RAYDP packet-length variants

The per-case length checks in the dispatcher confirm the
empirically-derived packet length variants in
`/raymarine/NET/docs/RAYDP.md`, with one new finding:

| Length    | Variant                                  | Used by |
| --------- | ---------------------------------------- | ------- |
| 0x1c (28) | single ip:port                           | Waypoint, Track, Flob, HistData, Database (single-port) |
| 0x24 (36) | mcast + tcp ip:port pair                 | Radar, GPS, DGPS, Compass, Alarm, DigitalRadar, AIS, Sonar2 |
| 0x25 (37) | 36 + flags byte                          | CFAccessController/FILESYS |
| 0x28 (40) | tcp ip + two ports + mcast ip:port       | Database, AutoPilot, NavionicsChart, Navtex, DataMaster |
| 0x34 (52) | new variant -- not previously observed   | Sonar3 |

The 52-byte variant is specific to Sonar3: its factory stores four
extra words (vs Sonar2's 36-byte form) -- additional channel ip:port
endpoints -- consistent with Sonar3 being the newer, multi-channel
sonar protocol generation. The Sonar2 / Sonar3 split, and how the
registration tag selects the matching consume-source, is decoded in
[Sonar](Sonar.md).

## Discovery flow

The firmware-side discovery flow for incoming advertisements:

```
RAYDP advertisement arrives at 224.0.0.1:5800
  -> CLNetServiceManager processes it
  -> RAYDP_dispatchAdvertisement switches on sid
  -> RAYDP_allocService does RB-tree lookup-or-insert by device_id
  -> per-service factory builds the lightweight Source registration
```

Separately, on boot:

```
each served service constructs its CLNet*Server
  -> Server creates its threads, sockets, connection table
  -> Server registers with CLNetServiceManager for advertisement
  -> the E80 begins broadcasting RAYDP advertisements for it
```

The Diagnostics service sits outside both flows: it has no
`CLNet*ServiceInfo`, so it neither dispatches through
`RAYDP_dispatchAdvertisement` nor advertises on boot. It was
found not by observing the wire but by the type-matching scan
over the `CLNet*Server` family in the firmware -- a Server class
with no matching ServiceInfo -- and then reading its listener
directly.

This mirrors what `/raymarine/NET/c_RAYDP.pm` does on the
client side: receive advertisements, dispatch by sid, build
per-service descriptors, populate a service registry. The
firmware-side Server constructors are the equivalent of what
/NET implements as per-service modules (d_WPMGR, d_TRACK,
d_FILESYS, etc.).

## Service-internal architecture

The firmware-side architecture of how each service is
structured internally -- the CLNet five-class set
(Server/Source/ServiceInfo/Connection/Backup), the ThreadX
kernel wrappers, the two-object pattern, the inlined
serviceLoop dispatch -- is documented in
[architecture/services](../architecture/services.md). The
per-service specifics for individual protocols are in their
respective abstracts docs ([WPMGR](WPMGR.md),
[TRACK](TRACK.md), [FILESYS](FILESYS.md),
[DATABASE](DATABASE.md), [DB_FIDS](DB_FIDS.md),\n[DB_DECODE](DB_DECODE.md)).

---

**Next:** [WPMGR](WPMGR.md) ...
