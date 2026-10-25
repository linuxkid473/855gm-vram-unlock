#!/usr/bin/env python3
"""Build the BeOS VBIOS-patch USB image.

    ./build.py            -> build/usb.img          (the real stick image)
    ./build.py --test     -> build/usb-test.img     (adds FAKEVB.BIN + serial debug)

Layout of the image (512-byte sectors):
    LBA 0            MBR (boot.asm) + partition table
    LBA 1..40        stage (stage.asm)
    LBA 2048..       FAT16 volume "BEOSPATCH" holding the files below

The stage addresses every file by absolute LBA (build/layout.inc), so the
FAT16 volume is written once here and never modified by the stub; the files
are pre-allocated, contiguous and just get their data overwritten.
"""
import argparse
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "build")

SECTOR = 512
STAGE_SECTORS = 40
PART_LBA = 2048
IMG_SECTORS = 49152                 # 24 MiB
PART_SECTORS = IMG_SECTORS - PART_LBA
SPC = 4                             # sectors per cluster
RESERVED = 1
NFATS = 2
ROOT_ENTRIES = 512
ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR
VOLUME = b"BEOSPATCH  "

RUN_SECTORS = 128                   # 64 KiB per run log
VB_SECTORS = 128                    # 64 KiB VBIOS dump

DEFAULT_CONFIG = """BEOSVBIOS-CONFIG-1
# keys explained in README.TXT; change with tools/setconfig.py
PATCH=0
MODE=0
SRC=0
BPP=0
TESTSET=1
AUTOBOOT=0
PAUSE=1
BOOTDRV=0
FAKEVB=0
BOOTSEL=0
VMEM=4096
SELFTEST=1
PART=0
"""
assert len(DEFAULT_CONFIG) < 400

README = """BEOSPATCH - BeOS 855GM VBIOS patch stick

Boot the Dell Inspiron 510m from this stick. It logs everything to the files
on this volume and then chain-loads the internal disk (BeOS).

  COUNTER.TXT   boot counter; latest log is RUN<counter mod 4>.LOG
  RUN0-3.LOG    text logs of the last four boots
  VBIOS_A.BIN   64 KB dump of the VBIOS (C000:0000) before any patch
  VBIOS_B.BIN   same, after the patch (only written when a patch ran)
  CONFIG.TXT    settings; change them with tools/setconfig.py, not by hand
                  (one 512-byte sector, edited in place)

CONFIG keys:
  PATCH   0/1  apply the VBIOS mode-table patch before booting
  MODE    hex  table mode number to modify (see "mode table" in RUNn.LOG)
  SRC     hex  copy the resolution record of this mode into MODE (0 = keep)
  BPP     dec  set bits per pixel of MODE (0 = keep)
  TESTSET 0/1  try VBE set-mode on every 1024x768 mode (logged)
  AUTOBOOT sec seconds before the menu auto-selects B (0 = wait for a key)
  PAUSE   0/1  wait for a key after patching, before booting
  BOOTDRV hex  force the BIOS drive number to boot (0 = auto)
  BOOTSEL 0/1/2 what B / auto-boot does: 0 hard disk, 1 CD/DVD (El Torito), 2 hand back to BIOS (INT 18h)
  VMEM    dec  KB of video memory the patch gives the VBIOS (and hides from the OS)
  PART    dec  0 = H chains the disk's MBR; 1-4 = H chains that partition's own boot sector (MBR untouched)
  SELFTEST 0/1 after PATCH, show full-screen 1024x768x32 bars before booting
  FAKEVB  0/1  test builds only: use FAKEVB.BIN instead of the real VBIOS

Eject cleanly from the Mac before booting the laptop.
"""


def fat_geometry():
    fatsz = 1
    while True:
        data = PART_SECTORS - RESERVED - NFATS * fatsz - ROOT_SECTORS
        clusters = data // SPC
        need = (clusters + 2) * 2
        needed_sectors = (need + SECTOR - 1) // SECTOR
        if needed_sectors <= fatsz:
            return fatsz, clusters
        fatsz = needed_sectors


