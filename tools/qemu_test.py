#!/usr/bin/env python3
"""End-to-end test of the stick image under QEMU.

Boots build/usb-test.img as the first disk and a fake "internal" disk as the
second, lets the stage run (config: FAKEVB=1 PATCH=1 ...), then
  * screenshots the VGA text buffer through the QEMU monitor,
  * reads the logs / dumps back out of the image,
  * checks the patched VBIOS dump against tools/vbios_tool.py's simulation.
"""
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
sys.path.insert(0, HERE)
import fatimg  # noqa: E402
import vbios_tool  # noqa: E402

TEST_CONFIG = dict(PATCH=1, MODE="3A", SRC="41", BPP=32, TESTSET=1,
                   AUTOBOOT=2, PAUSE=0, FAKEVB=1)
SCENARIO = ("part" if "--part" in sys.argv or "--part9" in sys.argv else "vmem" if "--vmem" in sys.argv else "diag" if "--diag" in sys.argv else "a20" if "--a20" in sys.argv else "gfx" if "--gfx" in sys.argv else "probe" if "--probe" in sys.argv else "int18" if "--int18" in sys.argv else ("cd" if "--cd" in sys.argv else "hd"))
if SCENARIO == "cd":
    TEST_CONFIG["BOOTSEL"] = 1
if SCENARIO == "int18":
    TEST_CONFIG["BOOTSEL"] = 2
if SCENARIO in ("probe", "gfx", "a20", "diag"):
    TEST_CONFIG.update(AUTOBOOT=0, TESTSET=0, PATCH=0)
if SCENARIO == "a20":
    TEST_CONFIG["FAKEVB"] = 2
if SCENARIO == "part":
    TEST_CONFIG.update(PATCH=1, MODE=0, SRC=0, BPP=0, TESTSET=0, PAUSE=0, AUTOBOOT=2, BOOTSEL=0, SELFTEST=0, VMEM=4096, FAKEVB=1, PART=9 if "--part9" in sys.argv else 2)
if SCENARIO == "vmem":
    TEST_CONFIG.update(PATCH=1, MODE=0, SRC=0, BPP=0, TESTSET=0, PAUSE=0, AUTOBOOT=2, BOOTSEL=0, SELFTEST=1, VMEM=4096, FAKEVB=1)


def make_fakecd(path):
    """No-emulation El Torito ISO whose boot image prints its load registers."""
    import shutil
    d = path + ".dir"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    subprocess.run(["nasm", "-f", "bin", os.path.join(ROOT, "src", "fakecd.asm"),
                    "-o", os.path.join(d, "BOOT.IMG")], check=True)
    if os.path.exists(path):
        os.remove(path)
    subprocess.run(["hdiutil", "makehybrid", "-o", path, "-iso", "-eltorito-boot",
                    os.path.join(d, "BOOT.IMG"), "-no-emul-boot", "-boot-load-size", "4",
                    d], check=True, capture_output=True)
    if not path.endswith(".iso") and os.path.exists(path + ".iso"):
        os.rename(path + ".iso", path)


def make_fakehd(path):
    subprocess.run(["nasm", "-f", "bin", os.path.join(ROOT, "src", "fakehd.asm"),
                    "-o", path + ".mbr"], check=True)
    disk = bytearray(1024 * 1024)
    disk[0:512] = open(path + ".mbr", "rb").read()
    disk[512:518] = b"FAKEHD"
    # partition 2: BeOS type 0xEB at LBA 100, with its own boot sector
    subprocess.run(["nasm", "-f", "bin", os.path.join(ROOT, "src", "fakepbr.asm"), "-o", path + ".pbr"], check=True)
    import struct as _st
    disk[0x1BE + 16:0x1BE + 32] = bytes([0, 0xFE, 0xFF, 0xFF, 0xEB, 0xFE, 0xFF, 0xFF]) + _st.pack("<II", 100, 1000)
    disk[100 * 512:100 * 512 + 512] = open(path + ".pbr", "rb").read()
    open(path, "wb").write(disk)


def monitor(sock_path, cmds, wait=0.3):
    s = socket.socket(socket.AF_UNIX)
    for _ in range(50):
        try:
            s.connect(sock_path)
            break
        except OSError:
            time.sleep(0.1)
    s.settimeout(1)
    try:
        s.recv(4096)
    except OSError:
        pass
    for c in cmds:
        s.sendall(c.encode() + b"\n")
        time.sleep(wait)
        try:
            s.recv(65536)
        except OSError:
            pass
    s.close()


