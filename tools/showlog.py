#!/usr/bin/env python3
"""Print the latest boot log (and optionally analyse the VBIOS dump) from the stick.

    tools/showlog.py                     # mounted stick at /Volumes/BEOSPATCH
    tools/showlog.py --vbios             # also list the VBIOS mode table offline
    tools/showlog.py /path/to/usb.img    # a raw image instead of a mounted volume
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fatimg  # noqa: E402
import vbios_tool  # noqa: E402


def load(path):
    if os.path.isdir(path):
        return {n: open(os.path.join(path, n), "rb").read()
                for n in os.listdir(path) if not n.startswith(".")}
    return fatimg.read_files(bytearray(open(path, "rb").read()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", nargs="?", default="/Volumes/BEOSPATCH")
    ap.add_argument("--all", action="store_true", help="print all four log slots")
    ap.add_argument("--vbios", action="store_true", help="analyse VBIOS_A.BIN / VBIOS_B.BIN")
    a = ap.parse_args()

    files = load(a.source)
    counter = files["COUNTER.TXT"][:4].decode()
    latest = int(counter) % 4
    print("boot counter %s -> latest log is RUN%d.LOG" % (counter, latest))
    slots = range(4) if a.all else [latest]
    for s in slots:
        text = files["RUN%d.LOG" % s].decode("latin1").rstrip()
        print("\n===== RUN%d.LOG =====" % s)
        print(text if text else "(empty)")

    if a.vbios:
        for n in ("VBIOS_A.BIN", "VBIOS_B.BIN"):
            blob = files[n]
            print("\n===== %s =====" % n)
            if not any(blob):
                print("(empty - no dump written)")
                continue
            vbios_tool.list_table(blob)


if __name__ == "__main__":
    main()
