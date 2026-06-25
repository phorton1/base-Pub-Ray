# TFTP

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

Standard RFC 1350 TFTP server compiled into the E80's normal
firmware. Listener bound on UDP port 69. Both GET (RRQ) and PUT
(WRQ) operations implemented. Transfers gated by a single-byte
enable flag in memory; when the flag is off, the listener still
parses requests and replies with an error packet.

Discovered 2026-05-28 via static analysis of the e80.bin firmware
and confirmed via live wire probe of E80-4.

## Wire-confirmed behavior

The 2026-05-28 wire probe sent a properly-formatted TFTP RRQ
(opcode 1, filename `"test"`, mode `"octet"`) from a host machine
to 10.0.166.121:69. The E80 replied with a 34-byte TFTP ERROR
packet:

```
hex: 000500005472616e73666572732063757272656e746c792064697361626c65642e00
     ^^^^                                                                  opcode 5 = ERROR
         ^^^^                                                              error code 0
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^    "Transfers currently disabled."
                                                                       ^^ null terminator
```

The reply came from UDP source port 69 itself, not an ephemeral
port -- the listener short-circuits without allocating a transfer
task when the enable flag is off.

This confirms:

- A TFTP server is bound on UDP 69 of every running E80 (modulo
  this version of firmware)
- The implementation follows RFC 1350 packet structure
- The "transfers disabled" error message is sent verbatim from the
  firmware's literal string `"Transfers currently disabled."`

## Request handler structure

The handler at `FUN_0029d51c` in e80.bin performs the following:

| Step | Behavior                                                                            |
|------|-------------------------------------------------------------------------------------|
| 1    | Read opcode (2 bytes, big-endian). Accept 1 (RRQ) or 2 (WRQ); reject opcodes > 2    |
| 2    | Read null-terminated filename                                                       |
| 3    | Read null-terminated mode; accept `"octet"`, `"image"`, `"netascii"`; reject others |
| 4    | Check `*DAT_0029d7f4 != 1` -- if true, reply "Transfers currently disabled." and return |
| 5    | Call access-control hook `(*DAT_0029d7f8[0])(server_obj, filename)`; if returns 0, reply "Transfer refused" and return |
| 6    | Allocate per-transfer state                                                         |
| 7    | RRQ: open file via standard `fopen` with `"r"` or `"rb"` mode; reply error code 1 on failure |
| 8    | WRQ: open file via standard `fopen` with `"w"` or `"wb"` mode; reply error code 2 on failure |
| 9    | Start the transfer in DATA/ACK or ACK/DATA loop                                     |

Files are opened via the standard C library `fopen`. Filename comes
from the wire request with no munging observed. The filesystem
visible to TFTP is whatever the firmware's `fopen` resolves.

## Toggle mechanism

A single byte in memory at `*DAT_0029d7f4` gates all transfers:

- `*DAT_0029d7f4 == 1`: transfers permitted; full GET/PUT processing
- `*DAT_0029d7f4 == 0`: transfers refused with the "Transfers currently disabled." error

Two functions write this flag:

- `FUN_0029d4fc` -- START: `*DAT_0029d7f4 = 1;`
- `FUN_0029d50c` -- STOP: `*DAT_0029d7f4 = 0;`

By static xref, both are called only from `FUN_002a6900` -- the
handler for the menu entry labeled `"Toggle tftp server on/off"`.

The menu entry sits in a data table at `0x0153d748` along with
other TFTP submenu entries:

```
0x0153d740  "tftpc"                       (tftp client submenu container)
0x0153d748  "tftp client menu"            (submenu header)
0x0153d754  "tftp GET a file"             (client GET command)
0x0153d760  "tftp PUT a file"             (client PUT command)
0x0153d768  "Toggle tftp server on/off"   (server enable toggle)
```

These labels are referenced ONLY from this data table by direct
xref. Their handler functions (12-byte entries: label_ptr +
handler_fp + flags) are reachable only via the parent menu's
dispatcher.

## The enable flag and the access-control hook are one object

The enable flag and the per-request permission check are two
fields of a single statically-placed TFTP server object in RAM
(base `0x01AD2290`, in the BSS region above the loaded image):

```
obj+0x00   permission hook   (function pointer)
obj+0x0C   enable flag       (= 0x01AD229C, the "Transfers ... disabled" byte)
obj+0x1C   concurrent-transfer limit (handler rejects when >= 4)
```

So the flag this whole abstract is about is just field +0x0C of
the server object; the request handler reaches it both directly
(`DAT_0029d7f4`) and as `obj+0x0C`.

