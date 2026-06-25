# Instruments -- the data fusion

**[Architecture](readme.md)** --
**[overview](overview.md)** --
**[runtime](runtime.md)** --
**[services](services.md)** --
**instruments** --
**[applications](applications.md)** --
**[persistence](persistence.md)**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The architectural center of the running firmware: how **four marine protocol
worlds become one instrument-data model**, and how everything else -- the apps,
the data bar, the instrument panels, and the networked services -- draws from
that single model. The [crown](overview.md) names this the *heart*; this is
the factored design behind it.

This is a design doc: it names the implementation classes. The conceptual
data-dictionary view is [abstracts/DB_FIDS](../abstracts/DB_FIDS.md); the broadcast
that carries the fused data over the wire is
[abstracts/DATABASE](../abstracts/DATABASE.md).

---

## 1. The fusion, in one picture

```
   Seatalk1     NMEA 0183     NMEA 2000     SeaTalkHS (ethernet)
      |             |             |              |
      +------+------+------+------+------+-------+
             |  a sensor reading, whatever its wire
             v
      a PROXY per data source  (the local stand-in for one source)
             |
             v
      the INSTRUMENT-DATA model  (one data item per quantity-instance;
             |                    a Seatalk heading and an N2K heading
             |                    are the SAME data item)
             v
      consumers:  the apps  |  the data bar  |  the instrument panels  |
                  the networked services that re-broadcast to peers
```

A reading enters from any of the four protocol worlds, is normalized by the
proxy for its source, and lands in the shared model as a **data item**. From
there every consumer reads the same model -- it never matters again which wire
the value came in on. That wire-independence is the whole point of the fusion.

## 2. The four protocol worlds (the sources)

The E80 ingests sensor data over four protocols (the manuals; confirmed on the
wire). Each is a distinct wire world with its own parsing layer, visible in the
firmware's own source-tree taxonomy:

| Protocol | Role | Firmware source area |
| -------- | ---- | -------------------- |
| **Seatalk1** | legacy single-wire Raymarine bus | `Source/BaseBrick/SeaTalk/` (the `CSeaTalk*` classes) |
| **NMEA 0183** | legacy serial sentences | the `PACKED_NMEA0183_*` data structs |
| **NMEA 2000** | CAN-bus PGNs | `Source/BaseBrick/SeaTalk2/` (`RaymarineMessages.cpp`, the `CCAN*`/`CRaymarine*` message classes) |
| **SeaTalkHS** | the ethernet service stack | the `CLNet*` family -- see [services](services.md) |

The first three are physical instrument buses; the fourth is the networked
re-distribution layer between E-Series displays. The data-item model is what
they all converge on, so a depth from a Seatalk transducer, a depth in an 0183
`DPT` sentence, and a depth in N2K PGN 128267 are three roads to one data item.

The `/Boat` library mirrors this exactly -- `instST` / `inst0183` /
`inst2000` parsers feeding shared depth / wind / gps / compass / engine
instruments -- which is why teensyBoat can drive the E80 through any of the
three legacy buses and observe the same result.

## 3. The proxy-per-source pattern

For each data source the firmware instantiates a **proxy** -- a local object
that stands in for that source and feeds its readings into the model. The
proxies are among the heaviest objects in the image (the vtable catalog ranks
`RayComObject<CRadarProxy>` at 230 methods and `RayComObject<CSonarProxy>` at
216 -- the two largest in the entire firmware). The per-source set, from the RTTI class catalog:

- `CGPSProxy`, `CDGPSProxy` -- position / differential GPS
- `CCompassProxy` -- heading
- `CAutoPilotProxy` -- course computer
- `CAISProxy` -- AIS targets
- `CRadarProxy`, `CSonarProxy` -- radar / sounder
- `CHistDataProxy` -- the fishfinder history series (see
  [abstracts/FishHistory](../abstracts/FishHistory.md))
- depth / speed / wind and the other transducer quantities

A proxy is the **role**, not the wire: the same `CCompassProxy` serves a heading
whether it arrived over Seatalk1 or NMEA 2000. The proxy normalizes its source
into the common data-item vocabulary below.

## 4. The instrument-data model (the data items)

The quantities the system can hold, display, or store are the
**`INSTRUMENT_DATA_ITEMS`** enumeration -- the shared vocabulary every proxy
writes into and every consumer reads from. The firmware describes each item in
RTTI with the template

```
TDBItem< <unit-type>, (UINT16)<id>, INSTRUMENT_DATA_ITEMS::<encoding> >
```

binding three things:

- a 16-bit **id** -- the stable name of the quantity (a panel cell or data-bar
  slot stores this id to name what it shows);
- a **unit-type** -- the physical meaning *and* the fixed-point scaling
  (`SPEED_0_01_METRES_PER_SECOND`, `ANGLE_0_0001_RAD`, packed structs such as
  `PACKED_POSITION_STRUCT`);
- an **encoding** -- byte / short / long (with signed variants), or a named
  packed struct for composite values.

**160 distinct ids** are enumerated from the image.
The pairing of unit-type with a raw integer is what makes the model
self-describing: the stored number plus its unit-type fully determine the
physical quantity, and the user's Units setup (knots vs mph, feet vs metres) is
a display-time conversion layered on top. The id space is shared across every
source -- which is precisely how two wires collapse to one item.

A cell or data-bar slot binds to one item through the firmware class
`CInstrumentDataSource` (the binding object that connects a consumer to a model
quantity). See [applications](applications.md) for the panel/cell side and
[persistence](persistence.md) for how a binding is stored.

## 5. The consumers (who draws from the model)

The model has one set of producers (the proxies) and many consumers, all
reading the same items:

- **the apps** -- Chart, Radar, Fishfinder and the rest render from the model;
- **the data bar** (`CDataBar`) -- the strip of live values across the top;
- **the instrument panels** -- Data / Engine / CDI, each cell a
  `CInstrumentDataSource` bound to one item (see [applications](applications.md));
- **the networked services** -- the navigation database re-broadcasts model
  values to peer displays. Every broadcast record carries the item's
  **FID** (its semantic field type) and its **ENC** (encoding type) on the
  wire, so a consumer can decode any value by its ENC without a per-FID
  table (see
  [abstracts/DB_DECODE](../abstracts/DB_DECODE.md) and
  [abstracts/DATABASE](../abstracts/DATABASE.md)).

That last consumer closes the loop: a reading that entered over Seatalk1 leaves
the unit again over SeaTalkHS, carrying the firmware's own FID and ENC.

## 6. Walked on the wire

The fusion is not only inferred from the class graph -- the pipeline has been
exercised end-to-end against a real E80:

- A **Seatalk1** depth driven by teensyBoat, and an **NMEA 2000** depth (PGN
  128267) injected over the diagnostics channel, **both** drove the on-screen
  depth and **both** appeared on the navigation-database broadcast (see
  History, 2026-05-29; the injection path is
  [diagnostics](../deployment/diagnostics.md)).
- The broadcast's per-record `type` field was confirmed to be the firmware's own
  ENC -- one fused vocabulary, end to end
  ([abstracts/DB_DECODE](../abstracts/DB_DECODE.md)).

The producing side of the model -- exactly how a proxy registers a value, and the
per-source registration table -- sits behind the runtime service-locator
indirection ([the wall](overview.md), section 8) and is `[? not statically
traced]`. The *shape* of the fusion is confirmed; the per-proxy wiring is
empirical.

---

**Next:** [applications](applications.md) ...
