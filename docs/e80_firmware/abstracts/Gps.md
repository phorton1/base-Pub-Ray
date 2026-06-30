# GPS

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

The GPS network service: how the E80 republishes a GPS receiver's fix and
satellite picture onto SeaTalkHS, and how a networked client reads that picture
and can configure the receiver. RAYDP **SID 8 (0x08)**, firmware name `GPS`,
shown on the E80's own diagnostics screen as "GPS". Both consumed and served by
the E80; not yet implemented in `/raymarine/NET`.

## What it is

A GPS sensor is not usually a SeaTalkHS device. The E80 takes a fix from a
connected receiver (SeaTalk1, NMEA, or an internal/antenna source), maintains
one in-memory GPS record, and **republishes that record on SeaTalkHS** as the
GPS service so any networked display shows the same position, fix quality, and
satellite status. The same path runs in reverse: a networked client can send
**configuration commands** -- choose the chart datum, set position smoothing,
enable or pick a differential-correction source, restart the receiver -- and the
E80 forwards them to the real GPS hardware.

The report is large and rich: a scalar navigation block plus **two 32-entry
satellite tables** (the firmware tracks two parallel constellations -- a GPS set
and a differential/augmentation set), giving a full sky view, not just a fix.

The service is named from the firmware's `CGPSMsg_*` message classes (a sibling
`CDGPSMsg_*` set backs the separate DGPS service, SID 0x15).

## Transport and framing

GPS is a UDP service on the on-demand instrument tail (it constructs only when
GPS data appears, claiming the next free unicast port from 2056 and multicast
group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)). The
advertisement carries both the server's **unicast** ip:port and its **multicast**
ip:port.

As with the other instrument services, picture two distinct client roles rather
than a request/response exchange:

- **Subscribers** join the server's multicast group and *receive* the report.
  Joining the group is the subscription -- there is no handshake or per-client
  registry. The server **pushes** a fresh report to the group whenever the GPS
  record changes (it is a change-sink on the underlying GPS data).
- **Commanders** send command datagrams to the server's unicast port to
  configure the receiver. A command gets **no unicast reply** and carries **no
  client reply-port**: the only observable effect is the next report the server
  broadcasts to the group.

Every message is a bare little-endian datagram that leads with a 4-byte
**command word** and carries no length prefix (the datagram length is the
message length):

```
cmd_word = (sid << 16) | dir | sel
           sid = 0x0008 (GPS)
           dir = 0x100  command  (client -> server's unicast port)
                 0x000  report   (server -> its multicast group)
           sel = low byte selects the message
```

## Message set

The firmware defines ten `CGPSMsg_*` classes: one report and nine commands.

| cmd_word                   | message (`CGPSMsg_*`)  | direction         | meaning                                          |
| -------------------------- | ---------------------- | ----------------- | ------------------------------------------------ |
| `0x00080000`               | UpdateGPSStatus        | server -> mcast   | the full GPS fix + satellite report (626 bytes)  |
| `0x00080100`..`0x00080108` | nine command classes   | client -> unicast | configure the receiver -- named in *Commands*    |

The single `server -> mcast` report (`UpdateGPSStatus`, sel `0x00`) is broadcast
on every change to the GPS record. The nine `client -> unicast` commands
(sel `0x00`..`0x08`) are the inputs the server accepts; each is length-checked
and validated, then forwarded to a slot on the GPS provider object. The nine
command-message classes and their command words are named in *Commands* below.

## UpdateGPSStatus layout (626 bytes)

`UpdateGPSStatus` is a fixed **626-byte (0x272)** datagram -- the length is
checked on receive and fixed on send. The structure is established; the
**semantics of the individual scalar fields are not yet confirmed** (see *Open
edges*), so the leading block is given here as typed slots:

| offset | size | field            | notes                                              |
| ------ | ---- | ---------------- | -------------------------------------------------- |
| 0x000  | 4    | cmd_word         | `0x00080000`                                       |
| 0x004  | 44   | scalar nav block | u32 / u16 / byte mix (fix, mode, HDOP, time, etc.) |
| 0x028  | 4    | u32              | likely latitude                                    |
| 0x02c  | 4    | u32              | likely longitude                                   |
| 0x030  | 256  | satellite table A| 32 entries x 8 bytes (see below)                   |
| 0x130  | 256  | satellite table B| 32 entries x 8 bytes (differential / augmentation) |
| 0x230  | 32   | byte[32]         | per-entry flags for table A (in-use / tracked)     |
| 0x250  | 32   | byte[32]         | per-entry flags for table B                        |
| 0x270  | 1    | count A          | number of valid entries in table A                 |
| 0x271  | 1    | count B          | number of valid entries in table B                 |

