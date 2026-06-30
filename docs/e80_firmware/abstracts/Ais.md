# AIS

Return to [**Abstracts**](readme.md)

The AIS network service: how the E80 republishes its AIS target database onto
SeaTalkHS, and how a networked client mirrors that database and can drive display
settings, alarms, and a transceiver-status query. RAYDP **SID 30 (0x1e)**,
firmware name `AIS`, shown on the E80's own diagnostics screen as "AIS". Both
consumed and served by the E80; not yet implemented in `/raymarine/NET`.

## What it is

An AIS receiver or transceiver reports nearby vessels (targets) to the E80 over
NMEA 0183 (the firmware also carries a simulator source). The E80 parses those
sentences into a **target database** -- a tree of target records keyed by MMSI --
plus the own-ship transceiver status, alarms, and safety-related text messages
(SRMs), and **republishes the whole database on SeaTalkHS** as the AIS service.
This is the richest of the instrument services: where GPS publishes one record,
AIS publishes a live, mutating *set* of records.

A networked client mirrors the database by applying a stream of report
mutations -- targets added/changed/removed, alarms raised/cleared, safety
messages received, transceiver state changed -- and can act on it: seed its
mirror with the three `GetAll*` requests, acknowledge an alarm, or change
per-target display settings. The `GetAllSRMs` request gets a genuine **unicast
reply**, unlike the other instrument services. The service is named from the
firmware's `CAIS_*` message classes.

## Transport and framing

AIS is a UDP service on the on-demand instrument tail (it constructs only when
AIS data appears, claiming the next free unicast port from 2056 and multicast
group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)). The
advertisement carries both the server's **unicast** ip:port and its **multicast**
ip:port.

Two client roles, with one wrinkle the other instrument services lack:

- **Subscribers** join the multicast group and *receive* the report mutations.
  Joining is the subscription; the server **pushes** a mutation to the group as
  each database change happens.
- **Commanders** send command datagrams to the unicast port. Most commands get
  **no unicast reply** -- their effect appears as the report mutations broadcast
  to the group (`GetAllTargets` and `GetAllAlarms` replay their stores as a burst
  of group reports). The **`GetAllSRMs` command is the exception**: rather than
  replaying to the group, the server sends each safety message straight back to
  the requester as a `NewSRM` (`0x001e0004`) datagram **unicast to the
  requester's address** -- so a client can pull the SRMs directly, without
  joining the group.

Every message is a bare little-endian datagram leading with a 4-byte **command
word** and no length prefix:

```
cmd_word = (sid << 16) | dir | sel
           sid = 0x001e (AIS)
           dir = 0x100  command  (client -> server's unicast port)
                 0x000  report   (server -> its multicast group; also the unicast
                                  status reply)
           sel = low byte selects the message
```

## Message set

The firmware defines thirteen `CAIS_*` wire classes -- seven reports and six
commands:

| cmd_word     | direction         | class (`CAIS_*`)                 | behaviour                                          |
| ------------ | ----------------- | -------------------------------- | -------------------------------------------------- |
| `0x001e0000` | server -> mcast   | `TargetChanged`                  | target add/update -- 228-byte record, key MMSI     |
| `0x001e0001` | server -> mcast   | `TargetDeleted`                  | target remove -- by id                             |
| `0x001e0002` | server -> mcast   | `AlarmChanged`                   | alarm add/update -- 124-byte record, key short id  |
| `0x001e0003` | server -> mcast   | `AlarmDeleted`                   | alarm remove -- by short id                        |
| `0x001e0004` | server -> mcast / unicast | `NewSRM`                  | a safety-related message -- 180-byte record        |
| `0x001e0005` | server -> mcast   | `TxcrStateChange`                | own-ship transceiver state -- a single u32         |
| `0x001e0006` | server -> mcast   | `AllTargetsDeleted`              | all targets cleared -- re-notify every target      |
| `0x001e0100` | client -> unicast | `GetAllTargets`                  | replay all targets -- no argument                  |
| `0x001e0101` | client -> unicast | `GetAllAlarms`                   | replay all alarms -- no argument                   |
| `0x001e0102` | client -> unicast | `GetAllSRMs`                     | replay all SRMs (unicast `NewSRM` reply) -- no arg |
| `0x001e0103` | client -> unicast | `SetTargetDisplayDataSetting`    | per-target display setting -- u32 id + byte        |
| `0x001e0104` | client -> unicast | `SetTargetDisplayVectorSetting`  | per-target display setting -- u32 id + byte        |
| `0x001e0105` | client -> unicast | `AckExternalAlarm`               | acknowledge an alarm -- u32 id                     |

Every binding is read from the firmware and **verified, not inferred**: the
command words, directions, record sizes, and dispatch behaviour from the server's
receive side; the class names from the consume-source's apply handlers (each
report handler names the class it decodes) and from its connect-time seed senders
(which pair `GetAllTargets`/`GetAllAlarms`/`GetAllSRMs` with `0x001e0100/01/02`).
Three observations fall out of the real names:

- The "secondary" 124-byte store is the **alarm list** (`AlarmChanged` /
  `AlarmDeleted`), not a second class of target.
