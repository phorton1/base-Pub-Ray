# AutoPilot

**[Abstracts](readme.md)** --
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

The autopilot network service: how the E80 republishes the boat's
autopilot state onto SeaTalkHS, and how a networked client reads that
state and can set the pilot's status. RAYDP **SID 9 (0x09)**, firmware
name `AutoPilot`, shown on the E80's own diagnostics screen as
"Auto Pilot". Both consumed and served by the E80; not yet implemented
in `/raymarine/NET`.

## What it is

The autopilot itself is not an Ethernet device. The E80 reaches the
boat's pilot over SeaTalk1, SeaTalk2, or NMEA 2000 (the firmware carries
`CSTAutoPilotSource`, `CST2AutoPilotSource`, and an N2K command/ACK
handler), maintains a single in-memory pilot record, and **republishes
that record on SeaTalkHS** as the AutoPilot service so any networked
display can show the same pilot state. The same path runs in reverse: a
networked client can ask the E80 to **set the pilot's status**, which the
E80 forwards down to the real autopilot.

The pilot state it carries is the familiar Raymarine pilot picture --
mode and steering state (the firmware enumerates `STANDBY`, `AUTO`,
`TRACK`, `VANE` (wind), `PWRSTEER`, `FISH`, `DODGE`, `ALARM`, and a
`None`/no-pilot state, each with a `Straight`/`Turning` sub-state) plus a
small set of numeric steering values and two name fields.

For where this service sits in the larger navigator -> autopilot -> rudder data
flow -- and how it relates to the [Navig](Navig.md) service that feeds it -- see
[RAYNET -> Navigation and autopilot data flow](RAYNET.md#navigation-and-autopilot-data-flow).

## Transport and framing

AutoPilot is a UDP service on the on-demand instrument tail (it constructs
only when pilot data appears, claiming the next free udp port from 2056
and multicast group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)).
The advertisement carries both the server's **unicast** ip:port and its
**multicast** ip:port.

The traffic is asymmetric, and it is clearest to picture two distinct
client roles rather than a request/response exchange:

- **Subscribers** join the server's multicast group and *receive* the
  report messages. There is no subscription handshake or per-client
  registry -- joining the group is the subscription. The server **pushes**
  reports to the group whenever the pilot state changes (it is a
  change-sink on the underlying pilot data); it does not poll or emit at a
  fixed rate.
- **Commanders** send command datagrams to the server's unicast port to
  control the pilot or to prompt a report. A command gets **no unicast
  reply** and carries **no client reply-port** (unlike FILESYS or
  Diagnostics): the server's only response is the next report it
  broadcasts to the multicast group, which a commander sees only if it is
  *also* a subscriber.

A single client can of course play both roles (join the group, then send
commands), but they are independent channels.

Every message is a bare little-endian datagram that leads with a 4-byte
**command word** and carries no length prefix (the datagram length is the
message length):

```
cmd_word = (sid << 16) | dir | cmd
           sid = 0x0009 (AutoPilot)
           dir = 0x100  command  (client -> server's unicast port)
                 0x000  report   (server -> its multicast group)
           cmd = low byte selects the message
```

So a consumer that just wants to display the pilot joins the multicast
group and listens; if it wants the current state immediately rather than
waiting for the next change, it sends a one-shot `GetPilotData` to the
unicast port, which makes the server broadcast the current record to the
group.

## Message set

The service implements exactly five messages -- the firmware's five
`CAutoPilotMsg_*` classes -- in two groups by direction:

| cmd_word     | message        | direction         | meaning                                                     |
| ------------ | -------------- | ----------------- | ---------------------------------------------------------- |
| `0x00090101` | GetPilotData   | client -> unicast | prompt the server to broadcast the current record (4 bytes) |
| `0x00090100` | SetPilotStatus | client -> unicast | set the pilot status/mode (cmd_word + 1 status byte = 5 bytes) |
| `0x00090000` | NewPilotData   | server -> mcast   | the pilot state report (fixed 61 bytes)                    |
| `0x00090001` | PilotConnected | server -> mcast   | a pilot has come online                                    |
| `0x00090002` | NoPilotData    | server -> mcast   | no autopilot is present / available                        |

