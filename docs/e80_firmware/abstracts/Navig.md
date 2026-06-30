# Navig

Return to [**Abstracts**](readme.md)

The active-navigation service: the network face of the E80's "navigate to"
function -- the state the unit enters when a **Goto Waypoint** or **Follow Route**
is active. RAYDP **SID 7**, firmware name `Navigation` (the "LNet Navigation
Source"), diagnostics service-type 5, Pub::Ray name **Navig**. Served only; **not
yet implemented in `/raymarine/NET`** (there is no `d_NAV.pm`). A **TCP
command/reply** service in the WPMGR / TRACK family, not a UDP push feed.

## What it is

When the E80 is actively navigating, it holds an *active-navigation state*: a
current destination (a single waypoint, or the active leg of a route) and the
continuously-computed steering solution toward it -- the bearing and distance to
the mark, the cross-track error, and so on. That state is what drives the unit's
on-screen navigation readout, its NMEA output sentences, and any autopilot that is
following it.

The Navig service is the **wire control point for that state**, and it works in
**both directions**:

- **Control in.** Three commands carry coordinates: one sets a single destination
  (the shape of "Goto Waypoint"); one sets a from/to pair (the shape of "Follow
  Route" -- the active leg). A client uses these to *start or retarget* active
  navigation over Ethernet.
- **Readback out.** One command returns the entire active-navigation status in a
  54-byte report; the rest are single-value queries. The server also **pushes**
  that same status unsolicited on every change (see *Transport and framing*). A
  client uses these to *read* the boat position and the active-navigation
  reference the unit holds.

So it is **not** an information-only feed, and it is **not** the autopilot. The
autopilot is a separate service ([AutoPilot](AutoPilot.md), SID 9); Navig sits
*upstream* of it -- it is the route-following function whose solution the pilot
(and the NMEA nav outputs) consume. To make the E80 navigate somewhere over the
wire, or to read where it is navigating, this is the service; to drive the pilot's
rudder or mode, that is AutoPilot. For the full navigator -> autopilot -> rudder
data flow these two services sit on, see
[RAYNET -> Navigation and autopilot data flow](RAYNET.md#navigation-and-autopilot-data-flow).

What the service is *for* is therefore clear, and live capture has pinned the
status report's core -- the boat position, carried as plain 1e-7-degree
longitude/latitude. What is **not** yet pinned is the exact job of each individual
command and the meaning of the report's secondary coordinate, because the
in-process object that implements the commands is reached through a registry handle
whose concrete type is not visible in a static read (see *Status and open edges*).

## Transport and framing

Navig is a **base, always-on service**: its server starts unconditionally at boot
(it does not wait for any hardware), on the fixed **TCP port 2054** (see
[RAYDP](RAYDP.md)). It presents as diagnostics service-type 5 on the unit. The
advertisement carries the single TCP ip:port -- no multicast, no UDP.

The server follows the same **listener + per-connection** pattern as
[WPMGR](WPMGR.md) and [TRACK](TRACK.md): it accepts a client connection, runs a
command loop on it that reads one framed message at a time and writes the reply
back on the same socket, and drops the connection when the client disconnects.

The service is both **polled and pushed**. A client may poll the status command at
any time, but the server **also pushes an unsolicited status notification
(`0x070007`) on the same TCP connection whenever the active-navigation state
changes** -- roughly once per second while underway, mirroring the unit's own
position/solution updates. So a live client does not have to poll: it connects and
receives a stream of `0x070007` pushes, and polls `0x070106` only when it wants a
fresh snapshot on demand. (Unlike the GPS / Compass / AIS feeds, the push is a TCP
notification on the established connection, not a UDP multicast.)

Every message uses the standard RAYNET TCP envelope -- a length-delimited frame
carrying a 4-byte **command word**, a 4-byte **seq** token, and then the body:

```
[ frame_len ][ cmd_word(4) ][ seq(4) ][ body... ]

cmd_word = (sid << 16) | (dir << 8) | sel
           sid = 0x0007 (Navig)
           dir = 0x01  command  (client -> server)
                 0x00  reply    (server -> client)
```

The `seq` dword is echoed verbatim from the request into the reply, exactly as on
the WPMGR / TRACK connections.

## Message set

Nine client commands (`0x070100`..`0x070108`), each returning one reply. Three
commands carry coordinate arguments (the control side); the rest take no body
(queries). Reply `0x070006` is the full status report; the other replies are a
fixed 12 bytes.

| command    | req len | -> | reply      | reply len | shape / role (inferred)                    |
| ---------- | :-----: | -- | ---------- | :-------: | ------------------------------------------ |
| `0x070100` |   17    | -> | `0x070000` |    12     | set: one coordinate (8) + byte             |
| `0x070101` |   17    | -> | `0x070001` |    12     | set: two dwords + byte                     |
| `0x070102` |   29    | -> | `0x070002` |    12     | set: two coordinates (8+8) + dword + byte  |
| `0x070103` |   12    | -> | `0x070003` |    12     | query (no args)                            |
| `0x070104` |   12    | -> | `0x070004` |    12     | query (no args)                            |
| `0x070105` |   12    | -> | `0x070005` |    12     | query (no args)                            |
| `0x070106` |   12    | -> | `0x070006` |  **54**   | **get active-navigation status**           |
| `0x070107` |   12    | -> | `0x070009` |    12     | query (no args)                            |
| `0x070108` |   12    | -> | `0x07000a` |    12     | query (no args)                            |

An unrecognized command word makes the server **close the connection**.

Beyond these replies, the server emits one **unsolicited push**:

| message    | direction        | bytes | meaning                                            |
| ---------- | ---------------- | :---: | -------------------------------------------------- |
| `0x070007` | server -> client |  50   | nav-status push (sent on every change, no seq)     |

The `0x070007` push carries the **same status body** as the `0x070006` reply,
minus the 4-byte seq (so 50 bytes versus 54). Selector `0x070008` was never
observed.

### The 12-byte replies

Every command except `0x070106` returns the same fixed envelope -- the command's
single-word result:

```
[0]  cmd_word (4)   0x0700xx   (reply selector for the command)
[4]  seq      (4)              echoed from the request
[8]  result   (4)              the command's return value
```

The three control commands carry their arguments in the request body after the
`seq` token:

```
0x070100  (17 bytes)  [cmd(4)][seq(4)][ coordinate(8) ][ byte(1) ]
0x070101  (17 bytes)  [cmd(4)][seq(4)][ dword(4) ][ dword(4) ][ byte(1) ]
0x070102  (29 bytes)  [cmd(4)][seq(4)][ coordinate(8) ][ coordinate(8) ][ dword(4) ][ byte(1) ]
```

The 8-byte "coordinate" slots are carried as paired 4-byte values. The status
report (below) confirms this service encodes coordinates as **plain
1e-7-degree longitude/latitude i32 pairs** -- *not* the prescaled-Mercator form
used by [TRACK](TRACK.md) -- so the setter coordinates are almost certainly the
same encoding (the setters themselves were not exercised). The two-coordinate
`0x070102` has the shape of a route-leg set (an origin and a destination);
`0x070100` has the shape of a single-destination "goto".

### Get active-navigation status (`0x070106` -> `0x070006`, 54 bytes)

The one rich query, and the body the `0x070007` push also carries. Most of the
layout was **decoded from live captures** of an E80 navigating a route (boat
position fed and driven by a simulator, the on-screen values used as ground
truth):

```
[0x00]  4   cmd_word     0x00070006
[0x04]  4   seq          echoed from the request
[0x08]  4   status word  0x00000000 idle / 0x00000601 navigating
[0x0c]  4   boat LONGITUDE   i32, units 1e-7 degree   (VERIFIED)
[0x10]  4   boat LATITUDE    i32, units 1e-7 degree   (VERIFIED)
[0x14]  4   coordinate B longitude   i32, 1e-7 degree
[0x18]  4   coordinate B latitude    i32, 1e-7 degree
[0x1c]  8   identifier   constant within a navigation episode; changes when
                         navigation is restarted (an active-waypoint / leg id)
[0x24] 12   zero
[0x30]  4   mode marker  0x00004001 idle / 0x00004a01 routing / 0x00004201 AP-only
[0x34]  2   (pad to 54)
```

**Verified:** the boat's own position at `[0x0c]/[0x10]` -- plain
1e-7-degree longitude then latitude -- tracked the simulated boat exactly across
multiple captures. The status word and the mode marker both change with the
navigation mode.

**Still open:**

- **Coordinate B** (`[0x14]/[0x18]`) is a second 1e-7-degree lon/lat point that
  lies on the bearing from the boat toward the active waypoint, a fraction of the
  way along it (about 40% of the distance-to-go in one capture, 7% in another). It
  is not the waypoint itself (it moves with the boat), and its exact meaning -- a
  steering / course-made-good look-ahead point, or a leg reference -- is not yet
  pinned.
- **Cross-track error is *not* in this report.** With the boat driven ~2 nm
  off-track, the 12 bytes at `[0x24]` stayed all-zero. The report carries position
  + active-navigation reference + status; XTE, bearing, and distance-to-waypoint
  are computed by the consumer, not transmitted here. (This was captured with the
  E80 *repeating* a simulator's navigation; a capture of the E80 *originating*
  navigation may populate more.)
- The 8-byte identifier at `[0x1c]` is stable while a single navigation episode is
  active and changes when navigation restarts -- consistent with an
  active-waypoint or leg handle, but its internal form is not decoded.

## Status and open edges

**Established:** the SID, the base always-on TCP 2054 binding, the command/reply
TCP architecture with an **additional server push** (`0x070007`) on every state
change, the standard `[cmd_word][seq][body]` envelope with the echoed seq, the
complete nine-command set with each command's direction / length / reply selector,
the three control commands' body shapes, the 54-byte status-report structure, and
-- from live capture -- the **boat-position fields (1e-7-degree lon/lat)**, the
status and mode words, and the fact that **cross-track error is not carried in the
report**.

**Not yet pinned:**

- The meaning of each individual command (which control command is the goto versus
  the route leg; which query returns which value).
- The identity of **coordinate B** in the status report and the form of the 8-byte
  active-navigation identifier.
- Whether the E80 *originating* navigation (rather than repeating a feed) populates
  fields left zero in the repeater capture.

These are best resolved by further live capture -- driving navigation against the
E80 on TCP 2054 with the E80 itself as the navigator, correlating the on-screen
readout to the `0x070006` / `0x070007` bytes.

## Why it matters

Navig is the "active" half of the WGRT picture: WPMGR and TRACK maintain the stored
waypoints, routes, and tracks, while Navig is what actually *runs* a route on the
E80. A decoder would let navMate read the live navigation solution (active
waypoint, cross-track error, bearing and distance to the mark) directly from the
unit and -- via the control commands -- start or retarget navigation over Ethernet,
the natural companion to the existing programmatic waypoint and track writers.
Read-side polling is harmless monitoring; the control commands act on the live,
autopilot-facing navigation state and are out of scope for passive use.

---

Return to [**Abstracts**](readme.md)
