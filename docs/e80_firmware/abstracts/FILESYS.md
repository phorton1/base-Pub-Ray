# FILESYS

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**FILESYS** --
**[DATABASE](DATABASE.md)** --
**[DB_FIDS](DB_FIDS.md)** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The CF-card filesystem access service (`CFAccessController`, service id 5). A
UDP request/reply protocol for reading the E80's CF card over Ethernet -- most
importantly `\Archive\ARCHIVE.FSH`, the navigation archive. This document gives
the command set, the full request/reply byte structures ("transaction blocks"),
the multicast card-status channel, and the ancillary card behaviors (the
session file-handle lockout, the "Remove CF Card" remount, and ARCHIVE.FSH
writing) that sit outside the wire protocol but dominate how the service is used
in practice.

**Provenance.** The command set, byte layouts, and read-only conclusion are
**firmware-confirmed** (the dispatcher and every handler were read directly).
The wire examples are real **captures** from RNS and the `shark` client. Points
that remain observation or inference are marked where they occur.

## Service and ports

FILESYS is advertised by RAYDP (service id 5) and presents two endpoints:

- **UDP 2049** -- the command port (the "FILESYS port"). Clients send requests
  here and the service replies to a listener port carried in each request.
- **mcast :2561** -- a multicast group on which the service broadcasts CF-card
  status, unsolicited. The group IP is derived from the unit's own address by
  the standard RAYDP multicast formula (see [RAYDP](RAYDP.md)); the port is
  fixed at 2561. Its purpose -- undocumented in prior work -- is the
  card-status channel described under *Multicast card-status* below.

**Reply-port-in-request.** FILESYS does not reply to the UDP source port. The
client binds its own UDP listener on a chosen port, puts that port number in
every request, and the service sends the reply there. Observed listener ports:

| Port  | Client                |
| ----- | --------------------- |
| 18432 | RNS                   |
| 18433 | shark                 |

These are not advertised; 18432 is what RNS uses, 18433 is the `shark` choice.

## Command words

Every FILESYS message begins with a 4-byte command word, little-endian on the
wire as four bytes:

```
  opcode   direction   service-id(2)
   XX         DD          05 00
```

- **opcode** -- the command (0x00..0x09).
- **direction** -- `0x01` request, `0x00` reply, `0x02` unsolicited
  INFO/broadcast (used only on the multicast channel).
- **service-id** -- `0x0005` for FILESYS.

So a CMD_GET_SIZE request is `01 01 05 00` (`0x00050101`) and its reply is
`01 00 05 00` (`0x00050001`).

The complete command set -- this **is** the whole protocol surface; the
dispatcher has exactly these cases, there is **no opcode 3**, and there are **no
write opcodes** (firmware-confirmed):

| opcode | name            | request | reply   | meaning                                   |
| :----: | --------------- | ------- | ------- | ----------------------------------------- |
| 0x00   | CMD_DIR         | 0x00050100 | 0x00050000 | directory listing                      |
| 0x01   | CMD_GET_SIZE    | 0x00050101 | 0x00050001 | file size (opens a session -- see below) |
| 0x02   | CMD_GET_FILE    | 0x00050102 | 0x00050002 | file contents (multi-packet; opens a session) |
| 0x03   | *(CMD_UNKNOWN3)* | --        | --        | **no dispatcher case** -- never answers   |
| 0x04   | CMD_GET_ATTR    | 0x00050104 | 0x00050004 | size + FAT attribute byte                 |
| 0x05   | CMD_FILE_EXISTS | 0x00050105 | 0x00050005 | existence test                            |
| 0x06   | CMD_GET_SIZE2   | 0x00050106 | 0x00050006 | file size (stateless -- no session)       |
| 0x07   | CMD_LOCK        | 0x00050107 | 0x00050007 | card-removal lock (advisory counter)      |
| 0x08   | CMD_UNLOCK      | 0x00050108 | 0x00050008 | card-removal unlock                       |
| 0x09   | CMD_CARD_ID     | 0x00050109 | 0x00050009 | CF-card identification string             |

The command names are the long-standing `d_FILESYS.pm` names; the firmware is
stripped, so the names are this project's, now bound to the firmware dispatch
cases above. **CMD_UNKNOWN3 is a missing switch case, not a hidden feature** --
the long search for a write command ends here: the dispatcher's default path
silently discards anything it does not recognize.

### Result codes

Reply messages carry a 4-byte **result** at offset 8, immediately after the
echoed sequence number:

- **`0x00040000`** (wire `00 00 04 00`) -- **success**. This is the "success
  signature": a reply that matches the first 8 bytes but does not carry it is an
  error.