def dos_date(y, m, d):
    return ((y - 1980) << 9) | (m << 5) | d


def build_files(test):
    spaces = lambda n: b" " * n
    counter = (b"0000 boot counter, BeOS VBIOS patch. latest log = RUN(counter mod 4).LOG\n"
               .ljust(SECTOR - 1, b" ") + b"\n")
    cfg = DEFAULT_CONFIG.encode().ljust(SECTOR - 1, b" ") + b"\n"
    files = [
        ("README", "TXT", README.encode()),
        ("COUNTER", "TXT", counter),
        ("CONFIG", "TXT", cfg),
    ]
    for i in range(4):
        files.append(("RUN%d" % i, "LOG", spaces(RUN_SECTORS * SECTOR)))
    files.append(("VBIOS_A", "BIN", bytes(VB_SECTORS * SECTOR)))
    files.append(("VBIOS_B", "BIN", bytes(VB_SECTORS * SECTOR)))
    if test:
        files.append(("FAKEVB", "BIN", fake_vbios()))
    return files


def fake_vbios():
    """64 KiB pretend VBIOS with a plausible 855GM-style (type 1) mode table."""
    img = bytearray(0x10000)
    img[0:3] = b"\x55\xAA\x80"
    img[0x20:0x30] = b"Intel Corp FAKE\x00"
    records = {}
    pos = 0x0800

    def rec(x, y):
        nonlocal pos
        key = (x, y)
        if key in records:
            return records[key]
        htot, vtot = x + 320, y + 40
        clock = (htot * vtot * 60) // 10000
        blob = struct.pack("<HBBBBBB", clock, x & 0xFF, (htot - x) & 0xFF,
                           (((htot - x) >> 8) & 0x0F) | ((x >> 4) & 0xF0),
                           y & 0xFF, (vtot - y) & 0xFF,
                           (((vtot - y) >> 8) & 0x0F) | ((y >> 4) & 0xF0))
        img[pos:pos + 8] = blob
        records[key] = pos
        pos += 8
        return records[key]

    modes = [
        (0x30, 8, 640, 480), (0x32, 16, 640, 480), (0x34, 32, 640, 480),
        (0x36, 8, 800, 600), (0x38, 16, 800, 600), (0x3A, 32, 800, 600),
        (0x3C, 8, 1024, 768), (0x3D, 16, 1024, 768), (0x41, 32, 1024, 768),
        (0x43, 16, 1280, 1024),
    ]
    tab = 0x0300
    for i, (m, bpp, x, y) in enumerate(modes):
        img[tab + i * 5: tab + i * 5 + 5] = struct.pack("<BBHB", m, bpp, rec(x, y), 0)
    img[tab + len(modes) * 5] = 0xFF
    return bytes(img)


