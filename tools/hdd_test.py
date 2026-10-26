#!/usr/bin/env python3
"""End-to-end tests of the hard-disk loader in QEMU.

Needs ./build.py --test first. Builds a fake internal disk laid out like the real one (an
active Windows-type partition at sector 63, a BeOS-type partition later, an empty gap before
sector 63, a plain 'boot the active partition' MBR), then:

  install        stick + disk: press I, type INSTALL; check every byte written
  boot           disk alone: the loader menu, default path -> ZETA partition (patch hooks live)
  windows        disk alone, press W -> original MBR -> Windows partition
  never-writes   the disk image is byte-identical after the boot tests
  fallback       loader sectors corrupted -> the MBR falls back to the original MBR
  shift          SHIFT held at power-on skips the loader (best effort: QEMU key timing)
  uninstall      stick + installed disk: press U, type UNINSTALL; disk identical to the original
  refusals       gap not empty / partition inside the gap / already installed / wrong confirmation
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
WORK = os.path.join(BUILD, "hdd-test")
sys.path.insert(0, HERE)
import fatimg  # noqa: E402
from zeta_qemu import monitor  # noqa: E402

SECT = 512
STAGE_SECTORS = 56
FAILS = 0


def check(name, cond):
    global FAILS
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        FAILS += 1


def nasm(src, *flags):
    out = os.path.join(WORK, os.path.basename(src) + ".bin")
    subprocess.run(["nasm", "-f", "bin", *flags, os.path.join(ROOT, "src", src), "-o", out], check=True)
    return open(out, "rb").read()


def entry(boot, ptype, start, size):
    return bytes([boot, 0xFE, 0xFF, 0xFF, ptype, 0xFE, 0xFF, 0xFF]) + struct.pack("<II", start, size)


def make_disk(path, p1_start=63, gap_junk=False):
    mbr_code = nasm("origmbr.asm")
    d = bytearray(64 * 1024 * 1024)
    d[0:len(mbr_code)] = mbr_code
    d[0x1B8:0x1BC] = b"\x29\x00\x29\x00"
    d[0x1BE:0x1CE] = entry(0x80, 0x07, p1_start, 20000)
    d[0x1CE:0x1DE] = entry(0x00, 0xEB, 30000, 20000)
    d[510:512] = b"\x55\xAA"
    d[p1_start * SECT:(p1_start + 1) * SECT] = nasm("fakepbr.asm", "-DXP")
    d[30000 * SECT:30001 * SECT] = nasm("fakepbr.asm")
    if gap_junk:
        d[5 * SECT:5 * SECT + 16] = b"GRUB-STAGE-1.5!!"
    open(path, "wb").write(d)
    return bytes(d)


def make_stick(path):
    data = bytearray(open(os.path.join(BUILD, "usb-test.img"), "rb").read())
    fatimg.set_config(data, dict(PATCH=1, MODE=0, SRC=0, BPP=0, TESTSET=0, PAUSE=0, AUTOBOOT=0,
                                 BOOTSEL=0, SELFTEST=0, VMEM=4096, FAKEVB=1, PART=9))
    open(path, "wb").write(data)
    return bytes(data)


def keys(text):
    out = []
    for ch in text.lower():
        out.append("sendkey " + ("ret" if ch == "\n" else ch))
    return out


def run_qemu(drives, steps, total, boot="c"):
    """drives: list of image paths (index 0 first = boot). steps: [(seconds, monitor command)]."""
    tmp = tempfile.mkdtemp(prefix="hddtest-")
    sock = os.path.join(tmp, "q.sock")
    vga = os.path.join(tmp, "vga.bin")
    args = ["qemu-system-i386", "-m", "64", "-display", "none",
            "-monitor", "unix:%s,server,nowait" % sock, "-boot", boot]
    for i, p in enumerate(drives):
        args += ["-drive", "file=%s,format=raw,if=ide,index=%d" % (p, i)]
    q = subprocess.Popen(args)
    t0 = time.time()
    text = ""
    try:
        for when, cmd in steps:
            wait = when - (time.time() - t0)
            if wait > 0:
                time.sleep(wait)
            monitor(sock, [cmd], wait=0.15)
        wait = total - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        monitor(sock, ['pmemsave 0xb8000 4000 "%s"' % vga], wait=1.0)
        time.sleep(0.5)
        raw = open(vga, "rb").read()
        text = "\n".join("".join(chr(raw[(r * 80 + c) * 2]) if 32 <= raw[(r * 80 + c) * 2] < 127 else " "
                                 for c in range(80)).rstrip() for r in range(25))
    finally:
        try:
            monitor(sock, ["quit"], wait=0.2)
        except Exception:
            pass
        try:
            q.wait(8)
        except subprocess.TimeoutExpired:
            q.kill()
    return text


def typed(start, word):
    return [(start + 0.35 * i, c) for i, c in enumerate(keys(word))]


def stick_log(path):
    files = fatimg.read_files(bytearray(open(path, "rb").read()))
    n = int(files["COUNTER.TXT"][:4]) % 4
    return files["RUN%d.LOG" % n].decode("latin1")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    if not os.path.exists(os.path.join(BUILD, "usb-test.img")):
        sys.exit("run ./build.py --test first")
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    stage_hdd = open(os.path.join(BUILD, "stage_hdd.bin"), "rb").read().ljust(STAGE_SECTORS * SECT, b"\0")
    mbrhdd = open(os.path.join(BUILD, "mbrhdd.bin"), "rb").read()

    stick = os.path.join(WORK, "stick.img")
    disk = os.path.join(WORK, "disk.img")
    stick_bytes = make_stick(stick)
    orig = make_disk(disk)

    # ---------------------------------------------------------------- install
    print("== install")
    steps = [(14, "sendkey i")] + [(t, c) for t, c in typed(16, "install\n")]
    text = run_qemu([stick, disk], [(a, b) for a, b in steps], 30)
    d = open(disk, "rb").read()
    check("screen says INSTALLED", "INSTALLED" in text)
    check("new MBR code is ours (bytes 0..0x1B7)", d[:0x1B8] == mbrhdd)
    check("signature + partition table preserved byte for byte", d[0x1B8:512] == orig[0x1B8:512])
    check("loader image written to sectors 1-56", d[SECT:(1 + STAGE_SECTORS) * SECT] == stage_hdd)
    check("sectors 57-59 untouched (zero)", not any(d[57 * SECT:60 * SECT]))
    check("original MBR saved at sector 60", d[60 * SECT:61 * SECT] == orig[:SECT])
    cfg = fatimg.read_files(bytearray(stick_bytes))["CONFIG.TXT"][:SECT]
    check("stick config copied to sector 61", d[61 * SECT:62 * SECT] == cfg)
    check("marker at sector 62", d[62 * SECT:62 * SECT + 8] == b"BVBPHDD1" and not any(d[62 * SECT + 8:63 * SECT]))
    check("everything from sector 63 on is untouched", d[63 * SECT:] == orig[63 * SECT:])
    saved = fatimg.read_files(bytearray(open(stick, "rb").read()))["MBRORIG.BIN"][:SECT]
    check("original MBR also saved on the stick (MBRORIG.BIN)", saved == orig[:SECT])
    check("diagnostics report a clean gap as free", "(the gap is free)" in stick_log(stick))
    installed = d
    shutil.copy(disk, os.path.join(WORK, "installed.img"))

    # ------------------------------------------------------- boot, disk alone
    print("== boot the installed disk alone (default path)")
    text = run_qemu([os.path.join(WORK, "installed.img")], [], 22)
    print(text[-700:].replace("\n\n", "\n"))
    check("loader menu shown", "disk loader" in text)
    check("default path reached the ZETA (BeOS-type) partition's boot sector", "FAKE-PBR reached, DL=0x80" in text)
    check("DS:SI points at partition 2's entry", "SI=0x07CE" in text)
    check("memory-map hook was installed (patch ran)", "INT 15h memory-map hook installed" in text or "video RAM block" in text)

    print("== press W -> Windows")
    text = run_qemu([os.path.join(WORK, "installed.img")], [(3.5, "sendkey w")], 12)
    check("original MBR code ran", "ORIG-MBR" in text)
    check("Windows-type partition's boot sector reached", "FAKE-XP PBR reached, DL=0x80" in text)
    check("no patch lines on the Windows path", "memory-map hook installed" not in text)

    check("the disk loader never wrote to the disk (image identical after boots)",
          open(os.path.join(WORK, "installed.img"), "rb").read() == installed)

    # ------------------------------------------------- partition picker (3 systems + a 2nd BeOS)
    print("== partition picker")
    pick = bytearray(installed)
    pick[0x1BE:0x1CE] = entry(0x80, 0x07, 63, 20000)        # 1 Windows (active)
    pick[0x1CE:0x1DE] = entry(0x00, 0xEB, 30000, 20000)     # 2 ZETA
    pick[0x1DE:0x1EE] = entry(0x00, 0xAF, 40000, 10000)     # 3 Mac OS X
    pick[0x1EE:0x1FE] = entry(0x00, 0xEB, 45000, 10000)     # 4 a second BeOS-type partition
    for lba in (40000, 45000):
        pick[lba * SECT:(lba + 1) * SECT] = nasm("fakepbr.asm")
    pickp = os.path.join(WORK, "pick.img")
    open(pickp, "wb").write(pick)

    def pick_run(key, total=14):
        steps = [(3.5, "sendkey " + key)] if key else []
        return run_qemu([pickp], steps, total)

    text = pick_run(None, 20)
    check("menu lists Windows, ZETA / BeOS and Mac OS X with sizes",
          "1) Windows" in text and "2) ZETA / BeOS" in text and "3) Mac OS X" in text and "4) ZETA / BeOS" in text
          and "(active)" in text and "9 MB" in text)
    check("timeout still boots the first BeOS partition (BOOTSEL=0)", "SI=0x07CE" in text)
    text = pick_run("t")
    check("T boots the Mac OS X partition (entry 3)", "FAKE-PBR reached, DL=0x80" in text and "SI=0x07DE" in text)
    check("T applied the video patch", "memory-map hook installed" in text or "video RAM block" in text)
    text = pick_run("4")
    check("4 boots the SECOND BeOS-type partition (not the top one)", "SI=0x07EE" in text)
    text = pick_run("3")
    check("3 boots the Mac OS X partition by number", "SI=0x07DE" in text)
    text = pick_run("2")
    check("2 boots the first BeOS partition", "SI=0x07CE" in text)
    text = pick_run("z")
    check("Z boots the first BeOS partition", "SI=0x07CE" in text)
    text = pick_run("1")
    check("1 boots the Windows partition directly", "FAKE-XP PBR reached, DL=0x80" in text and "SI=0x07BE" in text)
    check("1 does not apply the video patch", "memory-map hook installed" not in text and "video RAM block" not in text)
    pick2 = bytearray(pick)
    pick2[0x1DE:0x1EE] = bytes(16)
    pick2p = os.path.join(WORK, "pick2.img")
    open(pick2p, "wb").write(pick2)
    text = run_qemu([pick2p], [(3.5, "sendkey 3")], 12)
    check("choosing an empty slot is refused and the loader keeps waiting", "that slot is empty" in text
          and "FAKE-PBR reached" not in text)
    text = run_qemu([pick2p], [(3.5, "sendkey t")], 12)
    check("T with no Mac OS X partition falls back to Windows instead of hanging",
          "no BeOS (0xEB) / Mac OS X (0xAF) partition" in text and "FAKE-XP PBR reached" in text)
    check("picker boots never wrote to the disk", open(pickp, "rb").read() == bytes(pick))

    # --------------------------------------------------------------- fallback
    print("== fallback: loader sectors corrupted")
    bad = bytearray(installed)
    bad[SECT:(1 + STAGE_SECTORS) * SECT] = bytes(STAGE_SECTORS * SECT)
    badp = os.path.join(WORK, "bad.img")
    open(badp, "wb").write(bad)
    text = run_qemu([badp], [], 10)
    check("MBR fell back to the original MBR and Windows", "ORIG-MBR" in text and "FAKE-XP PBR reached" in text)

    print("== SHIFT held at power-on (best effort)")
    # the BIOS splash pauses boot for 4 s, so SHIFT (held 1 s .. 7 s) is registered before the MBR runs
    text = run_qemu([os.path.join(WORK, "installed.img")], [(1.0, "sendkey shift 6000")], 11,
                    boot="order=c,menu=on,splash-time=4000")
    check("SHIFT held at power-on skips the loader and boots Windows via the original MBR",
          "FAKE-XP PBR reached" in text and "disk loader" not in text)
    text = run_qemu([os.path.join(WORK, "installed.img")], [], 14, boot="order=c,menu=on,splash-time=4000")
    check("control: same BIOS pause without SHIFT shows the loader", "disk loader" in text)

    # -------------------------------------------------------------- uninstall
    print("== uninstall")
    stick2 = os.path.join(WORK, "stick2.img")
    shutil.copy(stick, stick2)
    inst2 = os.path.join(WORK, "inst2.img")
    shutil.copy(os.path.join(WORK, "installed.img"), inst2)
    steps = [(14, "sendkey u")] + typed(16, "uninstall\n")
    text = run_qemu([stick2, inst2], steps, 28)
    d = open(inst2, "rb").read()
    check("screen says UNINSTALLED", "UNINSTALLED" in text)
    check("disk is byte-identical to the original again", d == orig)

    # --------------------------------------------------------------- refusals
    print("== refusals")
    cases = [
        ("partition inside the gap", dict(p1_start=32), "install\n", "before sector 63"),
    ]
    for name, kw, word, expect in cases:
        p = os.path.join(WORK, "refuse.img")
        before = make_disk(p, **kw)
        st = os.path.join(WORK, "stick3.img")
        shutil.copy(stick, st)
        text = run_qemu([st, p], [(14, "sendkey i")] + typed(16, word), 26)
        check("refuses: " + name, expect in text)
        check("   disk unchanged", open(p, "rb").read() == before)

    # non-empty gap: lists it, asks for OVERWRITE; declining leaves the disk alone, accepting backs it up first
    print("== non-empty gap (leftovers)")
    p = os.path.join(WORK, "junk.img")
    before = make_disk(p, gap_junk=True)
    st = os.path.join(WORK, "stick4.img")
    shutil.copy(stick, st)
    text = run_qemu([st, p], [(14, "sendkey i")] + typed(16, "install\n") + typed(19, "nope\n"), 28)
    check("non-empty gap is listed with its first bytes (installer output in the stick log)",
          "LBA 5:" in stick_log(st) and "GRUB-STAG" in stick_log(st))
    check("declining OVERWRITE cancels", "cancelled" in text)
    check("   disk unchanged", open(p, "rb").read() == before)
    check("   stick log shows the gap dump", "1 not empty - LBA: 5" in stick_log(st) and "GRUB-STAGE-1.5!!" in stick_log(st))
    p2 = os.path.join(WORK, "junk2.img")
    shutil.copy(os.path.join(WORK, "junk.img"), p2)
    st2 = os.path.join(WORK, "stick5.img")
    shutil.copy(stick, st2)
    text = run_qemu([st2, p2], [(14, "sendkey i")] + typed(16, "install\n") + typed(19, "overwrite\n"), 36)
    d2 = open(p2, "rb").read()
    check("typing OVERWRITE installs", "INSTALLED" in text and d2[:0x1B8] == mbrhdd)
    gb = fatimg.read_files(bytearray(open(st2, "rb").read()))["GAPBACK.BIN"]
    check("the old sectors 1-62 were saved on the stick first (GAPBACK.BIN)", gb[:62 * SECT] == before[SECT:63 * SECT])
    check("partition table still byte-identical", d2[0x1B8:512] == before[0x1B8:512])
    check("nothing after sector 62 touched", d2[63 * SECT:] == before[63 * SECT:])
    p = os.path.join(WORK, "refuse.img")
    shutil.copy(os.path.join(WORK, "installed.img"), p)
    text = run_qemu([stick, p], [(14, "sendkey i")] + typed(16, "install\n"), 26)
    check("refuses: already installed", "already installed" in text)
    check("   disk unchanged", open(p, "rb").read() == installed)
    p = os.path.join(WORK, "refuse.img")
    before = make_disk(p)
    text = run_qemu([stick, p], [(14, "sendkey i")] + typed(16, "nope\n"), 24)
    check("wrong confirmation cancels", "cancelled" in text)
    check("   disk unchanged", open(p, "rb").read() == before)

    print("\n%s" % ("ALL PASSED" if not FAILS else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