- **`0x80040501`** (wire `01 05 04 80`) -- **failure** (e.g. GET_SIZE on a
  directory, GET_ATTR on the root). A failed reply may carry trailing buffer
  bytes after the code; treat anything that is not the success signature as a
  terminated, failed operation.

## Transaction blocks

### Common request header

All requests share a 10-byte head, then command-specific fields, then (for
path-bearing commands) a length-prefixed, null-terminated ASCII path:

```
  [0]  command word (4)
  [4]  sequence number (4)   -- arbitrary; echoed in the reply
  [8]  listener port (2)     -- where the reply is sent
  ...  command-specific fields
  ...  path length (2)       -- bytes in the path including the null
  ...  path (ASCII + NUL)
```

The path length **includes** the trailing null. The position of the
length/path differs by command, because two commands insert extra fields:

| command         | extra fields before length | length @ | path @ |
| --------------- | -------------------------- | :------: | :----: |
| DIR, GET_ATTR, FILE_EXISTS, GET_SIZE2 | (none)       | 0x0a   | 0x0c  |
| GET_SIZE        | one word(0) at 0x0a        | 0x0c   | 0x0e  |
| GET_FILE        | start_offset(4)@0x0a, max_bytes(4)@0x0e | 0x12 | 0x14 |

The GET_SIZE `word(0)` at 0x0a has no known semantic; it is simply required, and
its absence is the *only* difference between CMD_GET_SIZE and CMD_GET_SIZE2.

### Common reply header

```
  [0]  reply command word (4)   -- request word with direction = 0x00
  [4]  sequence number (4)       -- echoed from the request
  [8]  result (4)                -- 0x00040000 success / 0x80040501 failure
  ...  command-specific payload
```

### CMD_DIR (0x00) -- directory listing

Request: common header + path. Example for `\junk_data`:

```
request:  00 01 05 00  03 00 00 00  00 48  0b 00  5c 6a 75 6e 6b 5f 64 61 74 61 00
          ^cmd_word    ^seq         ^port  ^len   ^"\junk_data\0"  (len 0x0b = 11)
```

The reply is the common header followed by a short count block and then a
stream of directory entries:

```
reply:    00 00 05 00  03 00 00 00  00 00 04 00  pp pp  ii ii  ee ee   <entries...>
          ^cmd_word    ^seq         ^result      ^pkt   ^idx   ^count
```

- `pkt` -- packet count (1 for a listing that fits one datagram).
- `ii` -- packet index word.
- `ee` -- number of entries in this packet. *(The entry-count word is recovered
  from capture; the firmware decompile of this handler drops the write, but the
  value matches the entry count on the wire.)*

Each entry is `word(name_length) | name bytes | byte(FAT attribute)`. The FAT
attribute byte uses the standard bits:

```
  0x01 READ_ONLY   0x02 HIDDEN   0x04 SYSTEM
  0x08 VOLUME_ID   0x10 DIRECTORY   0x20 FILE
```

For a large directory the listing chunks across multiple datagrams (the handler
flushes a packet and continues), each a full reply with the same header.

### CMD_GET_SIZE (0x01) and CMD_GET_SIZE2 (0x06) -- file size

Both return a `u32` file size and fail on directories. They differ in two ways:

- **Wire:** GET_SIZE carries the extra `word(0)` at 0x0a (length at 0x0c, path
  at 0x0e); GET_SIZE2 omits it (length at 0x0a, path at 0x0c).
- **State (important):** **GET_SIZE opens a per-client session** -- it goes
  through the same file-open path as GET_FILE and so incurs the same ARCHIVE.FSH
  lockout (see *Sessions* below). **GET_SIZE2 is stateless** -- it queries the
  size without opening the file, and incurs no lockout. GET_SIZE2 is therefore
  the size command to prefer; the `shark` client already uses it internally to
  size a file before a GET_FILE.

```
request:  01 01 05 00  04 00 00 00  00 48  00 00  1a 00  5c 6a ... 00
          ^GET_SIZE     ^seq         ^port  ^w(0)  ^len   ^path
reply:    01 00 05 00  04 00 00 00  00 00 04 00  2c 01 00 00
          ^cmd_word    ^seq         ^result      ^size = 0x12c = 300
```

GET_SIZE2 is identical but for the missing `word(0)` and the `0x06`/reply
`0x06` opcode, and creates no session.

### CMD_GET_FILE (0x02) -- file contents

The only multi-packet command. The request adds a 32-bit start offset and a
32-bit maximum byte count before the path:

