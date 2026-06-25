# FishHistory

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

The fishfinder instrument-history service: the time-series of
sounder-derived values the E80 keeps and serves over the network.
FishHistory is the project's name for the firmware's HistData service
(SID 0x16, TCP 2055). The CamelCase name marks it as a known
service that is not yet implemented in /raymarine/NET.

## What it is

FishHistory is the history subsystem behind the fishfinder. As
the sounder pings, the E80 keeps a rolling record of what it
saw -- both the raw scrolling sonar image and a set of numeric
series distilled from it (detected targets, bottom depth, water
temperature, and similar sounder-derived values). The service
lets another networked display ask for that history and subscribe
to new points as they arrive, so a second screen can show the
same scroll-back and graphs the originating unit has.

It is an **advertised, served** RAYNET service: it appears in the
RAYDP catalog at SID 0x16 and the E80 hosts it on TCP 2055. It
has long been observed on the wire under the working name `func22_t`,
emitting events as soon as a client connects.

## Not the navigation database

FishHistory is a separate domain from the navigation
[DATABASE](DATABASE.md). The database carries waypoints, routes,
and tracks; FishHistory carries fishfinder time-series. They share
only the common RAYNET service shape -- different data model,
different service, different SID. A FishHistory entry is a sounder
sample point, not a navigation record.

## Command structure

The protocol is a small request/response set plus a push channel,
keyed by a 4-byte **series key** that selects which history series
the operation refers to. Every message leads with a 4-byte type
word that carries the service id (0x16) and a message selector.

Queries (client to E80):

| Message | Type word | Meaning |
| --- | --- | --- |
| GetNumberOfEntries | `0x00160102` | how many points the series currently holds |
| GetEntry | `0x00160100` | fetch one point from the series |
| GetHistory | `0x00160101` | fetch the whole series |

Replies (E80 to client):

| Message | Type word | Payload |
| --- | --- | --- |
| GetNumberOfEntriesResponse | `0x00160003` | a count |
| GetEntryResponse | `0x00160001` | one fixed-size entry |
| GetHistoryResponse | `0x00160002` | a count followed by that many entries |

Push (E80 to client): on connect, the connection subscribes to the
series it is interested in, and the E80 then sends a **DataAdded**
notification (`0x00160200` / `0x00160000`) each time a new point is
appended. This is the "events on connect" behavior seen on the
wire: a client does not have to poll to stay current.

The service the E80 hosts is **read-and-subscribe**. The firmware
also defines write-side messages -- StartTransaction, SendData,
EndTransaction -- for uploading history, but the E80's server does
not act on them inbound; they belong to the writer/uploader
direction and are not exercised by the served side.

## What the data is -- buffers and entries

Two layers of storage sit behind the service.

**The scrolling sonar image.** The producer keeps two channels
(the dual-frequency sounder), and for each channel a ring of **800
columns** -- one column per displayed ping, matching the width of
the history view. Each column carries a **4 KB raw amplitude
buffer** (the echo-strength samples drawn as the sounder image)
plus a small block of per-column metadata (range, depth markers,
sample count, and similar fields). As new pings arrive the ring
wraps at 800, scrolling the oldest column off.

**Detected targets.** While building each column the firmware also
scans the amplitude samples against a gain-derived threshold and
records up to **60 targets** (fish-echo runs) per column, each as a
start position plus a run length. This is one of several numeric
series distilled per ping.

**The served entries.** The numeric series the network protocol
hands out are not the 4 KB image columns; they are compact records.
Each history entry is a **fixed 16-byte record**, and GetHistory
returns a count followed by a packed array of these 16-byte
records. The series key chosen in the request selects which series
(targets, depth, temperature, and the rest) the entries come from.

## Status and open edges

The service identity, the command set and type words, the
read-and-subscribe model, and the producer's buffer geometry
(channels, 800-column ring, 4 KB columns, 60-target detection) are
established. Two things are **not yet decoded**:

- The internal field layout of the 16-byte entry record (what the
  bytes mean -- timestamp, value, min/max, etc.).
- The full enumeration of series keys (which key value names which
  sounder series). One series -- target detection -- is identified;
  the others are known to exist but not individually mapped.

Both would come from reading the remaining series-writer paths on
the producer side; they are noted here as the open edge.

---

**Next:** [Home (Abstracts)](readme.md) ...
