# DATABASE

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**DATABASE** --
**[DB_FIDS](DB_FIDS.md)** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The E80 Database service is the E80's central field-publishing service.
It presents itself as two service-ports at IP addresses published by
RAYDP:

- DATABASE on TCP port 2050 at the E80's native IP address;
- DBNAV as a multicast broadcaster on UDP 2562, at a per-unit group derived
  from the unit IP (see [Multicast group addressing](RAYDP.md#multicast-group-addressing);
  e.g. 224.30.10.99 for a unit at 10.0.240.83).

DATABASE is both a subscription manager and a point-to-point read/write
interface; DBNAV is the broadcast side of the subscription process. The
two channels are one service in the firmware -- the TCP side is how a
client says "I'd like to know about this FID"; the multicast side is the
E80 saying "here are the current values of every FID someone asked
about."

This document specifies that protocol: the **conversation** -- the
packets, commands, and transactions that move records between client and
unit. The **interior** of a record -- how to decode its value and read
its source stamp -- is handed off to [DB_DECODE](DB_DECODE.md). The line
between the two documents is firm: DATABASE moves records and never draws
their interior bytes; DB_DECODE owns the record interior. Every record
that crosses either channel is referred to here as the `record` piece and
defined in DB_DECODE.

## Definitions

This document and its peers use the following terms precisely.

- **FID** (field ID) -- a semantically identified quantity in the
  firmware's data dictionary: *what* a datum is -- heading, depth, engine
  RPM. A single FID may be fed by one source or several (a twin-engine
  boat feeds the engine-RPM FID from two engines). Written uppercase
  throughout. The per-FID catalogue is [DB_FIDS](DB_FIDS.md).
- **ENC** (encoding) -- the data-encoding type of a FID's value: its
  structure, units, scale, precision. A FID names the quantity; its ENC
  says how to decode the bytes. One ENC serves many FIDs. The ENC
  catalogue is [DB_DECODE](DB_DECODE.md). This document defines only the
  term.
- **SOURCE** -- which source produced a value, along two sub-axes: the
  source **family** (NMEA 2000, NMEA 0183, a SeaTalk instrument, an
  internal computation, a GPS/compass fusion) and the source **class** (a
  per-FID source-binding tag). A value carries its SOURCE as a provenance
  stamp; for an NMEA 2000 source the stamp also carries the originating
  PGN and bus source-address. The family/class catalogue is
  [DB_DECODE](DB_DECODE.md); this document defines only the term.
- **TTL** (time-to-live) -- a countdown timer carried in the multicast
  (subscription) broadcast form of a record; when it reaches zero the E80
  stops broadcasting that value.

The database moves a single kind of record: the **value-record** -- a
FID's value from one source: the value bytes (decoded per the FID's ENC)
together with that source's SOURCE provenance stamp. A FID may have
several sources (a twin-engine boat feeds the engine-RPM FID from two
engines), and each source has its own value-record.

What the protocol offers in two forms is *which* of a FID's sources you
get:

- the **value** (preferred) view -- the one preferred source's
  value-record: the FIELD / value channel (CMD_SUB_VALUE, CMD_GET_VALUE,
  the 0x300 broadcast).
- the **directory** (all-sources) view -- every source of a FID, each as
  its own value-record: the UUID / directory channel (CMD_SUB_DIR,
  CMD_LIST, CMD_GET_ITEM, the 0x301 broadcast).

A source is named by an 8-byte **UUID** (`[device_id | per-item]`) carried
at the transaction-envelope level (the Start/End frames); it identifies
which source a transaction concerns and is never part of a record body.
The byte layout of a value-record -- and the codec that reads and writes
it -- is [DB_DECODE](DB_DECODE.md); this document treats every record as a
complete, delimited blob addressed to a FID.

## Wire envelope

Every message: `[len:2] [cmd_word:4] [body...]`, little-endian. `len`
counts the bytes after itself. The TCP socket layer frames on `len`; the
firmware sees `cmd_word` first.

```
cmd_word = svc(0x0010) << 16 | dir | code
```

`cmd_word` is a **flat 16-bit message id** within the DB service -- the
firmware dispatches on the full word, with no direction masking. The high
byte only *clusters* messages by role:

| dir | name | role |
|-----|------|------|
| 0x000 | DIR_RECV | **response** -- server's short reply to a request |
| 0x100 | DIR_SEND | **request** -- client -> server verb |
| 0x200 | DIR_INFO | **transaction** -- bidirectional; carries the serialized record |
| 0x300 | DIR_BCAST | **broadcast** -- DBNAV multicast |
| 0x500 | DIR_EVENT | **event / close** |

