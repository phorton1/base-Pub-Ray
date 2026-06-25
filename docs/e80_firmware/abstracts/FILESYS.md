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

Filesystem access service. Clean, usable wire interface; resolves
negatively on the long-open question of whether FILESYS supports
writing to the CF card.

FILESYS is the E80's file-access service over Ethernet. It is the
RAYNET service used to read files from the chartplotter's
CF card (most importantly `ARCHIVE.FSH`, the navigation-data
archive). UDP rather than TCP -- unlike WPMGR/TRACK/DATABASE, the
file-access pattern is request/response without long-running
sessions, and the per-client state held on the E80 is light.

## Scope: CF card only

Wire-tested 2026-05-28: a FILESYS `CMD_DIR` for the path `\LOCAL\`
returns failure. FILESYS exposes the CF card filesystem only and
does not reach the internal flash filesystem where `\LOCAL\` lives
(the page-set persistence layer, consolidated in `\local\slotless\CMainApp0.lp`).
Consistent with the static evidence that `\LOCAL\` is backed by
`CFlashFlobFsDriver` while FILESYS / `CFAccessController` is the
CF card driver -- different classes, different volumes. The
`d_FILESYS.pm` already treats the tree as rooted at `/`; the
backslash-prefixed `\LOCAL\` paths used by `CLocalPersistenceService`
are a different namespace this service does not bridge.

## Command vocabulary

Nine commands, all encoded as `0x000501XX`:

```
0x00050100  CMD_DIR          directory listing
0x00050101  CMD_GET_SIZE     file size
0x00050102  CMD_GET_FILE     read file contents (chunked into 1024-byte packets)
0x00050104  CMD_GET_ATTR     file attributes
0x00050105  CMD_FILE_EXISTS  existence check
0x00050106  CMD_GET_SIZE2    alternate size query
0x00050107  CMD_LOCK         advisory lock
0x00050108  CMD_UNLOCK       advisory unlock
0x00050109  CMD_CARD_ID      card identification
```

This matches the `%FILE_CMD_NAME` table in
`/raymarine/NET/d_FILESYS.pm` exactly.

## The CMD_UNKNOWN3 hole

The `d_FILESYS.pm` empirical table includes a `CMD_UNKNOWN3` slot at
`0x00050103` that the E80 didn't respond to. After 14 hours of
mystery, the firmware exploration resolved this definitively:
**there is no case 3 in the dispatcher switch**. CMD_UNKNOWN3 is
not a hidden feature -- it's a missing case. The default path is
silent cleanup-and-return.

## No write path

The most important negative finding: **FILESYS has no write
commands.** No `PUT_FILE`, no `MKDIR`, no `DELETE`, no `RENAME`,
no `SET_ATTR`. The 9 commands above are the complete protocol
surface. The default case in the dispatcher silently discards any
command word the dispatcher doesn't recognise; no write logic
exists in this service to be activated by a crafted command.

This resolves the long-open question "can we write to the E80's
CF card via FILESYS over Ethernet?" with a definitive **no**.
The chartplotter does write to its own CF card (it has to, to
persist state), but those writes happen through internal
CCFArchive code paths that FILESYS does not expose.

Writing TO the E80 over the wire happens through per-domain
RAYNET services -- the WPMGR-side waypoint/route/group writes,
the TRACK writer-mode upload protocol -- that route through the
CCFArchive code path internally. FILESYS is read-only at the
wire level, by design.

## The ARCHIVE.FSH lockout

The behavior that "GET_FILE on `\Archive\ARCHIVE.FSH` prevents
subsequent saves to ARCHIVE.FSH until reboot" is not produced by
FILESYS code itself. FILESYS sees the path only as a generic
string passed to the underlying filesystem object's open method.
The lockout is at the filesystem-object layer (CCFArchive and
friends), presumably because the open handle is never released
-- FILESYS sessions are keyed by client_ip with no explicit close
command, so the file stays open until reboot.

The lockout is a side-effect of the FILESYS session model meeting
the filesystem's exclusive-open requirement on ARCHIVE.FSH; it
is not an intentional locking feature.

## LOCK/UNLOCK

`CMD_LOCK` and `CMD_UNLOCK` implement a simple advisory counter
on the Server (incremented by LOCK, decremented by UNLOCK).
Per-client lock entries (keyed by client_ip+client_port) live in
an RB-tree on the Server. LOCK does not appear to gate any write
logic (because no write logic exists in FILESYS). Its practical
effect on the chartplotter's internal CCFArchive writes -- which
proceed through code paths FILESYS doesn't touch -- remains
untested.

## Session state

GET_FILE establishes a per-client open-file session keyed by
client_ip in an RB-tree on the Server. The session holds the file
object pointer (open handle) and the last-known read offset (used
to detect re-seeks). Sessions persist for the lifetime of the
connection. The session-create path goes through the underlying
filesystem object's open vmethod where the file is actually
opened.

For reads up to 10000 bytes, the response uses a pre-allocated
10000-byte rx scratch buffer on the Server. For larger reads, a
malloc is performed. The handler chops the read into 1024-byte
packets and emits one packet at a time via the send-side socket,
the final packet carrying the remainder.

---

**Next:** [DATABASE](DATABASE.md) ...
