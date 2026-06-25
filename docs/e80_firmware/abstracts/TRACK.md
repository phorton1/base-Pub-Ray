# TRACK

**[Abstracts](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**TRACK** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**[DB_FIDS](DB_FIDS.md)** --
**[DB_DECODE](DB_DECODE.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

Track service, including the writer-mode discovery that enabled
the first programmatic track upload to an E80 over Ethernet.

TRACK is the E80's track service over Ethernet (TCP port 2053,
sid 19). It is one of the two RAYNET services -- along with
WPMGR -- that are core to the WGRT maintenance goal: a track is
the T in WGRT. TRACK has been read-only
for years, with the long-open question "can a track be written to
the E80 via Ethernet?" hanging as a structural gap in the /NET
machinery. That question is now answered: **yes**, via a
writer-mode protocol decoded from the firmware and verified
end-to-end against a real E80 on 2026-05-27.

## Architecture

TRACK uses the **same Server + Connection + serviceLoop pattern as
WPMGR**, just at one-third the scale. One context (vs WPMGR's
W/R/G triple), 18 SEND command cases + 3 RECV cases, 9.2 KB
serviceLoop, 388-byte Connection object. Firmware-side details
are in [architecture/services](../architecture/services.md).

## The 18 SEND commands

The 18 SEND cases (`0x130100`..`0x130111`) correspond exactly 1:1
with the `$TRACK_CMD_*` constants in `/raymarine/NET/d_TRACK.pm`
(GET_NTH=0x00 through NO_REPLY_11=0x11). Empirical
exploration discovered all 18; the `%TRACK_PARSE_RULES` has
DIRECTION_SEND rules for 15 of them. The three intentionally-omitted
"useless" ones -- USELESS_E=0x0e, NOREPLY_F=0x0f, NO_REPLY_11=0x11
-- are real handlers in the firmware. Investigation of NO_REPLY_11
led to the writer-mode discovery below.

The dispatch structure is **clean and flat** (in contrast to
WPMGR's nested W-context dispatch):

```
if cmd_word >= 0x130200:
  // RECV-direction commands (the writer-mode INFO frames)
  case 0x130200: CMD_HEADER     (20-byte payload)
  case 0x130201: CMD_INFO_CHUNK (variable payload)
  case 0x130202: CMD_END        (16-byte payload, two-phase)
else:
  // SEND-direction switch
  switch (cmd_word): 18 cases 0x130100..0x130111
```

## The writer-mode discovery

**TRACK supports a second connection role -- "writer" -- on the
same TCP socket.** The transition is gated by the
previously-unused NO_REPLY_11 command (`0x130111`). While in
writer mode, batched track-point data sent by the client is
ingested into a CTrack object on the Connection; when the batch
is complete the firmware auto-saves the track to storage.

This resolves the long-standing open question in
`/raymarine/NET`: how to write a track to the E80 over Ethernet.

The protocol writes via the **same TCP socket** the reader role
uses, **the same service port** (2053) advertised by RAYDP, and
**the same wire formats** for MTA, TRACK_HEADER, and TRACK_PT
that `b_records.pm` already specifies. The new
ingredient is the writer-mode session-state machine on the
firmware side, and the four-command writer flow on the client
side: `RECORD` (the NO_REPLY_11 trigger), `CMD_HEADER`, `CMD_INFO`
(carrying chunked MTA then chunked point batches), and `CMD_END`
(two-phase: drain the MTA into a new CTrack, then later append
the point batch and auto-save when the buffer fills).

The full writer-mode wire-level protocol, sanitized for cleanroom
handoff, is in [TRACK_writing](TRACK_writing.md).
That spec is what was implemented in navMate's `d_TRACK_writer.pm`,
verified end-to-end on 2026-05-27.

## The CTrack lifecycle

When NO_REPLY_11 fires with no existing CTrack on the Connection,
the firmware allocates a fresh 160-byte CTrack object on the
Connection (`conn[+0x178]`) and switches the Connection into
writer mode. CTrack is the firmware's in-memory representation of
a track, identified via RTTI; it has embedded `CTrackPoint` and
`CTrackDetails` sub-objects (multiple inheritance).

The two-phase `CMD_END` state machine drives ingestion:

- **First CMD_END (writer_active == 0):** drain the accumulator,
  read the 57-byte MTA, copy its fields into the CTrack metadata
  (capacity, length, name, color, anchor points), set
  writer_active = 1.
- **Subsequent CMD_END calls (writer_active == 1):** read a
  point batch from the accumulator, append into the CTrack's
  point buffer. When the point count reaches the capacity declared
  in the MTA, fire the auto-save: the CTrack persists to storage,
  a SAVED reply goes back to the client, and the CTrack is
  destroyed.

The save fires automatically when the buffer fills; there is no
separate "commit" command. To abort an in-progress track, send
NO_REPLY_11 a second time: it destroys the in-progress CTrack and
closes the TCP session.

## On-device recording (where saved tracks come from)

The TRACK service above is the network face. The saved tracks it
serves are produced by a separate on-device subsystem in the
firmware's `BaseBrick/Local/Track` module: a singleton **TrackRecorder**
(`TrackRecorder_ctor` @ 0x2ec33c), a **TrackRecorderController**
(@ 0x2e8670) holding the user settings, and **TrackStorage**
(`TrackStorage_ctor` @ 0x2f065c) backing the saved-track database.

A unit with **mod003** installed additionally stamps each recorded point with a
wall-clock time and true depth -- a *timed track*. That changes only the per-point
payload (and is detected by value, not by any flag); the recorder mechanics below are
unchanged. See [deployment/mod003](../deployment/mod003.md).

### Recording modes

The controller reads a MODE setting (data item 0x5000087) and builds
one of three interval calculators
(`TrackRecorderController_selectMode` @ 0x2e8f28), each driven by the
live position (data item 0x93):

- **Auto** (mode 0, the factory default) -- `CAutoTrackCalculator`. No
  fixed interval; an adaptive line-simplification (below).
- **Time** (mode 1) -- `CTimeTrackCalculator`. A point every
  `timeTable[idx] * 1000` ms.
- **Distance** (mode 2) -- `CDistanceTrackCalculator`. A point once the
  boat has moved a set distance from the last kept point.

### Auto thinning

Auto is a streaming corridor (band) polyline generalizer
(`trackAutoSimplify_feedPoint` @ 0x5e2978, fed per fix by
`CAutoTrackCalculator_evaluateFix` @ 0x2f81c0). It anchors a segment,
then for each fix computes range and bearing from the anchor
(`geo_bearingAndRange` @ 0x5a82bc) and keeps extending the current
straight run while the bearing stays inside a tolerance band and the
perpendicular deviation stays under a scaled limit. When a fix breaks
out of the corridor -- a turn, or a sideways excursion -- the last
in-corridor vertex is emitted as a kept point and a new run begins. A
point is also force-kept every 300000 ms (5 minutes). So Auto keeps
points on turns and accumulated distance and discards them on straight
runs; time is only a 5-minute floor. The deviation tolerance is a
configuration scalar (raw value 2000; real-world units not yet
converted) held in a fixed 112-byte simplifier state object -- there is
no point buffer of that size.

### The current track is a 1000-point ring

The recorder owns exactly one active "current" track: a `CTrack`
created once (`CTrack_ctor` @ 0x2ce388, capacity 1000, point buffer
1000 * 14 bytes, its own minted 64-bit GUID). Kept vertices are added
by `CTrack_appendPointRing` @ 0x2cea08, which indexes the buffer as
`writeCursor mod capacity`. Below 1000 points it grows; once full it is
a FIFO ring -- each new point overwrites the oldest, the count pins at
1000, and the cumulative length is rebookkept. A long recording
therefore does not stop, spill into new tracks, or thin by importance:
the oldest points (and whole early segments) slide off the front. This
is the manual's "10 tracks with up to 1000 points each" figure.

### Segment breaks (the 0,0 markers)

When recording stops -- a deliberate stop, loss of the position source,
or a power-down -- `TrackRecorder_stopAndFlush` (@ 0x2e8c3c) calls
`CTrack_appendSegmentBreak` (@ 0x2cf734), which writes a sentinel point
with every field all-ones: north = east = 0xFFFFFFFF, temp = depth =
0xFFFF. As a signed prescaled-Mercator coordinate 0xFFFFFFFF is -1,
which inverse-Mercators to approximately lat 0 / lon 0 -- the "0,0"
markers that split a track into segments in the FSH and navMate
readers. (`trackPoint_isSegmentBreak` @ 0x2cdf20 is the firmware's own
test for the sentinel.) One sentinel per stop, so a single continuous
track can hold many segments -- e.g. dozens of separate power-on legs
recorded over months -- without those ever being separate saved tracks.

### Saved tracks vs. the current track

The saved-track database holds at most **10 tracks** (E-Series
Reference Manual). The active current track is separate -- the
conceptual 11th. Discrete saved tracks come from an explicit Save, not
from the recorder rolling over.

## Wire format

The writer side uses the same structures as the reader side.
`b_records.pm` already specifies:

- **MTA record (57 bytes)** -- `$MTA_REC_SPECS`: capacity, length,
  anchor points (start and end), color, name, plus k1_1 and u1
  bytes that flag saved/in-process state.
- **TRACK_HDR (8 bytes per batch)** -- `$TRACK_HEADER_SPECS`:
  start_index, count, and a 16-bit field that must be zero.
- **TRACK_PT (14 bytes per point)** -- `$TRACK_PT_SPECS`:
  prescaled Mercator northing/easting, temperature, depth.

The writer-side INFO frames carry a leading `'seq'` field and the
standard RAYNET `'buffer'` wire form (`u32 biglen + biglen bytes
of content`), mirroring the reader-side `%TRACK_PARSE_RULES`. The
SAVED reply parses as `pieces => ['seq', 'success']`.

## What was learned during end-to-end verification

The cleanroom spec was authored on 2026-05-26 and exercised
against a real E80 on 2026-05-27. The first two attempts crashed
the device. A second exploration round traced both failures to
two missing fields in the writer-side INFO-frame format that the
original spec didn't call out:

1. The standard `'seq'` envelope field, which the firmware
   accepts but doesn't strictly validate. The writer side mirrors
   the reader side exactly.
2. The `'buffer'` piece's leading `u32 biglen`. Without it, the
   firmware interpreted MTA bytes 4..7 (the `length` field, 10000
   meters) as the chunk length, bumped the accumulator write
   offset by 10000, and the next CMD_INFO write was wildly out
   of bounds.

The third attempt -- with both in place -- wrote a track cleanly:
the E80 received it, auto-saved on the capacity-th point, emitted
the expected SAVED reply, and the new track propagated back to
subscribers (visible in navMate's UI) without further
intervention.

The spec was corrected and committed before any further attempts.
The cross-wall debugging dynamic worked exactly as the cleanroom
discipline anticipates: independent analyses on both sides of the
wall converged on the same fix, the spec round-tripped through
one revision, and end-to-end verification took the third attempt.

## What this means for /raymarine/NET

The TRACK writer-mode is the canonical demonstration of the
exploration-to-implementation loop. The cleanroom spec at
[TRACK_writing](TRACK_writing.md) was
handed off to a separate implementation session and turned into
`d_TRACK_writer.pm` on the navMate side. The
navMate-database/E80-reflection-window cut/copy/paste integration
that has been a stated long-term goal now works for tracks.

The same architectural pattern (writer-mode triggered by a
previously-unused SEND command, two-phase CMD_END, auto-save when
capacity reached) is structurally available for the corresponding
WPMGR-side gap (SEND CMD_EVENT in all three W contexts) -- though
the WPMGR-side semantics have not been investigated and may differ
in detail.

---

**Next:** [FILESYS](FILESYS.md) ...