The three `server -> mcast` reports are broadcast to the group on
pilot-state changes. The two `client -> unicast` commands are the only
inputs the server accepts: a `GetPilotData` makes it immediately broadcast
`NewPilotData` (or `NoPilotData` if no pilot is present) to the group, and
`SetPilotStatus` emits no message of its own -- its effect appears as the
next `NewPilotData` broadcast.

## NewPilotData layout (61 bytes)

`NewPilotData` is a fixed **61-byte (0x3d)** datagram -- the length is
checked on receive and fixed on send. The byte layout is established; the
**semantics of the numeric fields are not yet individually confirmed**
(see *Open edges*), so they are grouped here as steering values:

| offset | size | field          | notes                                                    |
| ------ | ---- | -------------- | -------------------------------------------------------- |
| 0x00   | 4    | cmd_word       | `0x00090000`                                             |
| 0x04   | 2    | steering u16 A | one of heading / locked (target) heading / bearing      |
| 0x06   | 2    | steering u16 B |                                                          |
| 0x08   | 2    | steering u16 C |                                                          |
| 0x0a   | 4    | steering u32 D | a distance, position, or cross-track value              |
| 0x0e   | 17   | name A         | NUL-terminated, up to 16 chars (likely a waypoint name)  |
| 0x1f   | 1    | flag           |                                                          |
| 0x20   | 1    | **status/mode**| the primary pilot status; selects the mode enum above    |
| 0x21   | 2    | steering u16   |                                                          |
| 0x23   | 4    | steering u32   |                                                          |
| 0x27   | 17   | name B         | NUL-terminated, up to 16 chars (likely a waypoint name)  |
| 0x38   | 2    | u16            |                                                          |
| 0x3a   | 1    | flag           |                                                          |
| 0x3b   | 1    | flag           |                                                          |
| 0x3c   | 1    | flag           |                                                          |

On receive, the client copies this into its pilot record and notifies
every registered change-sink; that is how a second display tracks the
pilot live. The two 16-character name fields and the dual
`u16 / u32 / name` blocks fit a current-plus-next waypoint picture for
`TRACK` mode, but that mapping is inferred, not yet confirmed.

## Control: SetPilotStatus

The server accepts an inbound `SetPilotStatus` -- a 5-byte datagram
(`0x00090100` followed by a single status byte). After a validity check
it applies the byte to the pilot source, which forwards the change to the
real autopilot. This is a genuine **control** surface: a single
unauthenticated UDP datagram can change the autopilot's status/mode. It
is documented here as a fact about the protocol; exercising it acts on
the actual steering gear and should be treated with corresponding care.

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing,
the unicast-command / multicast-report split (reports are pushed to the
group on pilot-state change, `GetPilotData` prompts an immediate
broadcast, and commands get no unicast reply and carry no reply-port), the
complete five-message set with their command words and directions, the
61-byte `NewPilotData` byte layout, the status/mode byte and the mode
enumeration, the two name fields, the `SetPilotStatus` control path and
its validity gate, and the SeaTalk/SeaTalk2/N2K origin of the data.

**Not yet pinned:**

- The individual meaning of each numeric field (which u16 is heading vs
  locked heading vs bearing-to-waypoint; the u32s as distance / position
  / cross-track; whether the two name fields are the active and next
  waypoints).
- The exact numeric values of the status-byte enumeration.

Both are best resolved by a live capture with the pilot active --
feeding known SeaTalk1 autopilot data and correlating the on-screen
values to the byte offsets above.

## Why it matters

The AutoPilot service is the network face of the boat's pilot: it lets
any SeaTalkHS display read the pilot's mode and steering state, and set
its status, without its own pilot wiring. For interoperability it is an
attractive, small target -- a 4-byte subscribe and a fixed 61-byte report
-- and a natural candidate for a new `/raymarine/NET` decoder
(`d_AutoPilot`) alongside the existing `WPMGR`, `TRACK`, `FILESYS`, and
`Database` modules. Read-side decoding is harmless; the `SetPilotStatus`
write path is real autopilot control and is out of scope for passive
monitoring.

---

**Next:** [Home (Abstracts)](readme.md) ...