- The 180-byte record is a **safety-related message** (`NewSRM`), and the single
  u32 is the **transceiver state** (`TxcrStateChange`) -- not a generic status
  block.
- On connect, a client seeds its mirror by sending the three `GetAll*` requests
  in order (targets, alarms, SRMs); the two `SetTargetDisplay*` setters are the
  per-target display toggles.

## Target, alarm, and message stores

The consume side maintains two balanced-tree stores plus two unit-level records,
all populated from the report stream:

- **Targets** (`TargetChanged` / `TargetDeleted`): a **228-byte** record keyed by
  a **u32 MMSI** at offset 0. A class field at offset 4 (values 1 / 2 / 3)
  classifies the target and drives the active-target count the source keeps;
  add/update inserts-or-replaces by MMSI, remove deletes by id. The per-field
  record layout beyond {MMSI, class} is produced by a dedicated deserializer and
  is not yet broken out (see *Open edges*).
- **Alarms** (`AlarmChanged` / `AlarmDeleted`): a smaller **124-byte** record
  keyed by a **16-bit id**, in a separate tree -- the AIS alarm list (the
  "secondary" store, identified by name, is the alarm list, not a second class of
  target).
- **Safety-related messages** (`NewSRM`): a **180-byte** record carrying a
  received AIS text message; also the payload the server unicasts in reply to a
  `GetAllSRMs` request.
- **Transceiver state** (`TxcrStateChange`): a single **u32** holding the
  own-ship transceiver status (off / receive-only / transmitting, etc.).

`AllTargetsDeleted` (`0x001e0006`) clears the picture -- the handler walks the
target tree re-notifying change-sinks so every display drops its targets at once.

## Commands

The six commands split into three store replays, two per-target setters, and an
alarm acknowledge. The command word, argument shape, and provider-vtable slot are
read from the server's receive dispatch; the class name from the consume-source's
send methods. All six are **verified**:

| cmd_word     | argument      | provider slot | command class (`CAIS_*`)         | behaviour                          |
| ------------ | ------------- | ------------- | -------------------------------- | ---------------------------------- |
| `0x001e0100` | (none)        | vt[0x34]      | `GetAllTargets`                  | enumerate the target tree, rebroadcast each |
| `0x001e0101` | (none)        | vt[0x84]      | `GetAllAlarms`                   | enumerate the alarm tree, rebroadcast each |
| `0x001e0102` | (none)        | vt[0xcc]      | `GetAllSRMs`                     | **unicast** each SRM back as `NewSRM` (`0x001e0004`) |
| `0x001e0103` | u32 id + byte | vt[0x4c]      | `SetTargetDisplayDataSetting`    | per-target display setting         |
| `0x001e0104` | u32 id + byte | vt[0x5c]      | `SetTargetDisplayVectorSetting`  | per-target display setting         |
| `0x001e0105` | u32 id        | vt[0x9c]      | `AckExternalAlarm`               | acknowledge an alarm by id         |

`GetAllTargets`, `GetAllAlarms`, and `GetAllSRMs` are the three connect-time seed
requests (the consume source sends them in that order to populate its mirror).
`GetAllSRMs` is the one command that answers **unicast** to the requester --
returning each safety message as a `NewSRM` datagram -- rather than replaying to
the multicast group.

## Status and open edges

**Established (firmware):** the SID, the UDP bare-command-word framing, the
mutating-database model (a stream of report mutations over multicast, seeded by
the three `GetAll*` requests), the complete thirteen-message set (seven reports,
six commands) with the **class name of every message verified**, the target store
(228-byte, keyed by MMSI) and the alarm store (124-byte, keyed by a short id) and
their add/update/remove semantics, the target class field and the active-count it
drives, the 180-byte `NewSRM` record and the u32 `TxcrStateChange`, the
`AllTargetsDeleted` clear-all report, and every command's argument shape and
provider-vtable slot -- including `GetAllSRMs`'s **unicast reply**, which no other
instrument service has.

**Not yet pinned:**

- The per-field layout of the 228-byte target record (position, COG/SOG, name,
  dimensions, nav status) -- produced by a deserializer whose field breakdown is
  not yet decoded.
- The internal layout of the 124-byte alarm record and the 180-byte `NewSRM`
  record, and the value enumeration of the `TxcrStateChange` u32.

Both are best resolved by a live capture with an AIS source (or the firmware's
own simulator) present -- correlating a known target's MMSI, position, and motion
to the record bytes, and watching which report words follow each database change.

## Why it matters

The AIS service is the network face of the boat's collision-awareness picture:
the full target database, alarm list, and safety messages, mirrored over
multicast by a compact set of mutation reports, with three `GetAll*` requests to
seed a client and a direct unicast SRM pull. For
interoperability it is the most capable of the instrument services -- a real
shared database rather than a single record -- and a substantial `/raymarine/NET`
decoder (`d_AIS`) target, closer in shape to the waypoint and track stores.
Read-side decoding (subscribe, track adds / updates / removes, mirror the
target tree) is harmless monitoring; the display-setting and alarm-acknowledge
commands act on the unit and are out of scope for passive use.

---

Return to [**Abstracts**](readme.md)
