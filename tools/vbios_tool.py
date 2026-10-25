#!/usr/bin/env python3
"""Offline analysis of a VBIOS dump (VBIOS_A.BIN) and patch simulation.

    vbios_tool.py list  VBIOS_A.BIN
    vbios_tool.py patch VBIOS_A.BIN MODE SRC BPP [-o out.bin]   (MODE/SRC hex)
    vbios_tool.py diff  VBIOS_A.BIN VBIOS_B.BIN

Same table-finding algorithm as 915resolution / the stage: scan from offset 16
for four consecutive 5-byte entries whose mode byte is 0x3x, entries end at
mode 0xFF.  Entry = <mode u8, bpp u8, record offset u16, unknown u8>.
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

ENTRY = 5


def find_table(img):
    for p in range(16, min(len(img), 0x10000) - 20):
        if all(img[p + i * ENTRY] & 0xF0 == 0x30 for i in range(4)):
            n = 0
            q = p
            while img[q] != 0xFF and n < 64:
                n += 1
                q += ENTRY
            return p, n
    return None, 0


def entries(img):
    p, n = find_table(img)
    if p is None:
        return None, []
    return p, [(p + i * ENTRY,) + struct.unpack_from("<BBHB", img, p + i * ENTRY) for i in range(n)]


def detect_type(ents):
    r1 = r2 = 32000
    for _, _, _, res, _ in ents:
        if res <= r1:
            r1 = res
        elif res <= r2:
            r2 = res
    for name, size in (("type3", 38), ("type2", 28), ("type1", 8)):
        if (r2 - r1 - 6) % size == 0:
            return name
    return "unknown"


def decode_type1(img, res):
    rec = img[res:res + 8]
    x = ((rec[4] & 0xF0) << 4) | rec[2]
    y = ((rec[7] & 0xF0) << 4) | rec[5]
    return x, y, rec.hex(" ")


def list_table(img):
    p, ents = entries(img)
    if p is None:
        print("no mode table found")
        return
    print("mode table at 0x%04x, %d entries, bios type guess: %s" % (p, len(ents), detect_type(ents)))
    for off, mode, bpp, res, unk in ents:
        x, y, raw = decode_type1(img, res)
        print("  @%04x mode %02x  %2d bpp  rec@%04x  %4dx%-4d  [%s]" % (off, mode, bpp, res, x, y, raw))


def simulate_patch(img, mode, src, bpp):
    img = bytearray(img)
    p, ents = entries(img)
    if p is None:
        raise ValueError("no mode table")
    srcres = None
    if src:
        for off, m, b, res, u in ents:
            if m == src:
                srcres = res
                break
        else:
            raise ValueError("SRC mode not found")
    hit = 0
    for off, m, b, res, u in ents:
        if m == mode:
            hit += 1
            if srcres is not None:
                struct.pack_into("<H", img, off + 2, srcres)
            if bpp:
                img[off + 1] = bpp
    if not hit:
        raise ValueError("MODE not found")
    return bytes(img)


def fake_original():
    import build
    return build.fake_vbios()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("list")
    s.add_argument("file")
    s = sub.add_parser("patch")
    s.add_argument("file")
    s.add_argument("mode")
    s.add_argument("src")
    s.add_argument("bpp", type=int)
    s.add_argument("-o")
    s = sub.add_parser("diff")
    s.add_argument("a")
    s.add_argument("b")
    a = ap.parse_args()

    if a.cmd == "list":
        list_table(open(a.file, "rb").read())
    elif a.cmd == "patch":
        img = open(a.file, "rb").read()
        out = simulate_patch(img, int(a.mode, 16), int(a.src, 16), a.bpp)
        if a.o:
            open(a.o, "wb").write(out)
        list_table(out)
    else:
        x, y = open(a.a, "rb").read(), open(a.b, "rb").read()
        d = [i for i in range(min(len(x), len(y))) if x[i] != y[i]]
        print("%d differing bytes" % len(d), [hex(i) for i in d[:64]])
        list_table(y)


if __name__ == "__main__":
    main()
