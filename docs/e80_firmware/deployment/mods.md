# Mods

**[Deployment](readme.md)** --
**[containers](containers.md)** --
**[installer](installer.md)** --
**[bootloader](bootloader.md)** --
**[modification](modification.md)** --
**mods** --
**[diagnostics](diagnostics.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Cleanroom](../cleanroom.md)**

The **catalog of specific modifications**. [modification](modification.md) is the
generic *process* -- the record format, the build pipeline, the version formula, the
safety floor. This page is the *instances*: which mods exist, what version each
package carries, what each package contains, and what has been confirmed on hardware.
Each mod has its own design page.

## The mods

| mod | what it is | enables | design |
|---|---|---|---|
| **mod001** | a remote peek / poke / call diagnostics primitive on the unadvertised Diagnostics service (UDP 6667), built by reclaiming a pair of dead helper routines | the live-device read/write channel the project reads hardware with ([diagnostics](diagnostics.md)); the substrate under the config backup/restore library ([cleanroom/e80Config_API](../cleanroom/e80Config_API.md)) | [mod001](mod001.md) |
| **mod002** | a fast, tear-free full-screen capture ("grab") over the Diagnostics TCP port (6668), built by reclaiming a dead handler body; also stamps the running app version | the live-screen capture library ([cleanroom/e80ScreenGrab_API](../cleanroom/e80ScreenGrab_API.md)) | [mod002](mod002.md) |
| **mod003** | per-track-point **datetime + corrected depth**: the on-device track recorder stamps each committed point with a real wall-clock time and the true depth in feet, by reclaiming an InterNiche dev-CLI reservoir for the injector; a DB toggle reverts it to stock tracks without a reflash | date-stamped standalone-recorded tracks (the E80 records while no host is connected) that any [TRACK](../abstracts/TRACK.md) reader recovers time + depth from directly | [mod003](mod003.md) |

The `mod001` name was **reused**: the *first* mod001 (a firmware enable-gate flip) was
proven to install but reached a dead end and was reverted; the slot was re-scoped to
the diagnostics primitive. That history is in [mod001](mod001.md).

## Version assignments

[modification](modification.md) defines the *formula* -- each new mod takes the next
number above stock, the gaps are intentional, the label is display + installer-ordering
only (never a schema/persistence version), and downdate is supported. The assignments:

| version | package / state |
|---|---|
| 5.69 | stock E80/120_App (and the original, reverted mod001, built at 5.69) |
| 5.70 | reserved (intentional gap) |
| 5.71 | standalone mod001 (peek / poke / call); its version records stamp `569 -> 571` |
| 5.72 | the mod002 package = mod001 + mod002; the version stamp chains `571 -> 572` |
| 5.73 | the mod003 package = mod001 + mod002 + mod003; the version stamp chains `572 -> 573` |

## Package composition

Mods are **byte-disjoint** -- each patches its own regions -- so a package is just a
linear chain of apply steps over a chosen base binary, and one package can carry
one mod or several. What we actually build:

| package | version | mods included |
|---|---|---|
| `E_App_Upg_Uni.mod003.pkg` | 5.73 | mod001 + mod002 + mod003 |

The aggregation is **client-driven**: a client that wants two capabilities (e.g. the
config backup *and* the screen grab) needs firmware carrying both mods, so the shipped
package carries both. This is the *binary / package* view -- the only relationship
between two byte-disjoint mods is that they coexist in one image. The one exception is the
**version stamp**: each mod stamps the app's reported version to match its own package, so
stacking them chains the stamp (stock `569` -> mod001 `571` -> mod002 `572` -> mod003 `573`) -- the only bytes
two mods share, which the apply step's `old_hash` makes explicit and verified.

---

**Next:** [mod001](mod001.md) ...
