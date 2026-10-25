# 855gm-vram-unlock

**Real 16/32-bit VESA modes on Intel 852/855GM laptops that only give the video chip ~1 MB of memory.**
A tiny real-mode boot stub that applies the *855patch* trick **before** the OS loader runs, so BeOS-family
systems (tested with **ZETA 1.21**) can use 1024x768 in more than 8-bit colour. Built and tested on a
Dell Inspiron 510m.

```
BIOS offers (stock)                         with the stub
  VBE memory      832 KB                      4096 KB
  1024x768        8-bit only                  8 / 16 / 32-bit modes offered and set
```

> **Status:** works on the author's Dell Inspiron 510m (BIOS A07). ZETA's loader boots with the patch live and
> offers 1024x768x16. A full-screen 1024x768x32 test pattern displays correctly on the LCD. Everything else
> is emulator-tested only. This pokes chipset registers and installs resident BIOS hooks: **use at your own
> risk**, and read [Safety](#safety).

## The problem

The 855GM reserves ~1 MB of system RAM as video memory and the Dell BIOS offers no setting to change it. The
VESA BIOS therefore reports 832 KB of video memory and hides every mode that does not fit, so a BeOS/ZETA
VESA boot is stuck at 1024x768 **8-bit** (or 640x480x16). Linux works around this with a driver that
allocates more memory through the chip's GTT; BeOS-family VESA drivers cannot.

## How it works

1. **Open A20.** Booting from USB leaves the A20 gate closed on this BIOS, so any access above 1 MB wraps. The
   stub opens it (INT 15h/2401, port 0x92, then the keyboard controller) and verifies.
2. **Raise the VBIOS memory register.** The VBIOS decides which modes fit from the upper word of MMIO
   `0x71414` (4 KB pages), read fresh on every VBE call. The stub reaches MMIO through the IGD's I/O BAR
   (index/data pair) and raises it (default 4096 KB). That alone makes the 16/32-bit modes appear and set.
3. **Back the extra memory with real RAM.** Display fetches and CPU aperture accesses above 896 KB go
   through the GTT, which the CPU cannot reach by physical address (the chip's memory reads `0xFFFFFFFF`).
   Entries are written through the MMIO window (BAR1 + `0x10000`) and point at a block taken from the top
   of the usable E820 range.
4. **Hide that RAM from the OS** with a resident INT 15h hook (E820 / E801 / 88h) that trims the top usable entry.
5. **Survive mode sets.** The VBIOS clears the GTT on every mode set and OS loaders set their mode *after*
   the stub, so a resident INT 10h hook refills the GTT after every successful VBE set-mode (port I/O only).
6. **Hand over.** The stub then boots something: hand back to the BIOS (INT 18h), chain a disc, chain the
   internal disk's MBR (with an INT 13h drive-number swap), or chain one partition's own boot sector.

The stub also logs everything (PCI, VBIOS, VBE, E820, partition table...) to plain files on the stick's FAT16
volume, so you can read what happened on the target machine by plugging the stick into another computer.

## Quick start

Needs Python 3 and NASM. QEMU is only needed for the tests.

```bash
./build.py                      # builds build/usb.img
./flash.sh                      # lists external disks (never offers internal ones)
./flash.sh disk4                # ERASES that stick and writes the image (asks you to retype the id)
python3 tools/setconfig.py PATCH=1 VMEM=4096 SELFTEST=1 BOOTSEL=2   # edit CONFIG.TXT on the mounted stick
```

1. **First boot: diagnose only.** The default config is `PATCH=0`. Boot the stick, let it run, power off at the
   menu. Then `python3 tools/showlog.py` prints the log (stick mounted as `BEOSPATCH`).
2. **Boot a disc with the patch live** (e.g. an OS installer): choose **X**. It patches, then executes INT 18h so the
   BIOS boots the next device. Gotcha found the hard way: this BIOS's INT 18h **restarts the boot sequence from the
   top of its list**, so set Setup's order to CD/DVD first and pick the stick with F12.
3. **Boot an installed system**: set `PART=9` (first BeOS-type partition) or `PART=1..4`, `BOOTSEL=0`, then **H**.
   The MBR is never modified; the partition's boot sector is loaded the way an MBR would. **N** boots the MBR
   without the patch (Windows); removing the stick boots whatever the BIOS would normally boot.

### Menu keys

| key | action |
|---|---|
| H | patch (if `PATCH=1`) then boot the hard disk; honours `PART` |
| N | boot the disk's MBR, no patch |
| X / Y | patch / no patch, then hand back to the BIOS (INT 18h) |
| C / D | patch / no patch, then load a no-emulation El Torito disc ourselves |
| B | default action per `BOOTSEL` (0 disk, 1 CD, 2 hand-back) |
| T, M, K, Q | diagnostics: VBE mode test, memory probe, on-screen test pattern, chip state capture |
| I | **install the loader on the internal hard disk** (see below) |
| U | uninstall it again (restores the original boot sector) |
| R | reboot |

### CONFIG.TXT keys

`PATCH` 0/1 · `VMEM` KB of video memory to give the VBIOS (and hide from the OS) · `SELFTEST` 0/1 show a
full-screen pattern after patching · `BOOTSEL` 0/1/2 · `PART` 0 = MBR, 1-4, or 9 = first BeOS partition ·
`AUTOBOOT` seconds before the default action runs (0 = wait for a key) · `PAUSE` · `TESTSET` · `BOOTDRV` ·
`MODE`/`SRC`/`BPP` optional mode-table entry rewrite (rarely needed; the memory register was the real fix) ·
`FAKEVB` test builds only. Edit the file only with `tools/setconfig.py`: it must stay one 512-byte sector in place.

## Run without the stick: install the loader on the hard disk

Optional. The stick's installer (menu key **I**) puts a copy of the loader in the unused sectors in front of
the first partition (a normal MBR disk leaves sectors 1-62 empty because the first partition starts at 63) and
replaces the MBR's *boot code* only. After that the machine shows a small menu at power-on:

```
855gm-vram-unlock disk loader
 Z or Enter = ZETA / BeOS (video patch)     W = Windows
 default in 5 seconds. Hold SHIFT at power-on to skip this loader.
```

**Z** applies the patch and boots the first BeOS-type (0xEB) partition's own boot sector (`PART` selects another);
**W** boots the original MBR code with the current partition table, unpatched. The loader reads its settings from
the config the stick had at install time (set `PATCH=1 VMEM=4096 PART=9` first; `AUTOBOOT=0` becomes 5 seconds,
`BOOTSEL=1` makes Windows the default).

What the install writes (disk layout, sectors):

| sector | content |
|---|---|
| 0 | MBR: new boot code (440 bytes) + the disk's **original signature and partition table, byte for byte** |
| 1-56 | the disk loader (`stage_hdd.bin`) |
| 60 | a copy of the **original MBR** |
| 61 | the loader's config |
| 62 | marker `BVBPHDD1` |

Everything from sector 63 onward is never touched. Order of operations: type `INSTALL` to confirm, check the disk
(valid MBR, every partition starts at or after sector 63, sectors 1-62 all zero, not already installed), save the
original MBR to the stick (`MBRORIG.BIN`), write sectors 1-62 and **read them back and compare**, and only then
write the new MBR and read that back too. Until that last write the disk boots exactly as before, and every
refusal leaves the disk untouched. During install the stick may write only to sectors 0-62 of the target disk.

**Ways out, in order of how bad things are**

1. Hold **SHIFT** (or Ctrl/Alt) at power-on: the MBR skips the loader and boots the original MBR code.
2. If the loader sectors cannot be read, or do not carry the loader's signature, the MBR falls back to the original
   MBR by itself.
3. Boot the stick and press **U**, type `UNINSTALL`: restores the original code (keeping the *current* partition
   table) and clears sectors 1-62. The test suite checks the disk is byte-identical afterwards.
4. Without the stick: restore only the 440 code bytes from the saved copy, e.g. on Linux
   `dd if=MBRORIG.BIN of=/dev/sdX bs=440 count=1 conv=notrunc` (never write more than 440 bytes: the rest is the
   partition table), or run `fixmbr` from a Windows XP recovery console.

The disk loader is built from the same source with `-DHDDMODE`: it never writes to any disk (the write path is
compiled out), does no logging and no diagnostics. If you resize partitions later, keep partition 1 starting at or
after sector 63 and keep sectors 1-62 free, or uninstall first.

Caveat: some BIOSes have a boot-sector virus warning that blocks writes to sector 0. The installer then reports
the failure and the disk still boots as before (the earlier sectors are written first).

## Safety

- The patch only runs if the host bridge is `8086:3580` (82855GM), A20 is open, an I/O BAR exists, and there is room
  at the top of RAM; otherwise it refuses.
- Disk writes go **only** to the stick: refused for any other drive number and once the INT 13h swap hook is live;
  the stick layout is verified before the first write. Other disks (including the internal one) are only read.
- `flash.sh` refuses internal or non-external disks and anything over 128 GB or under 32 MB.
- Every register it touches is a scratch/GTT register that a power cycle clears; nothing is flashed.
- Known hazard: resizing the chipset's real stolen-memory size at run time (`GCC1`) blanks the display. It is
  documented in `logs/02-gms-experiment.log` and removed from the code.

## Tests

`./build.py --test` builds an image with a synthetic VBIOS (`FAKEVB=1`, never in real builds). Then
`tools/qemu_test.py [--cd|--int18|--vmem|--gfx|--a20|--diag|--probe|--part|--part9]` boots it in QEMU with a fake
internal disk / CD and checks: drive-swap hook, E820 trimming (exactly the hidden size), the INT 10h hook passing
set-mode through, A20 opening after being closed, pixel-exact colour bars through the 4 GB-addressing code, patched
VBIOS bytes against an independent Python simulation (`tools/vbios_tool.py`), and partition chaining.
`tools/zeta_qemu.py` boots a real disc image through the stick and screenshots it (it matches an unpatched control).
`./build.py --test && tools/hdd_test.py` runs the hard-disk loader end to end on a fake disk laid out like a real one: install
(every byte checked), boot alone, the W path, a read-only disk, fallback from a corrupted loader, SHIFT bypass, uninstall back to a
byte-identical disk, and refusals (gap not empty, partition inside the gap, already installed, wrong confirmation).

## Findings that may help others (Intel 855GM, Dell BIOS A07)

- Booting from USB leaves **A20 closed**: unreal-mode accesses above 1 MB silently wrap.
- The CPU reads the chip's stolen memory as `0xFFFFFFFF`; the GTT must be written through the MMIO window.
- The GTT window reads back zero but the writes take effect. `PGTBL_ER` (0x2024) is sticky.
- The VBIOS clears the GTT on every VBE mode set.
- The BIOS does not expose the optical drive through INT 13h while booting from USB; hand back with INT 18h instead.
- This BIOS's INT 18h restarts the boot sequence rather than continuing to the next device.
- ZETA 1.21's fail-safe video menu lists only **16-bit** modes, so 16-bit is the ceiling through its VESA path. The
  disc boots with El Torito **floppy emulation** (media type 2), which the stub does not emulate.
- The chip has no packed 24-bit mode; "24-bit" means 32 bpp.

`logs/` has the real runs behind each finding.

## Limitations

Only tested on a Dell Inspiron 510m (855GM, BIOS A07) with ZETA 1.21. Other 852/855GM machines may need different
PAM/GTT behaviour; other chipsets are refused. The firmware dumps used during development are not published.

## Credits

The idea comes from **855patch** by Christian Zietz (the VBIOS memory-size trick) and the mode-table scanning from
**915resolution** / Syslinux (H. Peter Anvin). This code was written from scratch against hardware logs.
Tested with GParted Live for the disk resize.

## License

MIT, see [LICENSE](LICENSE).
