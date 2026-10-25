#!/usr/bin/env python3
"""Boot a disc straight in QEMU, tap SPACE until the loader's menu appears, then press keys.

    tools/zeta_menu.py DISC.iso OUTDIR [key ...]       keys are QEMU sendkey names (down, ret, ...)
Screenshots go to OUTDIR/shot-N.png (shot-0 = the menu as it first appears).
"""
import os, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zeta_qemu import monitor, ppm_to_png

disc, out, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
os.makedirs(out, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="zetamenu-")
sock = os.path.join(tmp, "q.sock")
vga = os.path.join(tmp, "vga.bin")
q = subprocess.Popen(["qemu-system-i386", "-m", "512", "-display", "none",
    "-monitor", "unix:%s,server,nowait" % sock,
    "-drive", "file=%s,format=raw,media=cdrom,readonly=on,if=ide,index=2" % disc, "-boot", "d"])

def text():
    if os.path.exists(vga):
        os.remove(vga)
    monitor(sock, ['pmemsave 0xb8000 4000 "%s"' % vga], wait=0.5)
    raw = open(vga, "rb").read()
    return "\n".join("".join(chr(raw[(r * 80 + c) * 2]) if 32 <= raw[(r * 80 + c) * 2] < 127 else " " for c in range(80)) for r in range(25))

n = 0
def shot():
    global n
    ppm = os.path.join(tmp, "s%d.ppm" % n)
    monitor(sock, ['screendump "%s"' % ppm], wait=1.0)
    ppm_to_png(ppm, os.path.join(out, "shot-%d.png" % n)); n += 1

try:
    time.sleep(2)
    found = False
    for i in range(80):
        monitor(sock, ["sendkey spc"], wait=0.15)
        time.sleep(0.15)
        if i % 6 == 5 and "Boot Options" in text():
            found = True
            break
    print("menu found:", found)
    time.sleep(0.5)
    shot()
    for k in keys:
        monitor(sock, ["sendkey %s" % k], wait=0.5)
        time.sleep(1.0)
        shot()
finally:
    try: monitor(sock, ["quit"], wait=0.2)
    except Exception: pass
    try: q.wait(5)
    except subprocess.TimeoutExpired: q.kill()
print("screenshots in", out)
