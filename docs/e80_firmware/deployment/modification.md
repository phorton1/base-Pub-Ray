# Modification

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

The proven scheme for producing a **modified firmware image** and installing it
on hardware the owner owns: how an edit is recorded, how the package is rebuilt to
pass the manufacturer's own gates, why it is safe to flash, and what has been
confirmed on a real unit. This is the *vehicle*; the *instrument* it currently
carries (the diagnostics peek/poke/call channel) is
[diagnostics](diagnostics.md).

This doc builds on [installer](installer.md) (the container/checksum mechanics)
and [containers](containers.md) (the byte-level facts).

---

## 1. Posture

Modification here is bounded, and the bounds are part of the method.

- **Cooperative with the design, not subversive of it** -- it works through the
  manufacturer's own installer and satisfies the installer's own integrity
  checks, reaching only states the shipped firmware already supports.
- **Additive, carrying nothing of the manufacturer's** -- the new bytes are the
  modder's own work; the recipe verifies each region it overwrites by a *hash*,
  never a copy of the original code (section 2). No manufacturer image, package,
  or derivative is redistributed.
- **On the owner's own hardware, from the owner's own firmware** -- the tooling
  never carries firmware; it transforms a copy the owner already lawfully holds.
- **In service of preservation** -- interoperability and data backup -- with an
  accompanying disclaimer, in the spirit of the device's own limitations-on-use
  notice.

There is **no technical protection measure** to circumvent. The update path
gates on two **additive byte-sum checksums** only -- no CRC, no signature, no
crypto (see [installer](installer.md)). Recomputing the sums after an edit is
arithmetic, not circumvention. A build only ever fixes length fields and
recomputes those byte-sums.

## 2. The edit record

A modification is captured as a serialized **edit record** -- a recipe, not a forked
binary. The record is **publishable by construction**: for each region it overwrites it
carries a *hash* of the original bytes -- a fingerprint, checked against the reader's own
firmware -- plus the new bytes to write, which are the modder's own work. Edits are
**length-preserving**: each new region is exactly as long as the one it replaces, so the
surrounding bytes and every downstream offset are untouched.

Applying a record is mechanical: each region's hash is checked before any byte is written,
so a record can only be applied to the firmware and the region it was made for, and
re-applying it changes nothing. Because the check is a hash, the record carries none of the
manufacturer's original code.

### Record file format

A record is a short synopsis of the mod's purpose, then a sequence of **edit blocks**:

```
edit <address> <file_offset> <length> <hash-of-original>
new
    <hex>   # <disassembly>  ; <meaning>     (the bytes; the comment is for the reader)
    ...
end
```

Each `edit` names its target -- address, file offset, region length, and the hash of the
original bytes -- and the `new ... end` block carries the bytes to write as an inline
assembly listing. The listing and the bytes are **one artifact**, so they cannot drift; the
hex is the single source of truth.

### Annotation directives (the Annotation Layer)

Beyond its byte edits, a record may carry **address-keyed annotation directives**:

- `func` -- create + name a routine + extent
- `sig` -- set the routine's prototype
- `pre` -- pre-comment before an address
- `plate` -- plate (block-header) comment
- `eol` -- end-of-line comment on a line
- `name` -- name a code/data location
- `label` -- label at an address
- `local` -- name a local variable
- `param` -- name a function parameter

They let a disassembly of the
patched firmware be re-annotated straight from the recipe. A mod with no directives simply
patches bytes; simple mods stay simple. The *specifics* of each mod -- its design, version,
and what it unlocks -- are in the mod catalog ([mods](mods.md)).

## 3. Building a package

A mod is built over a working copy of the firmware, so the original is never touched:

1. **Start** from a base image -- the stock extracted application for a first mod, or a
   previous mod's output to stack mods (any other base is a "branch").
2. **Apply** the record's edits to that copy (section 2).
3. **Package** the patched image back into an installer package, rebuilding the container so
   it satisfies the manufacturer's own length and checksum gates (see
   [installer](installer.md)) and stamping the build's version label.

The result is byte-for-byte the manufacturer's structure apart from the application payload
and the recomputed checksums. Several mods stack by chaining the start-and-apply steps over
one working image before the final package; which package carries which mods is in the mod
catalog ([mods](mods.md)).

### Version labeling

The package/app version (e.g. `v5.69`) is a text descriptor in the package and app headers.
It is **display and installer-ordering only**: the running unit shows it in Unit Info and
the boot disclaimer, and the installer compares it to decide update vs downdate (downdate is
supported). It is **not** a schema/persistence version, so changing it is safe in either
direction. A build stamps its own version label; the numbering gives each mod the next
number above stock, with intentional gaps. The per-package assignments are in the mod
catalog ([mods](mods.md)).

## 4. Why it is safe to flash (the bricking floor)

The modification inherits the stock package's safe targeting because it **never
touches the flasher stubs or the destination/region fields** -- only the application
payload bytes. A wrong byte in the application payload yields only a bad *application
image*, which is recoverable by reflashing the stock package: the recovery
actors (`ClearFlash`, `App2FSH`) are independent of the application image's content, and
the **stock-CF reflash recovery path is hardware-confirmed** (a rejected resize
package left the unit fully recoverable; see History,
2026-05-30). The boot region (the inferred stage-0) is written by no action in
the package at all (see [bootloader](bootloader.md)).

## 5. Hardware-confirmed

The pipeline is proven on a real E80, not just on the bench: a resized/recompressed
package installs and boots (so stage-0's boot-time inflater tolerates a resized
stream), a relabel is booted-visible (Unit Info shows the new build machine + date),
and a behavioral edit installs and boots with the user config retained. The
container-level resize/boot proof is in [installer](installer.md); the per-mod
confirmations are in the mod catalog ([mods](mods.md)).

---

**Next:** [mods](mods.md) ...