def screen_text(path):
    raw = open(path, "rb").read()
    rows = []
    for r in range(25):
        rows.append("".join(chr(raw[(r * 80 + c) * 2]) if raw[(r * 80 + c) * 2] >= 32 else " "
                            for c in range(80)).rstrip())
    return "\n".join(rows).rstrip()


def main():
    img = os.path.join(BUILD, "usb-test.img")
    work = os.path.join(BUILD, "qemu-run.img")
    fakehd = os.path.join(BUILD, "fakehd.img")
    if not os.path.exists(img):
        sys.exit("run ./build.py --test first")
    make_fakehd(fakehd)
    cdiso = os.path.join(BUILD, "fakecd.iso")
    if SCENARIO in ("cd", "int18"):
        make_fakecd(cdiso)
    data = bytearray(open(img, "rb").read())
    fatimg.set_config(data, TEST_CONFIG)
    open(work, "wb").write(data)

    tmp = tempfile.mkdtemp(prefix="beosvbp-")     # no spaces: monitor parsing
    sock = os.path.join(tmp, "qemu.sock")
    vga = os.path.join(tmp, "vga.bin")
    serial = os.path.join(BUILD, "serial.txt")
    for p in (sock, vga, serial):
        if os.path.exists(p):
            os.remove(p)
    q = subprocess.Popen([
        "qemu-system-i386", "-m", "64", "-display", "none",
        "-monitor", "unix:%s,server,nowait" % sock,
        "-serial", "file:%s" % serial,
        "-drive", "file=%s,format=raw,if=ide,index=0" % work,
        "-drive", "file=%s,format=raw,if=ide,index=1" % fakehd,
        *(["-drive", "file=%s,format=raw,media=cdrom,if=ide,index=2" % cdiso] if SCENARIO in ("cd", "int18") else []),
        "-boot", "order=cd" if SCENARIO == "int18" else "c"])
    try:
        if SCENARIO == "gfx":
            time.sleep(14)
            monitor(sock, ["sendkey k"], wait=0.5)
            time.sleep(4)
            monitor(sock, ["screendump \"%s\"" % os.path.join(tmp, "shot.ppm")], wait=1.5)
            time.sleep(1)
            monitor(sock, ["pmemsave 0xb8000 4000 \"%s\"" % vga], wait=1.0)
        elif SCENARIO == "probe":
            time.sleep(14)
            monitor(sock, ["sendkey m"], wait=0.5)
            time.sleep(4)
        elif SCENARIO == "a20":
            time.sleep(14)
        elif SCENARIO == "diag":
            time.sleep(14)
            monitor(sock, ["sendkey q"], wait=0.5)
            time.sleep(4)
        else:
            time.sleep(float(os.environ.get("QEMU_WAIT", "25")))
        monitor(sock, ["pmemsave 0xb8000 4000 \"%s\"" % vga], wait=1.0)
        time.sleep(0.5)
    finally:
        try:
            monitor(sock, ["quit"], wait=0.2)
        except Exception:
            pass
        try:
            q.wait(5)
        except subprocess.TimeoutExpired:
            q.kill()

    if SCENARIO == "gfx":
        ppm = open(os.path.join(tmp, "shot.ppm"), "rb").read()
        parts = ppm.split(b"\n", 3)
        w, h = map(int, parts[1].split())
        px = parts[3]
        def pix(x, y):
            o = (y * w + x) * 3
            return tuple(px[o:o + 3])
        print("screen %dx%d" % (w, h))
        ok = True
        exp = {(10, 5): (255, 0, 0), (10, 20): (0, 255, 0), (10, 210): (255, 255, 255),
               (10, 300): (255, 255, 0), (1000, 700): (0, 0, 255),
               (128, 300): (255, 255, 255), (0, 300): (255, 255, 255), (1023, 300): (255, 255, 255),
               (500, 0): (255, 255, 255), (500, 767): (255, 255, 255), (130, 100): (255, 255, 255), (140, 100): (255, 128, 0)}
        for k, v in exp.items():
            c = pix(*k) == v
            print(("PASS  " if c else "FAIL  ") + "pixel %s == %s" % (k, v))
            ok &= c
        sys.exit(0 if ok else 1)
    print("---- final VGA text screen ----")
    print(screen_text(vga))
    print("---- results ----")
    out = bytearray(open(work, "rb").read())
    files = fatimg.read_files(out)
    counter = files["COUNTER.TXT"][:4].decode()
    slot = int(counter) % 4
    log = files["RUN%d.LOG" % slot].decode("latin1").rstrip()
    open(os.path.join(BUILD, "last-run.log"), "w").write(log + "\n")
    print("counter", counter, "-> RUN%d.LOG (%d chars), saved build/last-run.log" % (slot, len(log)))

    ok = True

    def check(name, cond):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + name)
        ok &= bool(cond)

    scr = open(vga, "rb").read()
    scr_txt = screen_text(vga)
    if SCENARIO == "diag":
        seg = log[log.index("--- STATE CAPTURE"):]
        print(seg[:1800])
        check("aperture read-back returns what was written (QEMU VGA RAM)", "DADA0000 DADA0001 DADA0002 DADA0003 DADA0004 DADA0005" in seg)
        check("PCI 00:02.0 read", "PCI 00:02.0 cmd/BAR0" in seg)
        sys.exit(0 if ok else 1)
    if SCENARIO == "part":
        check("stick handed over to the partition boot sector with DL=0x80", "FAKE-PBR reached, DL=0x80" in scr_txt)
        check("DS:SI points at partition 2's entry (0x0600+0x1BE+16 = 0x07CE)", "SI=0x07CE" in scr_txt)
        check("hard disk MBR code was NOT run", "FAKE-MBR reached" not in scr_txt)
        check("log says it chained partition 2 (type 0xEB)", "chaining partition 2: type 0xEB" in log)
        sys.exit(0 if ok else 1)
    if SCENARIO == "vmem":
        def top_usable(text):
            best = (0, 0)
            for m in re.finditer(r"base=([0-9A-F]{16}) len=([0-9A-F]{16}) type=1", text):
                b, l = int(m.group(1), 16), int(m.group(2), 16)
                if b + l > best[0] + best[1]:
                    best = (b, l)
            return best
        head, _, tail = log.partition("E820 as seen through INT 15h now:")
        before, after = top_usable(head), top_usable(tail.split("=== MENU")[0].split("--- CHAINLOAD")[0])
        print("top usable E820 entry before hook: base %#x len %#x; through hook: base %#x len %#x" % (before + after))
        check("hook shrank the top usable entry by exactly 4 MB", before[1] - after[1] == 0x400000 and before[0] == after[0])
        check("video RAM block sits at the end of the original entry", ("video RAM block 0x%08X" % (before[0] + before[1] - 0x400000)) in log)
        check("E801 line printed through the hook", "E801:" in log)
        check("INT 10h hook passes a real VBE set-mode through (AX=004F)", "returned AX=0x004F" in log)
        check("INT 10h hook installed", "INT 10h hook installed" in log)
        check("fake internal MBR still reached afterwards", "FAKE-MBR reached, DL=0x80" in scr_txt)
        sys.exit(0 if ok else 1)
    if SCENARIO == "a20":
        check("A20 was closed by the test hook", "A20 gate: CLOSED" in log)
        check("stage opened it again", "A20 gate: opened" in log)
        sys.exit(0 if ok else 1)
    if SCENARIO == "probe":
        check("unreal-mode self-test OK with A20 open", "OK (A20 open)" in log)
        print("---- probe log excerpt ----")
        print(log[log.index("--- VIDEO MEMORY PROBE"):][:600])
        sys.exit(0 if ok else 1)
    if SCENARIO in ("cd", "int18"):
        check("fake El Torito image reached, CD drive DL=0xE0", "FAKE-CD reached, DL=0xE0" in scr_txt)
        check("boot image ran after CD handoff", "[END]" in scr_txt)
    else:
        check("fake internal MBR reached with DL=0x80", "FAKE-MBR reached, DL=0x80" in scr_txt)
        check("internal disk MBR logged read-only", "internal disk MBR / partition table:" in log and "MBR signature 0xAA55" in log)
        check("read through 0x80 hit the fake internal disk (swap hook)", "tag via DL: FAKEHD" in scr_txt)
    check("log mentions patch ok", "patch ok" in log)
    check("log lists mode table", "mode table at VBIOS+0x" in log)
    a = files["VBIOS_A.BIN"]
    b = files["VBIOS_B.BIN"]
    orig = vbios_tool.fake_original()
    check("VBIOS_A.BIN == original fake VBIOS", a == orig)
    exp = vbios_tool.simulate_patch(orig, 0x3A, 0x41, 32)
    check("VBIOS_B.BIN == python-simulated patch", b == exp)
    diff = [i for i in range(len(a)) if a[i] != b[i]]
    print("bytes changed by patch:", [hex(i) for i in diff])
    print("---- run log ----")
    print(log)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
