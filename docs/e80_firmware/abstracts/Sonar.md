# Sonar

Return to [**Abstracts**](readme.md)

The sonar / fishfinder network service: how the E80 republishes a DSM (Digital
Sounder Module) sonar's echo data and configuration onto SeaTalkHS, and the
**two protocol generations** it supports. RAYDP **SID 24 (0x18) "Sonar2"** and
**SID 32 (0x20) "Sonar3"** -- two distinct SIDs that the E80's own diagnostics
screen presents under a single **"Fishfinder"** service. Consumed by the E80
from a networked DSM sounder module; the E80 serves sonar itself only when
configured to be the sounder source (see *Who advertises*). Not yet implemented
in `/raymarine/NET`.

## What it is

A sounder transducer connects to a Raymarine **DSM** (Digital Sounder Module).
The DSM is itself a native **SeaTalkHS (Ethernet)** device: on an E-Series
network it plugs into the same SeaTalkHS switch as the displays. It produces the
sonar -- a continuous stream of **ping** records (the per-column echo samples
drawn on screen) plus **configuration** records (range scales, gains,
frequencies, channel/transducer setup) -- and broadcasts them on SeaTalkHS so any
networked display can show the same fishfinder picture without its own transducer
wiring.

The firmware recognizes three DSM models, which differ in power and channel
count (all SeaTalkHS-capable for E-Series):

- **DSM30** -- 600 W, dual-frequency 50 / 200 kHz.
- **DSM300** -- 1 kW, dual-frequency 50 / 200 kHz (also supports the older HSB bus).
- **DSM400** -- 3 kW, **four independent transceivers** at 28 / 38 / 50 / 200 kHz.

The E80 is built primarily to **consume** the DSM's stream (it receives the
DSM's RAYDP advertisement and instantiates Source A/B); it can also serve sonar,
but only when configured to be the sounder source itself (see *Who advertises*).

There are two of them because there are two generations of the protocol:

- **Sonar2** -- the older protocol. One combined configuration message.
- **Sonar3** -- the newer protocol. Configuration split into two messages, an
  extra event message, and a larger advertisement that carries additional
  channel endpoints (multi-channel / dual-frequency-class DSMs).

Whichever generation the attached DSM speaks is what appears on the network, and
each display instantiates the matching decoder. Both appear to the user as the
one "Fishfinder" service.

## Two services, one Fishfinder

The split is real at the wire-discovery layer and is resolved deterministically
in firmware. Each service's RAYDP factory stamps a **registration type tag** onto
the advertisement record; the consume-source constructor selector reads that tag
to build the matching `CLNet*Source`:

| RAYDP service | SID         | reg. tag | consume source | working buffer | advertisement |
| ------------- | ----------- | -------- | -------------- | -------------- | ------------- |
| **Sonar2**    | 0x18 (24)   | `0x400`  | Source **B**   | ~200 KB        | 36-byte (0x24) |
| **Sonar3**    | 0x20 (32)   | `0x101a` | Source **A**   | ~400 KB        | 52-byte (0x34) |

Sonar2's tag `0x400` sits in a legacy low range; Sonar3's `0x101a` sits in the
modern range alongside the other current instruments (GPS `0x1006`, AutoPilot
`0x1007`, Compass `0x1015`, Navtex `0x1017`, AIS `0x1019`). The tag is an
internal source-type enum, independent of the SID -- the `0x400` vs `0x101a`
difference is exactly the old-vs-new generation split. Sonar3's 52-byte
advertisement is the only one in the whole catalog longer than 40 bytes; the
extra 16 bytes carry additional channel ip:port endpoints.

## Who advertises -- serve vs consume

Which device hosts the service matters for a decoder, and the firmware points to
a clear answer. The E80's **consume** path is unconditional: the RAYDP
advertisement dispatcher always carries the sid-0x18 / sid-0x20 cases that build
Source A/B from an *incoming* advertisement. The E80's **serve** path is not --
it constructs its own Sonar2 / Sonar3 servers only when a configuration value
marks this unit as the sounder source, and there is no unconditional boot hook
for them (unlike the always-on services such as Navigation, Waypoint, and Track).

The reading that follows: a DSM, being a native SeaTalkHS device, **advertises
the Sonar service itself** and broadcasts the pings; the E80 (and every other
display) consumes it. The E80 serves sonar only in the special case where it is
*itself* the sounder source (an internal or simulated sounder). This is the
firmware-favored interpretation; it has **not yet been observed on the wire** --
see *Status and open edges* for how a capture confirms it.

## Transport and framing

Sonar is a UDP service on the on-demand instrument tail (it constructs only when
sonar data appears, claiming the next free unicast port from 2056 and multicast
group from 2563 -- see
[RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)).

Three things make this protocol's framing different from the instrument services
(GPS, AutoPilot, AIS, ...):

