# Alarm

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

The network alarm service: how the E80 (and RNS) announce alarm events onto
SeaTalkHS and how a client acknowledges/controls them. RAYDP **SID 27 (0x1b)**,
firmware name `Alarm`, shown on the E80's diagnostics screen as "Alarm". Both
served and consumed; not yet implemented in `/raymarine/NET`.

## What it is

Alarm is a small event service. Any device that raises an alarm condition
**broadcasts** an alarm event to a shared multicast group, and any device can
send an alarm **control** message back to a unit's unicast port to act on it
(acknowledge / silence / clear). It is the network face of the unit's alarm
state -- the same alarm that beeps and shows on the E80's screen is announced
here. Unlike the instrument services, the alarm group is **shared and
well-known**, and alarms are broadcast by **both the master E80 and RNS**.

## Transport and framing

Alarm uses **fixed, well-known ports** -- it does *not* draw from the RAYDP
allocator like the instrument tail:

- **mcast 224.0.0.2:5801** -- the shared alarm broadcast group.
- **udp :5802** -- the unit's unicast control port.

Both are read from the unit's SysInfo configuration at construction, not
allocator-assigned. The service still advertises itself by RAYDP (these two
endpoints), and presents as diagnostics service-type 14 on the unit.

Messages are bare little-endian datagrams that lead with a 4-byte **command
word** and carry no length prefix (the datagram length is the message length),
the same scheme the instrument services use (see [GPS](Gps.md)):

```
cmd_word = (sid << 16) | (dir << 8) | sel
           sid = 0x001b (Alarm)
           dir = 0x00  event   (broadcaster -> mcast 224.0.0.2:5801)
                 0x01  control (client     -> a unit's unicast :5802)
           sel = 0x01  (the alarm message selector)
```

So the two message words are `0x001b0001` (event) and `0x001b0101` (control).

## Message set

| cmd_word     | direction              | bytes | meaning                          |
| ------------ | ---------------------- | :---: | -------------------------------- |
| `0x001b0001` | broadcaster -> mcast   | 15    | alarm event (state announcement) |
| `0x001b0101` | client -> unicast      | 9     | alarm control (ack / set state)  |

### Alarm event (`0x001b0001`, 15 bytes)

Broadcast to 224.0.0.2:5801 whenever an alarm changes. Built and sent on every
change-notification from the unit's alarm manager:

```
[0]  cmd_word (4)        0x001b0001
[4]  source (4)          the broadcasting unit's machine id (so receivers
                         know which device raised the alarm)
[8]  alarm id (4)        identifies the alarm
[12] status byte
[13] status byte
[14] status byte
```

The three status bytes carry the alarm's state (active / acknowledged / cleared,
plus presumably a type or severity); their exact mapping is **not yet confirmed**
and is best resolved by a capture (see *Status and open edges*).

### Alarm control (`0x001b0101`, 9 bytes)

Sent to a unit's unicast :5802 to act on an alarm. The unit's receive thread
validates the length (exactly 9) and applies it to the alarm manager:

```
[0]  cmd_word (4)        0x001b0101
[4]  value (4)           the target alarm (an id or selector)
[8]  state byte          the requested action (e.g. acknowledge / silence)
```

The control message carries **no client reply-port** and gets **no unicast
reply** -- like the instrument commands, the only observable effect is the next
event the unit broadcasts to the group. A client therefore acts by sending a
control message and watching the group for the resulting state change.

## Status and open edges

**Established (firmware):** the SID, the fixed `224.0.0.2:5801` / `:5802`
endpoints (read from SysInfo, outside the allocator), the bare-command-word
framing, the event/control direction split (events broadcast on change; control
messages get no reply and carry no reply-port), and the two message structures
(15-byte event, 9-byte control) with their field offsets.

**Not yet pinned:**

- The meaning of the three event status bytes and the control state byte
  (the active/acknowledged/cleared/severity encoding).
- The `alarm id` namespace -- which numeric ids correspond to which on-screen
  alarms.

Both are best resolved by a capture: trigger known alarms on the E80 (and via
RNS) and correlate the on-screen alarm and an acknowledge action to the
broadcast bytes. Because the group is shared and both the E80 and RNS broadcast,
a passive listener on 224.0.0.2:5801 sees the full alarm traffic of the network.

## Why it matters

Alarm is a compact, fixed-port, read-friendly service: a passive subscriber on
the well-known group sees every alarm event on the network without any handshake,
and the control side is a single 9-byte datagram. It is a natural candidate for a
`/raymarine/NET` decoder (`d_Alarm`) -- the read side is harmless monitoring; the
control side acts on real alarm state and is out of scope for passive use.

---

**Next:** [Home (Abstracts)](readme.md) ...