The `dir` nibble and these `DIR_` names are common to RAYNET services
generally, not specific to DATABASE.

## Field vocabulary (the pieces)

The atoms every message is built from. Generic pieces are shared by all
RAYNET services; DB-specific pieces are added by the DB parser.

| piece | bytes | encoding | meaning |
|-------|-------|----------|---------|
| `seq` | 4 | u32 LE | sequence number; links a reply's frames to the request. Echoed in every frame of a transaction. |
| `fid` | 4 | u32 LE | field id; high word zero for instrument fids, non-zero for app fids. Used here as a routing key; its semantics are [DB_FIDS](DB_FIDS.md). |
| `uuid` | 8 | bytes | a source identifier `[device_id:4][per-item:4]`, carried at the transaction-envelope level (the Start/End frames); names which source a transaction concerns |
| `success2` | 4 | u32 LE | the StartTransaction status word; `0x00000004` on captures |
| `db_bits` | 2 | u16 LE | a 16-bit flags word, meaning by context: in a REPLY_VALUE an inverted found flag (`0` = present/feeding); in a PUSH_VALUE the change-kind (delete = 3) |
| `word` | 2 | u16 LE | a 16-bit value, by context (a result word, or a pushed record field) |
| `biglen` | 4 | u32 LE | byte length of the `record` that follows in a transaction's SendData frame |
| `record` | var | see [DB_DECODE](DB_DECODE.md) | one serialized value-record (datum + provenance). The TCP transactions carry its transaction form; the multicast carries its broadcast form. |
| `count` | 4 | u32 LE | number of sources in an ItemList response |
| `zero` | 4 | u32 LE | the `seq` slot, zero in unsolicited (event) frames |

`record` and the per-source descriptor it carries are defined in
[DB_DECODE](DB_DECODE.md) (the ENC catalogue + the source-provenance
decoder). The protocol treats `record` as an opaque blob -- length-
prefixed by `biglen` in a TCP transaction, self-delimiting in a broadcast
-- and never reads into it.

Two kinds of fid appear throughout. An **inst-fid** has its high word
zero and names a measured quantity. An **app-fid** has a non-zero high
word (the 0x01 / 0x03 / 0x05 / 0x06 namespaces) and names a setting or a
stored record. Both are read and written identically; the distinction
matters only for subscription (only inst-fids broadcast).

## Message catalog

Each row gives a message's `cmd_word`, its official `name`, the firmware
RTTI class (`message`), and its body pieces. Refer to a message by its
`name(cmd_word)`.

### Requests (0x100, client -> server)

| cmd_word | name | message | body | notes |
|----------|------|---------|------|-------|
| 0x100 | CMD_SUB_DIR | RegisterForUpdates | `fid` | subscribe all of a fid's sources (the directory channel) |
| 0x101 | CMD_DEF | (unknown) | `seq,fid` | metadata probe; no reply to a bare request |
| 0x102 | CMD_SUB_VALUE | RegisterForPreferredUpdates | `fid` | subscribe a fid's value (the only value subscription) |
| 0x103 | CMD_EXISTS | (unknown) | `seq,fid` | metadata probe; no reply to a bare request |
| 0x104 | CMD_LIST | GetItemList | `seq,fid` | enumerate a fid's sources -> REPLY_ITEM_LIST |
| 0x105 | CMD_GET_VALUE | GetPreferredItem | `seq,fid` | read the preferred source's value -> REPLY_VALUE |
| 0x106 | CMD_GET_ITEM | GetItemWithTransport | begins read txn | keyed read of one specific source -> REPLY_ITEM |
| 0x107 | CMD_PUT_ITEM | SetItemUnconfirmed | begins write txn | the value write; no reply (silence = accepted) |
| 0x108 | CMD_DEL_ITEM | DeleteItem | begins delete txn | delete one specific source by transport key |

A request that begins a transaction (CMD_GET_ITEM / CMD_PUT_ITEM /
CMD_DEL_ITEM) stashes its kind in a per-connection slot; the following
INFO_END commits per that slot.

### Responses (0x000, server -> client)

