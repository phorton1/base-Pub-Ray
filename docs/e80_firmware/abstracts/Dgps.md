# DGPS

Return to [**Abstracts**](readme.md)

The differential-GPS network service: how the E80 republishes the status of a
differential / augmentation correction source onto SeaTalkHS, and how a client
configures it. RAYDP **SID 21 (0x15)**, firmware name `DGPS` (the `CDGPSMsg_*`
message classes), shown on the E80's diagnostics screen as "DGPS". Both served
and consumed; not yet implemented in `/raymarine/NET`. DGPS is the sibling of
the [GPS](Gps.md) service (SID 8) -- the same instrument framework, a smaller
message set.

## What it is

DGPS is the network face of the boat's **differential correction source** -- the
beacon receiver / SBAS / augmentation channel that improves a GPS fix. The E80
maintains a DGPS status record (which mode is active, which source/station, the
correction quality) and **republishes it on SeaTalkHS** so any networked display
shows the same differential status; in reverse, a client can send a single
**configuration command** to select the differential mode and source, which the
E80 applies to the real hardware.

## Transport and framing

DGPS is a UDP service on the **on-demand instrument tail**: it constructs only
when DGPS data/hardware appears, claiming the next free unicast port from
**2056** and multicast group from **2563** (see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)). It
presents as diagnostics service-type 9 on the unit. The advertisement carries
both the server's unicast and multicast ip:port.

As with the other instrument services, there are two client roles rather than a
request/response exchange:

- **Subscribers** join the server's multicast group and *receive* the report.
  Joining is the subscription; the server **pushes** a fresh report to the group
  whenever its DGPS record changes.
- **Commanders** send a command datagram to the server's unicast port. The
  command gets **no unicast reply** and carries **no client reply-port**; the
  only observable effect is the next report broadcast to the group.

Every message is a bare little-endian datagram leading with a 4-byte **command
word** and no length prefix (the datagram length is the message length):

```
cmd_word = (sid << 16) | (dir << 8) | sel
           sid = 0x0015 (DGPS)
           dir = 0x00  report   (server -> its multicast group)
                 0x01  command  (client -> server's unicast port)
           sel = 0x00
```

## Message set

DGPS has just two messages -- one report and one command (contrast GPS's ten):

| cmd_word     | direction            | bytes | meaning                          |
| ------------ | -------------------- | :---: | -------------------------------- |
| `0x00150000` | server -> mcast      | 19    | DGPS status report               |
| `0x00150100` | client -> unicast    | 9     | set DGPS configuration           |

### DGPS status report (`0x00150000`, 19 bytes)

Broadcast to the multicast group on every change to the DGPS record. The wire
message repackages the provider's status record into a fixed 19-byte datagram.
The structure is established; the **field semantics are not yet confirmed** (see
*Status and open edges*), so the body is given as typed slots:

| offset | size | field      | notes                                          |
| ------ | ---- | ---------- | ---------------------------------------------- |
| 0x00   | 4    | cmd_word   | `0x00150000`                                   |
| 0x04   | 4    | u32        | status / source word                           |
| 0x08   | 1    | byte       | (differential mode?)                           |
| 0x09   | 1    | byte       | (source select?)                               |
| 0x0a   | 2    | u16        |                                                |
| 0x0c   | 1    | byte       |                                                |
| 0x0d   | 2    | u16        | (station id?)                                  |
| 0x0f   | 1    | byte       |                                                |
| 0x10   | 2    | u16        | (correction quality / age?)                    |
| 0x12   | 1    | byte       |                                                |

### Set DGPS configuration (`0x00150100`, 9 bytes)

Sent to the server's unicast port. The receive thread length-checks it (exactly
9) and forwards the arguments to a single configuration slot on the DGPS
provider:

```
[0]  cmd_word (4)   0x00150100
[4]  byte           config arg 1 (differential mode?)
[5]  byte           config arg 2 (source?)
[6]  byte           config arg 3 (network?)
[7]  u16            config arg 4 (station id / frequency?)
```

There is exactly one command (one provider config slot), matching the small set
of differential settings. The consume-side source mirrors this as five
configuration items (the mode, source, network, station, and an enable),
addressed by item id rather than command word.

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing on the
dynamic instrument tail, the report/command split (report pushed on change;
command gets no reply and carries no reply-port), the two-message set with their
command words and directions, the 19-byte report structure, and the 9-byte
configuration command and its argument shape.

**Not yet pinned:**

- The meaning of each field in the report body and each argument in the command
  (which slot is differential mode, source, station id, correction quality/age).

This is best resolved by a live capture with a differential source active --
changing the differential mode/source on the E80 and correlating the on-screen
DGPS status to the report bytes.

## Why it matters

DGPS is a compact read target: a 4-byte subscribe and a single fixed 19-byte
report carry the whole differential picture, a natural companion to a `d_GPS`
decoder. Read-side decoding is harmless monitoring; the configuration command
acts on the real correction source and is out of scope for passive use.

---

Return to [**Abstracts**](readme.md)
