# Applications -- the on-screen model

**[Architecture](readme.md)** --
**[overview](overview.md)** --
**[runtime](runtime.md)** --
**[services](services.md)** --
**[instruments](instruments.md)** --
**applications** --
**[persistence](persistence.md)**

folders: **[Home](../readme.md)** --
**Architecture** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The application layer is the E80's **soul** -- the part a person looks at and
operates. This is the firmware-side object model behind it: how the screen is
organized, what an "app" is, how the three instrument apps build their panels,
and the configuration-UX that edits all of it.

This is a design doc (it names classes). The user-facing description and the
on-flash byte layouts are [abstracts/Config](../abstracts/Config.md); the
data-item model the cells bind to is [instruments](instruments.md); how any of
this survives a power cycle is [persistence](persistence.md).

---

## 1. The display: three zones

The screen is three zones (the manuals):

```
  +-------------------------------------------------+
  |  data bar      (CDataBar -- live instrument values + status)
  +-------------------------------------------------+
  |                                                 |
  |  Page          (the windowed region -- the apps)|
  |                                                 |
  +-------------------------------------------------+
  |  [F1] [F2] [F3] [F4] [F5]   (five soft-keys)    |
  +-------------------------------------------------+
```

The **data bar** runs across the top (a `CDataBar` reading the instrument model
-- see [instruments](instruments.md)); the **five soft-keys** run across the
bottom, context-labeled; the **Page** is everything between, and it is where the
applications live.

## 2. The containment model: page set -> page -> window -> app

The application layer is organized as a strict containment hierarchy, owned at
the top by **`CMainApp`**:

```
  data master            one networked unit owns the shared state
    page set    (5)      named layouts the PAGE button cycles through
      page      (5)      one screenful; can be switched off (skipped)
        window  (1-4)    a region of the page, per the layout string
          app            one application class instance fills the window
```

Five page sets (Navigation, Situational Awareness, Boat Systems, Fishing,
Custom), five pages each, one to four windows per page, one app per window. One
page set is active and one of its pages is shown. The window does **not** store
an app object -- it stores the app's **16-byte CLSID**, resolved back to a live
class at boot through the class registry (`CHSBClassInformation` /
`IClassInformation`; see [persistence](persistence.md), section 2). The layout
string, the per-window CLSIDs, and the active-page selection are the persisted
page-set state; their byte layout is in [abstracts/Config](../abstracts/Config.md).

## 3. The applications

About eleven applications fill windows. The user-visible roster and its
app-id / CLSID / class table are in [abstracts/Config](../abstracts/Config.md); the firmware classes (from the vtable catalog) are:

- **`ChartingApp`** -- the 2D chart, rendered by a **Navionics** engine
  (`CNavionicsRenderController` and a family of `CNavionics*` classes);
- **`BathyChartApp`** -- the 3D / bathymetric chart;
- **`RadarApp`**, **`FishFinderApp`** -- radar and sounder;
- **`CDataApplication`**, **`CEngineApplication`**, **`CCDIApplication`** -- the
  three **instrument apps** (section 4);
- **`VideoApp`**, **`CWeatherApp`** -- video input and weather;
- Navtex and AIS round out the catalogue.

Two on-screen labels diverge from their class behavior (the unit's "CDI" is a
forward 3D view; "3DChart" is bathymetric) -- a Design-tier wrinkle documented
in [abstracts/Config](../abstracts/Config.md). The applications are RayCom
classes (see [persistence](persistence.md), section 1); the largest by
vtable-method count are the radar/sonar proxies and the chart/app surfaces.

## 4. The instrument apps and their panels

Three apps -- **Data**, **Engine Monitor**, **CDI** -- do not render a fixed
view; they fill their window with a **panel** of configurable readouts. All
three are the same ~3 KB C++ object built on a single base,
**`CInstrumentationApplicationBase`**, which is why the manual documents panel
customization once and notes it "also" applies to the other two.

The panel object model:

- **`IPanelSet`** -- the collection of selectable panels the soft-keys cycle;
  each panel can be renamed (`CInstrumentPanelRenameDialog`).
- **`CInstrumentGrid`** -- a panel is a recursive grid of cells. The user
  reshapes it through **`IInstrumentGridMergeAndSplitCallbacks`** (SPLIT a cell
  into two; MERGE a cell with its neighbor), exactly as a page-set window spans
  merged quadrants, one resolution finer.
- **`CInstrumentGridSizes`** -- the grid dimensions come from a fixed ladder
  (1x1, 1x2, 2x2, 2x4, 4x4), read by `getDimensions(index, orientation)`; the
  maximum is **4x4 = 16 cells**.
- **`CInstrumentDataSource`** -- each leaf cell is bound through this to one
  **data item** from the instrument model (see [instruments](instruments.md)),
  shown in a per-cell display format (numeric / digits / gauge / graph).

The application advertises its capabilities the COM way -- a QueryInterface map
of sixteen interfaces (`IPanelSet`, `IInstrumentManager`,
`IInstrumentApplicationConfiguration`, `IRayApplicationSetup`, ...). That map is
a capability list, **not** stored data -- an easy trap, since both are tables of
GUIDs (see [persistence](persistence.md), section 1).

## 5. The configuration-UX layer

A real configuration-UX layer sits alongside the apps -- the machinery that lets
the user *edit* the model rather than just view it. It is architectural; the
specific menus and dialogs are Design detail. Its shape:

- **editing page sets** -- assigning apps to windows, choosing layouts;
- **editing panels** -- the configure-data / configure-panel applets that drive
  SPLIT / MERGE and bind cells to items;
- **selecting data items** -- a multi-tier selection through
  `CInstrumentGroupSetupMenu` (the data groups: Vessel, Navigation, Depth,
  Environment, Wind, Time and Date, Engine) then `CInstrumentItemSetupMenu` (the
  item within the group);
- **customizing the data bar** -- the same item-selection model feeding the top
  strip.

The group/item setup menus and the panel rename dialog are confirmed firmware
classes; the broader applet/dialog/popup family is enumerated as Design detail
(see [abstracts/Config](../abstracts/Config.md)).

## 6. The control surface

The application is driven by a **fixed control panel** plus soft-keys and a
cursor (the manuals): dedicated keys **PAGE** (cycle pages; hold to pick a set),
**ACTIVE** (choose the active window), **WPTS**, **DATA**, **MOB**, **MENU**,
**RANGE**, **OK**, **CANCEL**, the five context **soft-keys**, and the trackpad
**cursor**. The control surface is fixed hardware; the apps and the
configuration-UX interpret it.

---

**Next:** [persistence](persistence.md) ...