| cmd_word | name | message | body | reply to |
|----------|------|---------|------|----------|
| 0x002 | REPLY_ITEM_LIST | ItemList | `seq, fid, count, <per-source ids>` | CMD_LIST(0x104) |
| 0x003 | REPLY_VALUE | GetPreferredItemResponse | `seq, fid, db_bits, word` | CMD_GET_VALUE(0x105) |
| 0x004 | REPLY_ITEM | GetItemWithTransportResponse | (keyed-read ack) | CMD_GET_ITEM(0x106) |

ItemList is a fixed 48-byte frame: `cmd, seq, fid, count`, then one u16
source-id per source; the remainder is unused padding. Each source's
value rides in the INFO transaction that follows.

### Transaction / INFO (0x200, bidirectional)

The three phases of a record transfer; the low byte is the **phase**, not
a command.

| cmd_word | name | message | body |
|----------|------|---------|------|
| 0x200 | INFO_START | StartTransaction | `seq, uuid, success2` |
| 0x201 | INFO_RECORD | SendData | `seq, biglen, record` |
| 0x202 | INFO_END | EndTransaction | `seq, uuid` -- commits per the begin-request's conn state |

The zero-leading twins 0x203/204/205 (`zero` in place of `seq`) are the
unsolicited push form -- see Subscription pushes.

### Subscription pushes (server -> client, unsolicited)

On a change to a subscribed item the server pushes a change-event burst on
the subscriber's TCP connection, from a separate per-connection sink
(`seq` hardcoded `zero`).

| cmd_word | name | message | body |
|----------|------|---------|------|
| 0x000 | PUSH_DIR | (directory-change announce) | `zero, ...` |
| 0x001 | PUSH_VALUE | (value-change announce) | `zero, fid, db_bits, word` -- `db_bits` = change-kind |
| 0x203 | PUSH_START | UpdateStartTransaction | `zero, uuid, success2` |
| 0x204 | PUSH_RECORD | UpdateSendData | `zero, biglen, fid, record` -- the changed item |
| 0x205 | PUSH_END | UpdateEndTransaction | `zero, uuid` |

### Broadcast (0x300) and event (0x500)

| cmd_word | name | message | body |
|----------|------|---------|------|
| 0x300 | BCAST_VALUES | Report | `num_fields, <records>` -- preferred-source value-records |
| 0x301 | BCAST_DIRECTORY | UuidReport | `num_fields, <records>` -- all-source value-records |
| 0x500 | EVENT_PING | Ping | empty -- accepted no-op keepalive; NOT a close |

## DATABASE TCP transactions (port 2050)

The point-to-point control channel. Each line is `<dir> NAME(cmd_word)
pieces  RTTI-class  note`.

### 1. Read a value -- CMD_GET_VALUE(0x105)
One request, a four-frame reply (wire-verified):
```
->  CMD_GET_VALUE(0x105)     seq, fid                 GetPreferredItem          single-message request
<-  REPLY_VALUE(0x003)       seq, fid, db_bits, word  GetPreferredItemResponse  the ack (db_bits 0 = found)
<-  INFO_START(0x200)        seq, uuid, success2      StartTransaction          opens the value transaction
<-  INFO_RECORD(0x201)       seq, biglen, record      SendData                  THE VALUE (the serialized record)
<-  INFO_END(0x202)          seq, uuid                EndTransaction            closes
```
`record` is the serialized value-record (see [DB_DECODE](DB_DECODE.md)).
Reads are not namespace-gated: app/config fids (top byte 0x01/0x03/0x05/
0x06) answer point-to-point though they never broadcast. Not found / not
feeding: REPLY_VALUE returns with `db_bits` != 0 and no INFO frames
follow -- the same messages, a variant of this transaction.

### 2. Read a specific source -- CMD_GET_ITEM(0x106)
A keyed read of one specific source (vs the preferred source
CMD_GET_VALUE returns). The client names the source by its transport key
in a request transaction; the server answers with REPLY_ITEM and a value
transaction:
```
->  CMD_GET_ITEM(0x106)      seq, key                 GetItemWithTransport          begin (conn state 2)
->  INFO_START(0x200)        seq, uuid, success2      StartTransaction              opens the request transaction
->  INFO_RECORD(0x201)       seq, biglen, record      SendData                      the source descriptor (which source)
->  INFO_END(0x202)          seq, uuid                EndTransaction                closes the request
<-  REPLY_ITEM(0x004)        seq (keyed-read ack)     GetItemWithTransportResponse  the ack
<-  INFO_START(0x200)        seq, uuid, success2      StartTransaction              opens the value transaction
<-  INFO_RECORD(0x201)       seq, biglen, record      SendData                      THE VALUE (same record as CMD_GET_VALUE)
<-  INFO_END(0x202)          seq, uuid                EndTransaction                closes
```
Not found: REPLY_ITEM returns with its error flag set and no value
transaction follows. The request-side key + descriptor bytes are taken
from the firmware dispatch and are not yet wire-captured.

