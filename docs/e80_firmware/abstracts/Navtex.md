# Navtex

Return to [**Abstracts**](readme.md)

The NAVTEX network service: how the E80 republishes received NAVTEX text
messages onto SeaTalkHS as a shared message store, and how a networked client
mirrors that store and can clear alerts or delete messages. RAYDP
**SID 29 (0x1d)**, firmware name `Navtex`, shown on the E80's own diagnostics
screen as "Navtex". Both consumed and served by the E80; not yet implemented in
`/raymarine/NET`.

## What it is

NAVTEX is a maritime safety-broadcast service: a receiver picks up text messages
(navigational and weather warnings) over the air. The receiver reaches the E80
over SeaTalk1 or NMEA; the E80 reassembles each message, keeps a **message-store
database** of them, and **republishes that store on SeaTalkHS** as the Navtex
service so any networked display holds the same set of messages. Unlike the
scalar instrument services (GPS, Compass), the Navtex report stream is not a
single fixed record -- it is a set of **store mutations**: a message arrives
(possibly in chunks), a message is deleted, an alert is cleared.

A networked client mirrors the store by applying those mutations, and can act on
it: clear an alert, delete a message, or ask for the whole store to be resent.
The service is named from the firmware's `CNavtex_*` message classes; messages
are keyed by a `CNavtex_NavtexMessageID`.

## Transport and framing

Navtex is a UDP service on the on-demand instrument tail (it constructs only when
NAVTEX data appears, claiming the next free unicast port from 2056 and multicast
group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)). The
advertisement carries both the server's **unicast** ip:port and its **multicast**
ip:port.

Two client roles:

- **Subscribers** join the multicast group and *receive* the store mutations.
  Joining is the subscription; the server **pushes** a mutation to the group as
  each one happens (it is a change-sink on the message store).
- **Commanders** send command datagrams to the unicast port to act on the store.
  A command gets **no unicast reply** and carries **no client reply-port**; its
  effect appears as the resulting store mutation(s) broadcast to the group. The
  *get-all* command makes the server replay the whole store as a burst of
  message reports.

Every message is a bare little-endian datagram leading with a 4-byte **command
word** and no length prefix:

```
cmd_word = (sid << 16) | dir | sel
           sid = 0x001d (Navtex)
           dir = 0x100  command  (client -> server's unicast port)
                 0x000  report   (server -> its multicast group)
           sel = low byte selects the message
```

## Message set

The firmware defines `CNavtex_*` wire classes -- three reports and three
commands (a `CNavtex_NavtexMessageID` keys the store; it is not itself a wire
message):

| cmd_word     | message (`CNavtex_*`) | direction         | meaning                                          |
| ------------ | --------------------- | ----------------- | ------------------------------------------------ |
| `0x001d0000` | MessageUpdate         | server -> mcast   | a message chunk; reassembled into the store      |
| `0x001d0001` | AlertCleared          | server -> mcast   | the alert for a message id was cleared           |
| `0x001d0002` | MessageDeleted        | server -> mcast   | a message id was removed from the store          |
| `0x001d0100` | ClearAlert            | client -> unicast | clear the alert for one message id (cmd_word + u32 id) |
| `0x001d0101` | DeleteMessage         | client -> unicast | delete one message by id (cmd_word + u32 id)     |
| `0x001d0102` | GetAllMessages        | client -> unicast | replay the whole store (no argument)             |

Every binding is read from the firmware: the command words and directions from
the server's receive dispatch, and the class names from the client proxy's send
methods (each pairs its command word with the message class it builds). The two
id-bearing commands -- `ClearAlert` (`0x001d0100`) and `DeleteMessage`
(`0x001d0101`) -- are confirmed by name, not just by shape; `AlertCleared` is the
server's notification that follows a `ClearAlert`, and `MessageDeleted` the one
that follows a `DeleteMessage`.

## MessageUpdate: chunked text reassembly (`0x001d0000`)

A NAVTEX message can exceed one datagram, so `MessageUpdate` carries the text in
**chunks** that the receiver reassembles. Each chunk datagram is:

| offset | size | field        | notes                                              |
| ------ | ---- | ------------ | -------------------------------------------------- |
| 0x00   | 4    | cmd_word     | `0x001d0000`                                       |
| 0x04   | 2    | (header)     |                                                    |
| 0x06   | 2    | msg_id       | u16 -- the message key; identifies which message   |
| 0x08   | 1    | total_chunks | number of chunks that make up this message         |
| 0x09   | 1    | (pad)        |                                                    |
| 0x0a   | 2    | chunk_len    | u16 -- bytes of text in this chunk                 |
| 0x0c   | ...  | text         | `chunk_len` bytes of message text                  |

The source accumulates chunks into an ~8KB buffer keyed by `msg_id`, tracking a
running length and a chunk counter. When the received chunk count reaches
`total_chunks`, the completed message is inserted into the source's
message-store (a balanced-tree store keyed by id) and registered change-sinks
are notified. A client mirrors the same algorithm: append by `msg_id`, and on
the final chunk commit the message to its own store.

## AlertCleared and MessageDeleted

The other two reports are single-id mutations:

| cmd_word     | message        | payload                | effect on the store                            |
| ------------ | -------------- | ---------------------- | ---------------------------------------------- |
| `0x001d0001` | AlertCleared   | u32 message id @ +0x04 | the alert flag for that message is cleared     |
| `0x001d0002` | MessageDeleted | u32 message id @ +0x04 | the message is removed from the store          |

Each is broadcast to the group when the corresponding change happens, and a
client applies it by clearing the alert on, or removing, the matching id in its
mirror. (`AlertCleared` notifies registered sinks through a distinct change-sink
slot from the delete path; it is the report the server emits in response to a
`ClearAlert` command, as `MessageDeleted` is the response to `DeleteMessage`.)

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing, the
mutation-stream model (reports are store mutations, not a fixed record), the
three reports and three commands with their command words and directions, the
`MessageUpdate` chunk header (msg_id, total_chunks, chunk_len, text) and the
reassembly-by-id algorithm, the single-u32-id payload of `AlertCleared` and
`MessageDeleted`, the *get-all* replay behaviour of `GetAllMessages`, and the
class name of every report and command (all six are verified from the firmware).

**Not yet pinned:**

- The two header bytes at +0x04 of `MessageUpdate` (sequence / flags) and the
  exact text encoding (NAVTEX is 7-bit SITOR/ASCII; whether any framing survives
  into the chunk text).

This is best resolved by a live capture with a NAVTEX source present --
correlating an arriving message and the chunk fields.

## Why it matters

The Navtex service is a small, self-contained **database protocol**: a tree of
text messages mirrored over multicast by a stream of three mutation reports, with
a one-shot *get-all* to seed a fresh client. That makes it an approachable
`/raymarine/NET` decoder (`d_Navtex`) -- closer in shape to the waypoint/track
stores than to the scalar instruments -- and the read side (subscribe, reassemble
chunks, track adds and deletes) is harmless monitoring. The two id-bearing
commands act on the unit's message store and are out of scope for passive use.

---

Return to [**Abstracts**](readme.md)
