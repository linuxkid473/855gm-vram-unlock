"""Minimal read-only FAT16 access to a raw stick image, plus in-place CONFIG.TXT edits.

Works on a bytearray holding the whole disk image (MBR + partition 1 = FAT16).
"""
import re
import struct

SECTOR = 512


def _volume(data):
    ptype = data[0x1BE + 4]
    if ptype not in (0x04, 0x06, 0x0E):
        raise ValueError("partition 1 is not FAT16 (type 0x%02x)" % ptype)
    start = struct.unpack_from("<I", data, 0x1BE + 8)[0]
    b = start * SECTOR
    bps, spc, rsvd, nfats, rootent, tot16, _m, fatsz = struct.unpack_from("<HBHBHHBH", data, b + 11)
    fat_off = b + rsvd * SECTOR
    root_off = fat_off + nfats * fatsz * SECTOR
    root_sectors = rootent * 32 // SECTOR
    data_lba = start + rsvd + nfats * fatsz + root_sectors
    return dict(start=start, spc=spc, fat_off=fat_off, root_off=root_off,
                rootent=rootent, data_lba=data_lba)


def _chain(data, v, first):
    out = []
    c = first
    while 2 <= c < 0xFFF0:
        out.append(c)
        c = struct.unpack_from("<H", data, v["fat_off"] + c * 2)[0]
    return out


def entries(data):
    v = _volume(data)
    res = {}
    for i in range(v["rootent"]):
        e = data[v["root_off"] + i * 32: v["root_off"] + i * 32 + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5 or e[11] & 0x08 or e[11] == 0x0F:
            continue
        name = e[:8].decode("latin1").rstrip() + "." + e[8:11].decode("latin1").rstrip()
        first = struct.unpack_from("<H", e, 26)[0]
        size = struct.unpack_from("<I", e, 28)[0]
        res[name] = (first, size)
    return v, res


def file_lbas(data, name):
    """Absolute LBAs of every sector of the file's clusters (in order)."""
    v, ents = entries(data)
    first, size = ents[name]
    lbas = []
    for c in _chain(data, v, first):
        base = v["data_lba"] + (c - 2) * v["spc"]
        lbas.extend(range(base, base + v["spc"]))
    return lbas, size


def read_files(data):
    v, ents = entries(data)
    out = {}
    for name, (first, size) in ents.items():
        lbas, _ = file_lbas(data, name)
        blob = b"".join(bytes(data[l * SECTOR:(l + 1) * SECTOR]) for l in lbas)
        out[name] = blob[:size]
    return out


def update_config_text(text, updates):
    """Replace KEY=value lines, preserving total length (pads/trims trailing spaces)."""
    n = len(text)
    for k, val in updates.items():
        pat = re.compile(r"^%s=.*$" % re.escape(k), re.M)
        if pat.search(text):
            text = pat.sub("%s=%s" % (k, val), text, count=1)
        else:
            text = text.rstrip(" \n") + "\n%s=%s\n" % (k, val)
    body = text.rstrip(" \n") + "\n"
    if len(body) > n:
        raise ValueError("config grew past %d bytes" % n)
    return body[:-1].ljust(n - 1) + "\n"


def set_config(data, updates):
    lbas, size = file_lbas(data, "CONFIG.TXT")
    off = lbas[0] * SECTOR
    text = bytes(data[off:off + size]).decode("latin1")
    new = update_config_text(text, updates)
    assert len(new) == size
    data[off:off + size] = new.encode("latin1")