**The permission hook is NULL by construction.** The server
constructor (`TFTP_serverInit`, called from `TFTP_serverCreate`)
stores a hard-coded `0` into the hook field. The handler gates on
it as: if the hook is non-NULL, call `hook(server, filename)` and
refuse the transfer when it returns 0; if the hook is NULL, allow.
With NULL installed, the per-file permission check is skipped.
**However, a NULL hook does not imply VFS reach.** Hardware testing
on 2026-05-31 (modification `e80_mod001`, a previous mod since reverted)
showed the TFTP opener does
not actually resolve the requested filename and serves no files on
any volume -- see *Modification test and the file-layer dead end*
below. The earlier inference that the enable flag was the only gate
on full GET/PUT VFS access including the `\LOCAL\` flash tree is
**corrected there**.

Static analysis can show the *constructed* state is open; it
cannot rule out a later runtime write to the hook through an
indirect path. If a hook is in fact active on a running unit, it
would surface on the wire as a TFTP **ERROR packet with the
message "Transfer refused"** (emitted via the same error path as
the other refusals) -- distinct from "Transfers currently
disabled.", which is the enable-flag refusal. That distinction is
the runtime tell for which gate was hit.

(The hook comparison is a plain NULL test; the zero/low-address
compare is not a check against the `Reset` routine, and there is no
sentinel-against-reset logic.)

## Modification test and the file-layer dead end (2026-05-31)

The enable flag was force-opened on real hardware, and the result
reframes what enabling TFTP actually grants. Modification `e80_mod001`
(a previous mod, since reverted; name reused for the new mod)
patched the request handler's enable compare -- the single ARM
instruction at offset `0x0029d650`, `beq 0x0029d674` (taken only when
`*DAT_0029d7f4 == 1`), changed to an unconditional `b 0x0029d674` so
the handler always proceeds past the gate. The patched image was
rebuilt into a valid package, installed, and booted on E80-4 (build
descriptors relabeled to the builder signature + build date, visible in Unit Info;
config retained). See [modification](../deployment/modification.md).

**The enable gate works as documented.** With it open the server no
longer returns "Transfers currently disabled."; it processes RRQ and
WRQ, allocates a transfer, and replies from a fresh ephemeral TID port
(RFC 1350). (A stateful host firewall drops that TID reply as
unsolicited; a fixed local port + a narrow inbound rule are needed to
receive it -- see *Wire test tooling*.)

**But the file layer opens nothing.** Every read and write attempt
failed, on every volume tried:

| Target | Result |
|--------|--------|
| `\local\slotless\CMainApp0.lp` (all path forms: with/without `\LOCAL\`, lower/upper, fwd/back slash) | ERROR 1 "File not found" |
| CF chart-card root `CHARTCAT.XML` (all forms) | ERROR 1 "File not found" |
| plain-FAT CF card, root `test.txt` (all case/path forms) | ERROR 1 "File not found" |
| WRQ (write) of any name | ERROR 2 "Access violation" |

The opener the handler calls (`FUN_002a6014`, prior-named
"TFTP_fopen") **does not resolve the requested filename** -- its
disassembly never references the name argument. It fetches a
filesystem singleton (`FUN_005d9840`), allocates a handle, and returns
it only when a global media-ready word (`*DAT_002a60fc`) is zero, else
returns 0. That singleton is a FileX (FAT) media slot set up by
`FUN_005d95b0` ("FileX Media Semaphore"): mounted as a ~512 KB RAM
fallback named **"Baz FS"** at init, and dynamically re-mounted as
**"CF FS"** (the CF card) by a monitor thread (`FUN_005d9984`) when a
card is present. In this firmware the open never succeeds for any name
on any of these.

Consequences:

- **The TFTP file-transfer capability is effectively non-functional**
  as shipped: enabling it lets requests reach a file layer that serves
  no files.
- **Enabling TFTP does NOT grant access to `\LOCAL\`** (the Flob/NOR
  config store -- a different FileX media/driver), nor usefully to the
  CF card. The `\LOCAL\` pageset/panel backup goal is not reachable via
  TFTP.
- The modification *mechanics* are nonetheless proven end-to-end on
  hardware; only the targeted capability is a dead end.

## Parent menu and broader debug shell

The TFTP submenu is one part of a larger text-command CLI menu
structure in e80.bin. Other entries observed:

```
0x0153d214  "!command"     pass command to OS shell (per label "pass command to OS shell")
0x0153d25c  "debug"        debug submenu (likely contains the tftp submenu)
```

Additional debug strings clustered in the `0x00ca9xxx` data segment:

- `"version"` / `"display version information"`
- `"set IP stack debug tracing"`
- `"try to hook debugger"`
- `"SNMP Station: %s commands"` (SNMP client subcontext)
- The parser produces `"Unknown command: %s"` / `"Ambiguous command: %s"`
  for unrecognized input

The input source for this parser is not statically visible (menu data and error strings are referenced through
typed pointer indirection). The `UARTManager` class is present
in the firmware. No `telnet`, `ssh`, or `console` strings exist
in the firmware string set. The HTTP-shaped strings
(`"www/debug"` etc.) are consumed by an HTTP CLIENT object
(`FUN_00b62594 = HTRequest_new`, W3C libwww style), not by an
HTTP server. The HTTP server case is wire-tested: TCP port 80
on E80-4 does not respond to browser connections.

## autorun.bin TFTP

The CF-card-runtime installer `autorun.bin` (1 MB) also
contains TFTP server, TFTP client, DHCP server, and DNS server
code (same InterNicheTCPIP stack, same "Toggle tftp server on/off"
string). autorun.bin uses no CLNet / RAYDP / Flob infrastructure;
its network surface is standard DHCP+TFTP only. autorun.bin is the
runtime for the firmware-update CF card -- it executes when the CF
is inserted at boot, instead of the normal e80.bin firmware.

## ThreadX Debug Screen (separate surface)

A second debug surface in e80.bin is UI-accessible without UART
access. The watchdog handler `FUN_00171c54` displays a screen
including a Raymarine support phone number, then prompts
`"Press SoftKey 2 for ThreadX Debug or OK to reset unit"`. SoftKey 2
enters `FUN_00173640` -- the ThreadX Debug main loop. F1..F5
navigate to RTOS-internal screens (Threads / Mutex / Semaphores /
Events / Sockets). This surface does not contain navigation to the
text-command CLI menu structure with the TFTP toggle.

Tested 2026-05-28: holding SoftKey 2 during a normal boot did NOT
enter ThreadX Debug. The prompt appears only when the watchdog
runs with `*param_1 == 1`.

## E80 hardware schematic (per Sheet 14 inspection)

Source: the Raymarine E-Series service manual.

**Sheet 8** ("E80 CPU/PSU - Ethernet and Serial Interface,"
drawing 4598-011c) contains marine serial protocols only
(Ethernet, ST, NMEA0183, NMEA2000). No UART/RS-232 debug header
is shown on the production schematic.

**Sheet 14** ("E80 CPU/PSU - Misc Pandora," drawing 4598-011c)
shows a JTAG block with:

- **3M 2520-6002 connector** (20-pin / 2x10 right-angle shrouded
  box header) wired to the Pandora SoC's JTAG TAP
- Six JTAG signals: `nTRST`, `TDI`, `TMS`, `TCK`, `TDO`, `nSRST`
- Pull-up resistors on the signal lines (R073 etc., 4K7 typical)
- Test points TP12, TP25, TP26, TP27, TP4 on individual signals
- Annotation: "SIGNAL USED BY MULTI ICE" (ARM Ltd.'s original
  JTAG debugger product)

The 3M 2520-6002 is the de-facto-standard ARM 20-pin JTAG
connector. Standard pinout:

```
 1  VTref       2  Vsupply / NC
 3  nTRST       4  GND
 5  TDI         6  GND
 7  TMS         8  GND
 9  TCK        10  GND