- **It is a one-way report stream.** Every message is a server-to-multicast
  report. No command messages were found in the consume path -- range / gain /
  mode control reaches the DSM through the unit's local sounder/ConfigItem
  machinery, not over this wire service.
- **The selector space is `0x1801xx`, not the report/command split.** Where the
  instrument services use the command word's `0x100` bit to mean "command vs
  report", the sonar messages are simply numbered `0x180100`..`0x180104`. The
  `0x100` here is part of the message number, not a direction flag.
- **Both SIDs share the `0x18` wire family.** Sonar2 (sid 0x18) and Sonar3 (sid
  0x20) **both** stream `0x0018xxxx` command words. The SID distinguishes the
  *advertisement* (which generation / which mcast group), but on the wire both
  generations use the same `0x18` base. (Consequently these are not firmware
  `C*Msg_*` RTTI classes the way the instrument messages are -- they are raw
  structured datagrams, and the message names below are descriptive of the
  decode handlers, not firmware class names.)

```
cmd_word = 0x0018 << 16 | sel       sel = 0x0100 .. 0x0104
           (same 0x18 base for both Sonar2 and Sonar3)
```

Decoded records are delivered to registered change-sinks on three interface
slots, and the slot is the clearest guide to a message's role:

- **vt[0x14]** -- scan data (the ping, and the per-scan settings)
- **vt[0x1c]** -- channel / transducer configuration
- **vt[0x2c]** -- events

The unit applies and forwards the decoded settings only when it is the **active
sonar source** (gated on a SysInfo role flag) -- relevant when more than one
display is on the network.

## Message set

**Sonar2 (Source B)** -- one combined configuration plus the ping:

| cmd_word     | message    | size      | sink        | meaning                                            |
| ------------ | ---------- | --------- | ----------- | -------------------------------------------------- |
| `0x00180100` | Config     | 340 bytes | vt[0x14] + vt[0x1c] | combined scan-settings + channel config    |
| `0x00180101` | Ping       | variable  | vt[0x14]    | one echo column (header + echo-sample blob)        |

**Sonar3 (Source A)** -- the ping, the configuration split in two, plus an event:

| cmd_word     | message       | size      | sink        | meaning                                         |
| ------------ | ------------- | --------- | ----------- | ----------------------------------------------- |
| `0x00180101` | Ping          | variable  | vt[0x14]    | one echo column (same record shape as Sonar2)   |
| `0x00180102` | ScanSettings  | 228 bytes | vt[0x14]    | per-scan settings (range / gain / depth scalars)|
| `0x00180103` | ChannelConfig | 768 bytes | vt[0x1c]    | per-channel / transducer config + name strings  |
| `0x00180104` | Event         | small     | vt[0x2c]    | an event / marker notification (no Sonar2 peer)  |

The two generations carry the **same information**; Sonar3 just factors it
differently. Sonar2's single `Config` (`0x180100`) notifies *both* the
scan-settings sink (vt[0x14]) and the channel-config sink (vt[0x1c]) from one
datagram; Sonar3 splits those into `ScanSettings` (`0x180102`, vt[0x14]) and
`ChannelConfig` (`0x180103`, vt[0x1c]), and adds the `Event` message (`0x180104`,
vt[0x2c]) that Sonar2 has no equivalent of.

## The ping -- echo column (`0x180101`, both generations)

The ping is the actual fishfinder data: one **vertical echo column**. Its record
is identical between the two generations (Sonar3 fills two extra header bytes
Sonar2 leaves unset). The datagram is a **~0x5c-byte header followed by a
variable-length echo-sample blob**:

| region        | offset (datagram) | notes                                                        |
| ------------- | ----------------- | ------------------------------------------------------------ |
| cmd_word      | 0x00              | `0x00180101`                                                 |
| sequence / id | 0x04              | u16                                                          |
| type / channel| 0x06              | byte -- channel/beam selector; values 1 / 2 / 3 / 4 (see below) |
| scalar block  | 0x10 .. 0x34      | u16/u32 scan parameters: depth, range, gain, scale (typed but per-field meaning inferred) |
| echo length   | 0x10              | u32 -- number of echo samples that follow                    |
| (header tail) | 0x35 .. 0x37      | bytes (Sonar3 fills these; Sonar2 does not)                  |
| echo samples  | 0x5c              | `echo length` bytes -- the per-column intensity samples      |

Two field meanings are pinned from the firmware (the rest await a live capture):

- The **depth** scalar drives the unit's depth pipeline: a keel/transducer
  offset is added and the **shallow and deep depth alarms** are evaluated against
  it. So the ping is the source of the displayed depth, not just the echo image.
