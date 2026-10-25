#!/usr/bin/env python3
"""Edit CONFIG.TXT on the mounted stick (or a raw image) without changing its size.

    tools/setconfig.py PATCH=1 MODE=3A SRC=41 BPP=32
    tools/setconfig.py --show
    tools/setconfig.py --file build/usb.img PATCH=0

The stage reads CONFIG.TXT from a fixed sector, so the file must stay the same
size and in place. Editing it by hand in a text editor can make macOS write a
new copy elsewhere - use this script, then eject the stick cleanly.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fatimg  # noqa: E402

KEYS = {"PATCH", "MODE", "SRC", "BPP", "TESTSET", "AUTOBOOT", "PAUSE", "BOOTDRV", "FAKEVB", "BOOTSEL", "VMEM", "SELFTEST", "PART"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="/Volumes/BEOSPATCH/CONFIG.TXT",
                    help="CONFIG.TXT on the mounted stick, or a raw disk image")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("pairs", nargs="*", help="KEY=value ...")
    a = ap.parse_args()

    updates = {}
    for p in a.pairs:
        k, _, v = p.partition("=")
        k = k.upper()
        if k not in KEYS or not v:
            sys.exit("bad setting %r (keys: %s)" % (p, ", ".join(sorted(KEYS))))
        updates[k] = v

    is_image = os.path.getsize(a.file) > 1 << 20
    if is_image:
        data = bytearray(open(a.file, "rb").read())
        if updates:
            fatimg.set_config(data, updates)
            open(a.file, "wb").write(data)
        print(fatimg.read_files(data)["CONFIG.TXT"].decode("latin1").rstrip())
        return

    with open(a.file, "r+b") as f:
        text = f.read().decode("latin1")
        if updates:
            new = fatimg.update_config_text(text, updates)
            assert len(new) == len(text)
            f.seek(0)
            f.write(new.encode("latin1"))
            f.flush()
            os.fsync(f.fileno())
            text = new
    print(text.rstrip())
    if updates:
        print("\nsaved in place. Eject the stick cleanly: diskutil eject /Volumes/BEOSPATCH")


if __name__ == "__main__":
    main()