11  RTCK       12  GND
13  TDO        14  GND
15  nSRST      16  GND
17  DBGRQ/NC   18  GND
19  DBGACK/NC  20  GND
```

The signal set in the schematic (`nTRST`, `TDI`, `TMS`, `TCK`,
`TDO`, `nSRST`) maps to canonical pins 3, 5, 7, 9, 13, 15.

Not yet determined empirically:
- Whether JTAG access is electrically disabled in production
- Pandora SoC's actual response to a standard ARM JTAG probe

Externally confirmed:
- The 2x10 0.1" pitch JTAG pad footprint is present on production
  PCBs but UNPOPULATED (per eBay listings of bare E80 motherboards
  with high-resolution photos). A 2x10 2.54mm shrouded box header
  would need to be soldered in to use the footprint.
- Repair-community references describe E80 JTAG/BDM use for
  hardware-level unbricking, consistent with JTAG being
  electrically enabled in production silicon.
- No public software utilities for flashing the E80 over JTAG
  appear to exist.

## Wire test tooling

A TFTP RRQ/GET probe sends a read request and, if the server streams DATA, runs
the full RFC 1350 read transfer (locks the server TID, ACKs each block, writes
the file out); a single-block WRQ/PUT probe completes the pair. Both bind a FIXED local UDP port (9973) and take
`[remote_path] [ip]` (default IP 10.0.166.121).

Host prerequisite (Windows): the server's transfer reply comes from a
new ephemeral TID port, which a stateful firewall drops as
unsolicited. The standing inbound rule `_prh_src_e80_TFTP` (allow UDP
9973, private networks) lets it through.

Response classification table:

| Server response | Meaning |
|-----------------|---------|
| ERROR "Transfers currently disabled." | listener up, toggle flag is 0 |
| ERROR code 1 "File not found"          | listener up, toggle flag is 1, file missing |
| ERROR code 0 "Transfer refused"        | listener up, toggle flag is 1, access-control hook denied path |
| DATA block 1                            | listener up, toggle flag is 1, file exists |
| (no response in 3 seconds)              | listener not bound on this E80 |

**2026-05-31 update:** these are the *protocol-level* meanings. On real
hardware with the flag forced on, the "DATA block" and "Transfer
refused" rows are not actually reachable -- every read returns ERROR 1
and every write ERROR 2, because the opener serves no files (see
*Modification test and the file-layer dead end*).

---

**Next:** [Home](readme.md) ...
