#!/usr/bin/env python3
"""Boot a real bootable disc image through the stick in QEMU and screenshot it.

    tools/zeta_qemu.py DISC.iso [--patch] [--wait SECONDS] [--out DIR]

The stick is the test build (FAKEVB=1, so no Intel registers are touched); with
--patch it installs the INT 15h memory-map hook and hands back to the BIOS
(INT 18h), which boots DISC.iso. Without --patch it hands back untouched.
Screenshots (PNG) and a text-mode dump are written to DIR.
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import fatimg  # noqa: E402


def ppm_to_png(ppm_path, png_path):
    data = open(ppm_path, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    px = parts[3]
    raw = b"".join(b"\x00" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(png_path, "wb").write(png)


def monitor(sock_path, cmds, wait=0.5):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("disc")
    ap.add_argument("--patch", action="store_true")
    ap.add_argument("--wait", type=float, default=45)
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "zeta-run"))
    ap.add_argument("--mem", default="512")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    img = os.path.join(ROOT, "build", "usb-test.img")
    data = bytearray(open(img, "rb").read())
    cfg = dict(PATCH=1 if a.patch else 0, MODE=0, SRC=0, BPP=0, TESTSET=0, PAUSE=0, AUTOBOOT=2,
               BOOTSEL=2, SELFTEST=0, VMEM=4096, FAKEVB=1)
    fatimg.set_config(data, cfg)
    work = os.path.join(a.out, "stick.img")
    open(work, "wb").write(data)

    tmp = tempfile.mkdtemp(prefix="zetaqemu-")
    sock = os.path.join(tmp, "q.sock")
    q = subprocess.Popen([
        "qemu-system-i386", "-m", a.mem, "-display", "none",
        "-monitor", "unix:%s,server,nowait" % sock,
        "-drive", "file=%s,format=raw,if=ide,index=0" % work,
        "-drive", "file=%s,format=raw,media=cdrom,readonly=on,if=ide,index=2" % a.disc,
        "-boot", "order=cd"])
    tag = "patched" if a.patch else "control"
    try:
        for i, t in enumerate((a.wait * 0.4, a.wait * 0.6)):
            time.sleep(t if i == 0 else a.wait * 0.6 - a.wait * 0.4 + 0.1)
            ppm = os.path.join(tmp, "s%d.ppm" % i)
            monitor(sock, ['screendump "%s"' % ppm], wait=1.5)
            ppm_to_png(ppm, os.path.join(a.out, "%s-%d.png" % (tag, i)))
        time.sleep(1)
        vga = os.path.join(tmp, "vga.bin")
        monitor(sock, ['pmemsave 0xb8000 4000 "%s"' % vga], wait=1.0)
        raw = open(vga, "rb").read()
        rows = ["".join(chr(raw[(r * 80 + c) * 2]) if 32 <= raw[(r * 80 + c) * 2] < 127 else " " for c in range(80)).rstrip() for r in range(25)]
        open(os.path.join(a.out, "%s-text.txt" % tag), "w").write("\n".join(rows) + "\n")
    finally:
        try:
            monitor(sock, ["quit"], wait=0.2)
        except Exception:
            pass
        try:
            q.wait(5)
        except subprocess.TimeoutExpired:
            q.kill()
    print("wrote", a.out, "(%s-0.png, %s-1.png, %s-text.txt)" % (tag, tag, tag))


if __name__ == "__main__":
    main()