```
request:  02 01 05 00  01 00 00 00  00 48  <off u32>  <max u32>  <len u16>  <path>
                                            @0x0a       @0x0e      @0x12      @0x14
```

`max` is a client-chosen ceiling, not a protocol constant -- RNS uses
`0x019d9a00`, `shark` uses `0x01ffffff` (32 MB). The reply is a sequence of
packets, each with an 18-byte header then up to 1024 content bytes:

```
each packet:  02 00 05 00  01 00 00 00  00 00 04 00  nn nn  pp pp  bb bb   <content...>
              ^cmd_word    ^seq         ^result      ^npkts ^pkt#  ^bytes
```

- `nn` -- total number of packets.
- `pp` -- this packet's index (0-based).
- `bb` -- content bytes in this packet: `0x0400` (1024) for every packet except
  the last, which carries the remainder. Non-final packets also set a "more"
  marker in the bytes-count high field.

The client reassembles by packet index; the last packet's smaller byte count
gives the exact file length.

### CMD_GET_ATTR (0x04) -- size + attribute

Returns the `u32` size and the FAT attribute byte for one path; fails on the
root directory. Uses no extra `word(0)`.

```
reply:    04 00 05 00  <seq>  00 00 04 00  <size u32>  <attr byte>
          ^cmd_word           ^result      @0x0c        @0x10        (17 bytes)
```

### CMD_FILE_EXISTS (0x05) -- existence test

Returns the success signature if the path exists, the failure code otherwise;
no payload beyond the result. (Duplicate requests -- same client and sequence
number -- replay the prior reply, the same de-dup mechanism LOCK/UNLOCK use.)

```
reply:    05 00 05 00  <seq>  00 00 04 00         (12 bytes; result only)
```

### CMD_CARD_ID (0x09) -- card identification

Returns a card-specific identification string. This is the unicast "pull" form
of the same card body the multicast channel pushes.

```
request:  09 01 05 00  12 30 00 00  00 48
reply:    09 00 05 00  12 30 00 00  88 13 00 00  01 00  14 00
          20 20 20 20  30 30 31 34 39 31 30 46 30 36 44 36 32 30 36 32  0f 27 0c
```

- `@0x08` -- a 32-bit arming/next-valid timer (`0x1388` = 5000 ms); the service
  caches the card body for ~5 s between queries.
- `@0x0c` -- card-present flag (1).
- `@0x0e` -- id length (`0x14` = 20).
- `@0x10` -- the 20-byte id: four leading spaces then a 16-character ASCII
  string. Observed: `"0014910F06D62062"` (a RAY_DATA card),
  `"0014802A08W79223"` (a Caribbean Navionics card).
- trailing `0f 27 0c` -- a fixed 3-byte protocol/version trailer (the constant
  `9999, 0x0c`), present on every card reply; **not card data**.

CARD_ID never fails on a well-formed request; card absence is reported via the
present flag, not the failure path. (39 bytes total.)

### CMD_LOCK (0x07) / CMD_UNLOCK (0x08) -- card-removal lock

These are **not** a file write-lock and do not gate the E80's own writes. They
are an **advisory counter that coordinates safe removal of the CF card** -- the
network-client half of the "Remove CF Card" handshake (see *Ancillary findings*).

- **CMD_LOCK** increments a per-card "in use" counter, recorded per client
  (IP + listener port). It succeeds only while the card is mounted and no removal
  is pending; if a removal has been requested, LOCK is refused. Reply
  `0x00050007`, result `0x00040000` on success.
- **CMD_UNLOCK** decrements the counter. Reply `0x00050008`. Its one
  consequence: if this UNLOCK takes the counter to zero **while a removal is
  pending**, it is this UNLOCK that completes the unmount and the
  "card removed" multicast.

Both are request/reply with only a result (12 bytes), and both replay the prior
reply on a duplicate (same client + sequence). A bare LOCK/UNLOCK pair with no
removal pending simply moves the counter and has no other effect.

## Multicast card-status

On the multicast group (`:2561`) the service sends **unsolicited** messages --
direction byte `0x02` (INFO) -- announcing CF-card state. This is the previously
undocumented purpose of the FILESYS multicast port.

- **Card status -- `0x00050200`** (31 bytes). Sent when the card-presence state
  changes, rate-limited to about once per 5 s. Layout:

  ```
  00 02 05 00  ss ss  mm mm  <20-byte card id>  0f 27 0c
  ^cmd_word    ^state ^meta  ^id (zero if absent) ^trailer
  ```

  `state` = 0 means card present (followed by the same 20-byte id as CARD_ID);
  non-zero means the card has been removed/withdrawn (id zeroed). The `meta`
  word and `0f 27 0c` trailer are as in CARD_ID.