- The **type/channel** byte selects the transceiver/beam, and the values map
  naturally onto a DSM's channels: a four-transceiver **DSM400** (28 / 38 / 50 /
  200 kHz) would use **1 / 2 / 3 / 4**, while a dual-frequency **DSM30 / DSM300**
  (50 / 200 kHz) would use only **1 / 2**. Values **3 and 4 are treated
  specially** -- they do *not* update the primary range/depth, consistent with
  the supplementary low-frequency channels (or secondary zoom / bottom-lock
  panes) not driving the main depth readout.

The scalar block values are raw on the wire and pass through unit-conversion
objects before display, so a capture is the way to fix the exact units and the
per-offset assignment (which u32 is range vs gain vs frequency vs scroll).

## Configuration reports

The configuration carries the channel/transducer setup and the selectable scan
parameters. It is a large, per-channel structure:

- **Sonar2 `Config` (`0x180100`, 340 bytes)** -- a channel count followed by
  variable per-channel sub-records (nested at 0x114-byte and 0x73-byte strides)
  holding range-scale lists, frequencies, gains, and zoom settings, plus a
  transducer name string. One datagram feeds both the scan-settings and the
  channel-config sinks.
- **Sonar3 `ScanSettings` (`0x180102`, 228 bytes)** -- the currently selected
  scan parameters (range, gain, channel) published as ConfigItems on the
  scan-settings sink.
- **Sonar3 `ChannelConfig` (`0x180103`, 768 bytes)** -- the richer per-channel
  table (per-channel sub-records at an 0x88-byte stride, *two* 15-character name
  strings, an 0x80-byte block) on the channel-config sink. The larger size and
  the second name string are the multi-channel detail that motivated the new
  generation.

The per-field layout inside these records is structurally mapped but its exact
semantics (which list is range scales vs frequencies, the meaning of each
per-channel flag) is best confirmed by capture.

## Status and open edges

**Established (firmware):** the two SIDs and that they are one user-facing
"Fishfinder"; the deterministic registration-tag -> consume-source mapping
(Sonar2/`0x400` -> Source B, Sonar3/`0x101a` -> Source A); that both generations
share the `0x18` wire family and are report-only (no command path in the consume
sources); that the consume path is unconditional while the serve path is gated on
a sounder-source configuration value; the complete message set and datagram sizes
for each generation; the sink-slot routing (scan data / channel config / event);
the shared ping record with its header-plus-echo-blob shape; and the ping's role
as the depth source feeding the keel offset and the shallow/deep depth alarms.

**Not yet observed on the wire (confirmable on a live network):**

- **Who advertises the service.** The firmware favors the DSM advertising and
  serving it directly (the E80 consuming), but this has not been watched on the
  wire. It is confirmable from the **destination multicast IP of the ping
  stream**: a served group is derived from the *server's own* IP address
  (`224.0.0.0 + (low16 << 5) + (port - 2559)`, see
  [RAYDP -> Multicast group addressing](RAYDP.md#multicast-group-addressing)), so
  computing the group from the DSM's IP versus the E80's IP and matching it to
  the actual stream identifies the server. Decoding the RAYDP advertisement on
  224.0.0.1:5800 and reading its origin device-id is the direct version.
- **Which SID a given DSM advertises.** Whether the dual-frequency DSM30 / DSM300
  use Sonar2 (0x18) and the four-transceiver DSM400 uses Sonar3 (0x20) -- i.e.
  whether the generation split tracks hardware tier -- or whether it is instead a
  firmware-version split, is unconfirmed.

**Not yet pinned (best resolved by a live capture):**

- The exact meaning and units of the ping's scalar block (which field is range
  vs gain vs frequency vs scroll/zoom) and the precise `type`/channel
  enumeration (the 1/2/3/4 channel identities).
- The per-field layout of the `Config` / `ScanSettings` / `ChannelConfig`
  records (the range-scale and frequency lists, per-channel flags).
- The content and purpose of the Sonar3 `Event` message (`0x180104`).
- Whether any wire **command/control** path exists at all, or whether range /
  gain / mode is purely a local-to-the-DSM concern as the consume sources
  suggest.

A capture against a DSM -- a dual-frequency DSM300 for the baseline, a DSM400 to
exercise all four channels -- would resolve the scalar units, the channel
enumeration, the config field layout, and which SID the module advertises, in one
session.

## Why it matters

The fishfinder echo column is a high-value, high-rate data product, and this is
the service that carries it over SeaTalkHS. A `/raymarine/NET` decoder
(`d_Sonar`) would need to handle **both** generations -- pick Source A vs B by
the advertised SID, then decode the shared `0x18` ping plus the
generation-specific configuration. The ping alone (one fixed header + an echo
blob) is enough to reconstruct the sounder image and read depth; the
configuration messages add the range/gain/channel context. Decoding is pure
read-side monitoring -- there is no control surface to worry about here.

---

Return to [**Abstracts**](readme.md)
