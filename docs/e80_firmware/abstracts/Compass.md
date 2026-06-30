# Compass

Return to [**Abstracts**](readme.md)

The compass network service: how the E80 republishes the boat's heading sensor
onto SeaTalkHS, and how a networked client reads that heading and can drive the
sensor's calibration. RAYDP **SID 26 (0x1a)**, firmware name `Compass`, shown on
the E80's own diagnostics screen as "Compass". Both consumed and served by the
E80; not yet implemented in `/raymarine/NET`.

## What it is

A heading sensor (a fluxgate or a rate/attitude compass) reaches the E80 over
SeaTalk1, NMEA, or NMEA 2000. The E80 maintains one in-memory compass record and
**republishes it on SeaTalkHS** as the Compass service so any networked display
shows the same heading. The same path runs in reverse: a networked client can
ask the E80 to **calibrate** the sensor -- enter and exit *linearisation* (the
deviation-swing the sensor performs to build its correction table), request an
immediate live heading, or apply a fixed heading offset -- and the E80 forwards
those to the real sensor.

The service is named from the firmware's `CCompassMsg_*` message classes.

## Transport and framing

Compass is a UDP service on the on-demand instrument tail (it constructs only
when compass data appears, claiming the next free unicast port from 2056 and
multicast group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)). The
advertisement carries both the server's **unicast** ip:port and its **multicast**
ip:port.

Two client roles, as with the other instrument services:

- **Subscribers** join the multicast group and *receive* the report. Joining is
  the subscription; the server **pushes** a fresh report to the group whenever
  the heading record changes.
- **Commanders** send command datagrams to the unicast port to calibrate the
  sensor. A command gets **no unicast reply** and carries **no client
  reply-port**; the only observable effect is the next report on the group.

Every message is a bare little-endian datagram leading with a 4-byte **command
word** and no length prefix:

```
cmd_word = (sid << 16) | dir | sel
           sid = 0x001a (Compass)
           dir = 0x100  command  (client -> server's unicast port)
                 0x000  report   (server -> its multicast group)
           sel = low byte selects the message
```

## Message set

The firmware defines five `CCompassMsg_*` classes: one report and four commands.

| cmd_word                   | message (`CCompassMsg_*`) | direction         | meaning                                       |
| -------------------------- | ------------------------- | ----------------- | --------------------------------------------- |
| `0x001a0000`               | UpdateCompassStatus       | server -> mcast   | the heading / attitude report (25 bytes)      |
| `0x001a0100`..`0x001a0102` | three no-arg commands     | client -> unicast | calibration actions -- named in *Commands*    |
| `0x001a0103`               | SetHeadingOffset          | client -> unicast | set a heading offset (cmd_word + one u16 = 6 bytes) |

The single report (`UpdateCompassStatus`, sel `0x00`) is broadcast on every
change to the heading record. The four commands (sel `0x00`..`0x03`) are
length-checked and forwarded to the compass provider object; they are the
firmware's four `CCompassMsg_*` command classes, named in *Commands* below.

## UpdateCompassStatus layout (25 bytes)

`UpdateCompassStatus` is a fixed **25-byte (0x19)** datagram -- the length is
checked on receive. After the command word the record carries roughly **five
16-bit values and three bytes** -- heading, and the attitude/rate fields a
rate-gyro compass adds (pitch, roll, rate, plus status/quality bytes). The byte
layout is established as five u16 + three bytes; the **individual field meanings
and exact offsets are not yet confirmed** (see *Open edges*):

| offset    | size | field           | notes                                |
| --------- | ---- | --------------- | ------------------------------------ |
| 0x00      | 4    | cmd_word        | `0x001a0000`                         |
| 0x04-0x0b | 8    | header / scalar | leading bytes (not decoded into the notified record) |
| 0x0c      | 2    | u16             | likely heading                       |
| 0x0e      | 2    | u16             | attitude / rate                      |
| 0x10      | 2    | u16             | attitude / rate                      |
| 0x12      | 2    | u16             | attitude / rate                      |
| 0x14      | 2    | u16             | attitude / rate                      |
| 0x16      | 1    | byte            | status / quality                     |
| 0x17      | 1    | byte            | status / quality                     |
| 0x18      | 1    | byte            | status / quality                     |

On receive the client copies the decoded fields into its compass record and
notifies every registered change-sink. The "five u16 plus three bytes" grouping
is read from the decoder; which u16 is heading versus pitch/roll/rate is
inferred, not yet confirmed.

## Commands

The four commands are the firmware's four `CCompassMsg_*` command classes. Every
field below is read from the firmware: the command word, length, and argument
shape from the server's receive dispatch; the class name from the client proxy's
send methods (each pairs its command word with the message class it builds). The
mapping is **verified, not inferred**:

| cmd_word     | length | argument | provider slot | command class (`CCompassMsg_*`) |
| ------------ | ------ | -------- | ------------- | ------------------------------- |
| `0x001a0100` | 4      | (none)   | vt[0x34]      | `RequestLiveHeading`            |
| `0x001a0101` | 4      | (none)   | vt[0x3c]      | `EnterLinearisation`            |
| `0x001a0102` | 4      | (none)   | vt[0x44]      | `ExitLinearisation`             |
| `0x001a0103` | 6      | u16      | vt[0x4c]      | `SetHeadingOffset`              |

`RequestLiveHeading` prompts an immediate heading report; `EnterLinearisation`
and `ExitLinearisation` bracket the deviation-swing calibration; `SetHeadingOffset`
applies a fixed 16-bit heading correction.

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing, the
unicast-command / multicast-report split, the complete five-message set with
their command words and directions, the 25-byte report length and its five-u16 +
three-byte shape, and every command's class name, length, argument shape, and
provider-vtable slot.

**Not yet pinned:**

- The individual meaning of each report field (which u16 is heading versus
  pitch / roll / rate, and the meaning of the three status bytes).

This is best resolved by a live capture with a heading sensor present --
correlating the on-screen heading and attitude to the byte offsets.

## Why it matters

The Compass service is the network face of the boat's heading sensor: it lets any
SeaTalkHS display read heading and attitude, and drive calibration, without its
own compass wiring. The read side is a small, attractive target -- a 4-byte
subscribe and a fixed 25-byte report -- and a natural candidate for a new
`/raymarine/NET` decoder (`d_Compass`). Read-side decoding is harmless; the
calibration commands act on the real sensor and are out of scope for passive
monitoring.

---

Return to [**Abstracts**](readme.md)