def make_fat(files, label_date=dos_date(2026, 10, 25)):
    fatsz, clusters = fat_geometry()
    data_start = PART_LBA + RESERVED + NFATS * fatsz + ROOT_SECTORS
    fat = bytearray(fatsz * SECTOR)
    struct.pack_into("<HH", fat, 0, 0xFFF8, 0xFFFF)

    root = bytearray(ROOT_SECTORS * SECTOR)
    root[0:11] = VOLUME
    root[11] = 0x08
    struct.pack_into("<H", root, 24, label_date)

    data = bytearray()
    lbas = {}
    nxt = 2
    for idx, (name, ext, content) in enumerate(files):
        nclus = max(1, (len(content) + SPC * SECTOR - 1) // (SPC * SECTOR))
        for c in range(nclus):
            struct.pack_into("<H", fat, (nxt + c) * 2, nxt + c + 1 if c < nclus - 1 else 0xFFFF)
        ent = bytearray(32)
        ent[0:11] = name.ljust(8).encode() + ext.ljust(3).encode()
        ent[11] = 0x20
        struct.pack_into("<H", ent, 24, label_date)   # last write date
        struct.pack_into("<H", ent, 26, nxt)
        struct.pack_into("<I", ent, 28, len(content))
        root[(idx + 1) * 32:(idx + 2) * 32] = ent
        lbas[name + "." + ext] = data_start + (nxt - 2) * SPC
        data += content.ljust(nclus * SPC * SECTOR, b"\0")
        nxt += nclus
    assert nxt - 2 <= clusters, "files do not fit in the FAT volume"

    vbr = bytearray(SECTOR)
    vbr[0:3] = b"\xEB\x3C\x90"
    vbr[3:11] = b"BEOSVBP "
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, SECTOR, SPC, RESERVED, NFATS,
                     ROOT_ENTRIES, PART_SECTORS, 0xF8, fatsz, 63, 255, PART_LBA, 0)
    vbr[36] = 0x80
    vbr[38] = 0x29
    struct.pack_into("<I", vbr, 39, 0xBE05B105)
    vbr[43:54] = VOLUME
    vbr[54:62] = b"FAT16   "
    vbr[510:512] = b"\x55\xAA"

    part = bytes(vbr) + bytes(fat) + bytes(fat) + bytes(root) + bytes(data)
    return part, lbas


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit("command failed: " + " ".join(cmd))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", action="store_true",
                    help="add FAKEVB.BIN and build the stage with serial debug output")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    files = build_files(args.test)
    part, lbas = make_fat(files)

    def L(n):
        return lbas[n]

    inc = [
        "STAGE_SECTORS equ %d" % STAGE_SECTORS,
        "PART_LBA equ %d" % PART_LBA,
        "PART_SECTORS equ %d" % PART_SECTORS,
        "RUN_SECTORS equ %d" % RUN_SECTORS,
        "COUNTER_LBA equ %d" % L("COUNTER.TXT"),
        "CONFIG_LBA equ %d" % L("CONFIG.TXT"),
        "VBA_LBA equ %d" % L("VBIOS_A.BIN"),
        "VBB_LBA equ %d" % L("VBIOS_B.BIN"),
    ]
    for i in range(4):
        inc.append("RUN%d_LBA equ %d" % (i, L("RUN%d.LOG" % i)))
    inc.append("FAKEVB_LBA equ %d" % (L("FAKEVB.BIN") if args.test else 0))
    with open(os.path.join(OUT, "layout.inc"), "w") as f:
        f.write("\n".join(inc) + "\n")

    flags = ["-DSERIAL"] if args.test else []
    run(["nasm", "-f", "bin", "-I", OUT + "/", *flags, os.path.join(SRC, "boot.asm"),
         "-o", os.path.join(OUT, "boot.bin"), "-l", os.path.join(OUT, "boot.lst")])
    run(["nasm", "-f", "bin", "-I", OUT + "/", *flags, os.path.join(SRC, "stage.asm"),
         "-o", os.path.join(OUT, "stage.bin"), "-l", os.path.join(OUT, "stage.lst")])

    boot = open(os.path.join(OUT, "boot.bin"), "rb").read()
    stage = open(os.path.join(OUT, "stage.bin"), "rb").read()
    assert len(boot) == 512, "boot sector is %d bytes" % len(boot)
    assert len(stage) <= STAGE_SECTORS * SECTOR, \
        "stage is %d bytes, limit %d" % (len(stage), STAGE_SECTORS * SECTOR)

    img = bytearray(IMG_SECTORS * SECTOR)
    img[0:512] = boot
    img[512:512 + len(stage)] = stage
    img[PART_LBA * SECTOR:PART_LBA * SECTOR + len(part)] = part
    name = "usb-test.img" if args.test else "usb.img"
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(img)
    print("stage: %d bytes (limit %d)" % (len(stage), STAGE_SECTORS * SECTOR))
    print("wrote", os.path.join(OUT, name))


if __name__ == "__main__":
    main()