Each **satellite-table entry** is 8 bytes:

| offset | size | field   | notes                          |
| ------ | ---- | ------- | ------------------------------ |
| +0     | 3    | sat id  | satellite identifier (3 bytes) |
| +3     | 2    | u16     | e.g. azimuth                   |
| +5     | 2    | u16     | e.g. elevation / SNR           |
| +7     | 1    | byte    | e.g. status                    |

On receive, the client copies the scalar block into its GPS record and notifies
every registered change-sink; that is how a second display tracks position and
satellites live. The two parallel tables plus their separate counts and flag
arrays are the standard "two constellations" picture (primary GPS and a
differential/augmentation set), but the per-field azimuth/elevation/SNR mapping
is inferred, not yet confirmed.

## Commands

The nine commands are the firmware's nine `CGPSMsg_*` command classes. Every
field below is read from the firmware: the command word, datagram length, and
argument shape from the server's receive dispatch; the class name from the
client proxy's send methods (each method pairs its command word with the message
class it builds). The mapping is therefore **verified, not inferred**:

| cmd_word     | length | argument           | provider slot | command class (`CGPSMsg_*`) |
| ------------ | ------ | ------------------ | ------------- | --------------------------- |
| `0x00080100` | 4      | (none)             | vt[0x3c]      | `RestartGPS`                |
| `0x00080101` | 5      | 1 byte             | vt[0x44]      | `SetSmoothing`              |
| `0x00080102` | 5      | 1 byte             | vt[0x4c]      | `SetEnableDiffMode`         |
| `0x00080103` | 5      | 1 byte             | vt[0x54]      | `SetDiffSource`             |
| `0x00080104` | 5      | 1 byte             | vt[0x5c]      | `SetSatDiffNetwork`         |
| `0x00080105` | 8      | u32                | vt[0x64]      | `SetEnabledSDSats`          |
| `0x00080106` | 6      | u16                | vt[0x6c]      | `SetPreDefinedDatum`        |
| `0x00080107` | 11     | 1 byte + three u16 | vt[0x74]      | `SetUserDefinedDatum`       |
| `0x00080108` | 4      | (none)             | vt[0x34]      | `MasterResetGPS`            |

The two no-arg commands are the receiver power cycles (`RestartGPS`,
`MasterResetGPS`). The four single-byte setters select the position smoothing
level, the differential-mode enable, the differential source, and the
satellite-differential network. `SetEnabledSDSats` carries a **32-bit
per-satellite enable mask** (the u32 argument -- one bit per tracked satellite).
The datum pair sets either a predefined datum index (`SetPreDefinedDatum`, u16)
or a user-defined datum (`SetUserDefinedDatum`, a datum selector byte plus three
16-bit offsets).

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing, the
unicast-command / multicast-report split (reports pushed on change, commands get
no unicast reply and carry no reply-port), the complete ten-message set with
their command words and directions, the 626-byte `UpdateGPSStatus` structure
(scalar block, two 32-entry satellite tables with 8-byte entries, the two flag
arrays and the two counts), and every command's class name, length, argument
shape, and provider-vtable slot.

**Not yet pinned:**

- The individual meaning of each scalar field in the leading 0x04..0x2f block
  (which slot is fix mode, HDOP, UTC, the lat/lon scaling) and the exact
  per-field meaning of the 8-byte satellite entries (azimuth / elevation / SNR /
  status order).

This is best resolved by a live capture with a fix present -- feeding known
GPS data and correlating the on-screen position, fix quality, and sky view to
the byte offsets above.

## Why it matters

The GPS service is the network face of the boat's position source: it lets any
SeaTalkHS display read the fix *and* the full satellite picture, and reconfigure
the receiver, without its own GPS wiring. For interoperability the read side is
an attractive target -- a 4-byte subscribe and a single fixed 626-byte report
carry the entire fix-plus-sky view -- and a natural candidate for a new
`/raymarine/NET` decoder (`d_GPS`) alongside the existing `WPMGR`, `TRACK`,
`FILESYS`, and `Database` modules. Read-side decoding is harmless; the
configuration commands act on the real receiver and are out of scope for passive
monitoring.

---

**Next:** [Home (Abstracts)](readme.md) ...