### 3. Enumerate sources -- CMD_LIST(0x104)
```
->  CMD_LIST(0x104)          seq, fid                       GetItemList       request
<-  REPLY_ITEM_LIST(0x002)   seq, fid, count, <source ids>  ItemList          one u16 source-id per source
```
then, for each of the `count` sources, one value transaction:
```
<-  INFO_START(0x200)        seq, uuid, success2            StartTransaction  opens source k's transaction
<-  INFO_RECORD(0x201)       seq, biglen, record            SendData          source k's value record
<-  INFO_END(0x202)          seq, uuid                      EndTransaction    closes  (repeats per source)
```
A twin-engine RPM fid returns `count=2` and two records -- the per-source
tree surfacing (the fid is the quantity, each source an instance). A
single-source fid returns `count=1`.

### 4. Write a value -- CMD_PUT_ITEM(0x107)
A transaction; no reply (silence = acceptance):
```
->  CMD_PUT_ITEM(0x107)      seq (begin; carries a 2-byte persist flag)   SetItemUnconfirmed
->  INFO_START(0x200)        seq, uuid, success2                          StartTransaction
->  INFO_RECORD(0x201)       seq, biglen, record                         SendData          the read's record, value changed
->  INFO_END(0x202)          seq, uuid                                    EndTransaction    commits the write
```
There is no reply on either outcome -- a write rejected by the gate is as
silent as one accepted; confirm a write by reading the value back.
Encoding the outgoing `record` is decoding in reverse (see
[DB_DECODE](DB_DECODE.md)).

- **Gate = ENC consistency, not ownership.** The commit compares the
  record's 16-bit ENC against the item's registered ENC; present the ENC
  a prior read handed you and the write is accepted. Not an owner lock --
  a client may configure the unit.
- **Persistence is a per-write flag** in the begin frame: 0 = live RAM
  only, 1 = written through to flash (survives reboot).
- **A write to an unknown fid mints it** (first write fixes its ENC; with
  persist set it reloads at boot) -- the database is a dynamic registry.

### 5. Delete a source -- CMD_DEL_ITEM(0x108)
A transaction; no reply (silence = acceptance), like the write:
```
->  CMD_DEL_ITEM(0x108)      seq, key                 DeleteItem        begin (conn state 3)
->  INFO_START(0x200)        seq, uuid, success2      StartTransaction  opens the request transaction
->  INFO_RECORD(0x201)       seq, biglen, record      SendData          the source descriptor (which source to delete)
->  INFO_END(0x202)          seq, uuid                EndTransaction    commits the delete
```
INFO_END removes the named source from the fid's per-source tree (by
transport key) and fires a delete-notify. The deleter gets no reply
(statically confirmed); other subscribers receive a PUSH_VALUE delete-
announce (change-kind = 3, no record). The request-side key + descriptor
bytes are not yet wire-captured.

### 6. Metadata probes -- CMD_DEF(0x101) / CMD_EXISTS(0x103)
Single-message requests for an item's definition / existence:
```
->  CMD_DEF(0x101)           seq, fid                 field-definition probe
->  CMD_EXISTS(0x103)        seq, fid                 existence / feeding probe
```
Neither answers a bare request on TCP 2050 (live: no reply within the
listen window). Both are non-gating and not required to interoperate (an
existence answer is in any case the `db_bits` found flag in REPLY_VALUE).

### 7. Keepalive -- EVENT_PING(0x500)
```
    EVENT_PING(0x500)        (no body)                Ping
```
An accepted no-op keepalive: the serviceLoop reads it and continues. It
is NOT a close -- a connection ends on TCP disconnect, never via a wire
verb.