- **Service teardown -- `0x00050201`** (4 bytes, command word only). Sent when
  the service deregisters / the card is being released.

A client that joins the group sees these without polling -- it is told when a
card is inserted, identified, or removed. A removal broadcast is also the
network's signal that any open sessions on that card have just been dropped.

## Ancillary findings (out-of-protocol behavior)

These are device behaviors that are **not** part of the wire command set but
govern how FILESYS behaves in practice -- and explain the long-standing
ARCHIVE.FSH friction.

### Sessions and the file-handle lockout

`CMD_GET_FILE` and `CMD_GET_SIZE` (not GET_SIZE2) **open the target file and
hold the handle** in a per-client session, keyed by the client's IP. There is
**no close command** in the protocol -- the session, and the open handle, persist
until the session is torn down by some other event. The other read commands
(DIR, GET_ATTR, FILE_EXISTS, GET_SIZE2) are stateless and leave nothing open.

The practical consequence: once a client does `GET_FILE \Archive\ARCHIVE.FSH`,
the E80 holds that file open, and **the chartplotter can no longer save to
ARCHIVE.FSH** until the handle is released. This is the "GRUMBLE (a)" behavior --
it long looked like evidence of a write capability, but it is just an
unreleased read handle.

### Releasing the lockout

The held handles are released only by a single internal teardown ("release all
sessions"), which closes every open file object and then drops the underlying
filesystem lock. It is reached from exactly three places:

- the **"Remove CF Card"** card-removal flow,
- a **reboot** (service destruction), and
- a **CMD_UNLOCK that takes the lock counter to zero while a removal is
  pending** -- never a standalone LOCK/UNLOCK.

So **there is no way to close a session from the network using the stock
protocol**. The stock releases are the on-device "Remove CF Card" toggle and a
reboot.

### "Remove CF Card": unmount, then remount

The "Remove CF Card" menu does two things, and both bear on readability:

1. It **releases all sessions** (closing the held ARCHIVE.FSH handle), via the
   card-removal flow above. If a network client holds a CMD_LOCK at the time,
   the unmount is deferred until that client's final UNLOCK -- which is the
   entire reason LOCK/UNLOCK exist.
2. On the following "OK"/re-detect it **remounts the card**, which **re-reads
   the FAT** into a fresh directory cache.

### ARCHIVE.FSH writing and the stale view

FILESYS serves files from the card driver's cached directory/FAT. The E80
writes ARCHIVE.FSH through its own internal archive export (a `CCFArchive`
path), which does not refresh that cache -- so a freshly-written ARCHIVE.FSH
stays invisible to FILESYS until the volume is remounted. This is "GRUMBLE (b)":
saved WGRT changes only become visible (and only commit to the physical card)
after the "Remove CF Card" cycle, whose remount re-reads the FAT. *(The exact
reason the internal write bypasses the FILESYS cache -- a separate driver
handle vs. a shared mount -- is the one piece here still to be pinned.)*

### Read-only -- by design, not by omission

There is no write path to activate. The dispatcher's nine commands are the
complete surface, none writes, and the default case discards unknown commands.
The chartplotter does write its own card (it must, to persist navigation data),
but those writes go through internal `CCFArchive` code that FILESYS does not
expose. Writing **to** the E80 over Ethernet happens through the per-domain
RAYNET services ([WPMGR](WPMGR.md) waypoint/route/group writes, the
[TRACK](TRACK.md) writer-mode upload), which route into that same internal
archive path. FILESYS is read-only at the wire level.

### Malformed packets crash the device

A request with a bad string length will crash the E80 (and can crash RNS).
Construct path-length fields carefully.

## Implementation state (/raymarine)

`d_FILESYS.pm` implements the client side as a stateful parser (a single
`fileCommand` drives a START -> BUSY -> COMPLETE/ERROR machine; GET_FILE sizes
with GET_SIZE2 first, then loops GET_FILE in `BYTES_PER_REQUEST` chunks). DIR,
GET_SIZE/GET_SIZE2, GET_FILE, GET_ATTR, FILE_EXISTS, and CARD_ID are exercised;
LOCK/UNLOCK and the multicast channel are characterized here but are not part of
the routine read flow. The firmware-side service is the standard CLNet pattern;
see [architecture/services](../architecture/services.md).

---

**Next:** [DATABASE](DATABASE.md) ...