### 8. Subscribe -- CMD_SUB_VALUE(0x102) / CMD_SUB_DIR(0x100)
```
->  CMD_SUB_VALUE(0x102)     fid                      RegisterForPreferredUpdates   subscribe the preferred-source value
->  CMD_SUB_DIR(0x100)       fid                      RegisterForUpdates            subscribe all sources (the directory)
```
A subscription turns on two delivery paths for that fid: the change-event
push on this TCP connection (below), and inclusion in the DBNAV multicast.
**Only inst-fids can be subscribed** -- the firmware's categorizeFid
rejects any app-fid (it keys on the fid's top byte). Five nav fids are
preloaded at boot. **To unsubscribe, close the TCP connection** -- there
is no inbound deregister verb; on disconnect the server reaps the
connection and drops its listeners.

### 9. Subscription change-event push (server -> client)
After a subscribe, the E80 pushes this burst on the same TCP connection
whenever the item changes:
```
<-  PUSH_VALUE(0x001)        zero, fid, db_bits, word    (announce)               db_bits = change-kind
<-  PUSH_START(0x203)        zero, uuid, success2        UpdateStartTransaction   opens the push transaction
<-  PUSH_RECORD(0x204)       zero, biglen, fid, record   UpdateSendData           the changed item (record -> DB_DECODE)
<-  PUSH_END(0x205)          zero, uuid                  UpdateEndTransaction     closes
```
A directory subscription announces with PUSH_DIR(0x000) instead of
PUSH_VALUE. A delete emits the announce only. The push reuses the same
record serializer as the solicited read, through a separate
per-connection sink, with `seq` hardcoded to `zero`.

## DBNAV multicast broadcast (UDP 2562)

A second service-port carries the periodic broadcast of subscribed
instrument fids. This is what the DBNAV listener receives in full,
independent of which fids any one client subscribes: any subscribed
instrument fid appears here, and five nav fids are always present from
boot.

Two message kinds, by `cmd_word`:

| cmd_word | name | message | carries |
|----------|------|---------|---------|
| 0x300 | BCAST_VALUES | Report | a list of value-records -- the preferred source of each subscribed fid |
| 0x301 | BCAST_DIRECTORY | UuidReport | a list of value-records -- every source of each subscribed fid |

A broadcast packet is a **list of records**. It opens with a header, then
`num_fields` records back to back:

```
header:   cmd_word(2) = 0x0300 or 0x0301   sid(2) = 0x0010   num_fields(4)
body:     num_fields  x  record            (broadcast form -- see DB_DECODE)
```

- Each entry is one value-record in its **broadcast serialization** -- the
  same record the TCP transactions carry; bytes in
  [DB_DECODE](DB_DECODE.md). The two packet kinds differ only in which
  sources they include: 0x300 the preferred source of each subscribed fid,
  0x301 every source.
- Unlike a TCP transaction, the broadcast has no per-record `biglen`
  prefix; the records are self-delimiting (each carries its own value
  length and descriptor length).
- The broadcast record carries one broadcast-only field, the **TTL** -- a
  countdown timer that drives the consumer's cull timer (a fid is emitted
  only while it currently has a valid value). Its byte position is part of
  the broadcast-form record layout in [DB_DECODE](DB_DECODE.md); its role
  is the cull timer.
- Maximum packet 1000 bytes; a new packet starts on overflow.

The packet header and the 0x300 value broadcast are confirmed against the
production decoder `Pub::Ray d_DBNAV.pm`. The 0x301 directory broadcast is
the firmware counterpart for directory subscriptions.

Always-on at boot (no client subscribe needed): HEADING (0x17) at 10 Hz;
SPEED (0x03), SOG (0x04), COG (0x1a), LATLON (0x44) at 1 Hz -- the
"broadcasts begin once the unit has a fix and heading" behavior.

## Implementation details

These describe the firmware machinery behind the broadcast and the
FID-creation behavior; they are specific to DATABASE rather than protocol
the wire exposes.

Behind the two channels is a single firmware object, the report
generator, that owns both transports -- the TCP control socket and the
multicast broadcaster. It keeps three subscription lists (RB-trees,
conceptually hashes keyed by FID):

- the **field list** -- FIDs whose values broadcast at 1 Hz;
- the **UUID list** -- FIDs whose all-source (directory) records broadcast at 1 Hz;
- the **heading list** -- the heading-family FIDs, broadcast at 10 Hz.

A thread wakes every 100 ms and walks the heading list, emitting current
values; every tenth wake it also walks the other two lists. That is the
entire broadcaster -- the 10 Hz / 1 Hz tiering is just the heading list
serviced on every wake and the others on every tenth.

A FID enters a list one of two ways: the firmware preloads the five
always-on nav FIDs at boot, and a CMD_SUB_VALUE / CMD_SUB_DIR from a TCP
client adds a FID to the field/heading or UUID list. A client that wants
the broadcast to "go rich" subscribes each FID it cares about.

---

**Next:** [DB_FIDS](DB_FIDS.md) ...
