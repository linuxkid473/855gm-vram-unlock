#!/usr/bin/env python3
"""Patch your own copy of ZETA 1.21's extreme2.accelerant for the Intel 855GM (Dell Inspiron 510m etc.).

    python3 patch_extreme2.py extreme2.accelerant intel_extreme.accelerant
    python3 patch_extreme2.py --minimal extreme2.accelerant intel_extreme.accelerant

Input must be the stock ZETA 1.21 file (43718 bytes, md5 2c4c7d8dfd9b79ad70e35ce91fbccfdf).
It is found on a ZETA 1.21 install at /boot/beos/system/add-ons/accelerants/extreme2.accelerant
The output is a copy; the input file is never modified.

Default output (this is the tested build, md5 b18748f0e23fae905b075eca4c12af4c) applies three fixes:

 1. Plane size (0x4725, 29 bytes).  The stock driver writes the LCD pipe image size and the plane
    base/stride but never the plane size DSPBSIZE (0x71190), so the plane keeps the BIOS boot size
    (800x600) and a 1024x768 desktop is clipped by black.  Now:
        DSPBSIZE = ((v_display - 1) << 16) | (h_display - 1)
 2. 32-bit pixel format (0x42b9, 1 byte).  The driver programs "32bpp with alpha" (0x1c000000);
    programs that write pixels straight into video memory (DOSBox, video players) leave the alpha
    byte 0, which showed as black.  Now "32bpp, no alpha" (0x18000000), as the BIOS itself uses.
 3. No video overlay (0x5690, 0x56c8, 0x58fc).  With the overlay offered, VLC and MediaPlayer
    showed the overlay key colour (pink).  The driver now reports no overlay, so players draw
    normally into the frame buffer.

--minimal applies only fix 1 (what the 1024x768 crop needs; 32-bit direct-drawing programs and
overlay video then misbehave as described above).
"""
import hashlib
import sys

STOCK_MD5 = '2c4c7d8dfd9b79ad70e35ce91fbccfdf'
STOCK_SIZE = 43718
OFFSET = 0x4725

ORIGINAL = bytes.fromhex(
    '8bb3e4000000'  # mov esi,[ebx+0xe4]
    '8b06'          # mov eax,[esi]
    '8b10'          # mov edx,[eax]
    'b980010700'    # mov ecx,0x70180      (DSPACNTR)
    '8b0411'        # mov eax,[ecx+edx]
    '25ffffff83'    # and eax,0x83ffffff
    '0b45c4'        # or  eax,[ebp-0x3c]
    '890411')       # mov [ecx+edx],eax

PATCHED = bytes.fromhex(
    '8b06'          # mov eax,[esi]        esi is still [ebx+0xe4] here
    '8b08'          # mov ecx,[eax]        ecx = MMIO base
    '0fb745e4'      # movzx eax,word [ebp-0x1c]   v_display
    '48'            # dec eax
    'c1e010'        # shl eax,16
    '0fb755dc'      # movzx edx,word [ebp-0x24]   h_display
    '4a'            # dec edx
    '09d0'          # or eax,edx
    '898190110700'  # mov [ecx+0x71190],eax       DSPBSIZE
    '90909090')     # nop padding

assert len(ORIGINAL) == len(PATCHED) == 29


# Fix 3 (skipped with --minimal): with the overlay offered, players on the 510m show the overlay key
# colour (pink).  Make the driver report no overlay so players draw normally.
#   0x5690  intel_overlay_count:           mov eax,1  ->  mov eax,0
#   0x56c8  intel_allocate_overlay_buffer: push ebp;mov ebp,esp -> xor eax,eax;ret
#   0x58fc  intel_allocate_overlay:        push ebp;mov ebp,esp -> xor eax,eax;ret
NO_OVERLAY = [
    (0x568f, 'b801000000', 'b800000000'),
    (0x56c8, '5589e5', '31c0c3'),
    (0x58fc, '5589e5', '31c0c3'),
]


# Fix 2 (skipped with --minimal): show 32-bit modes as "32bpp, no alpha" (what the BIOS uses)
# instead of "32bpp with alpha", in get_color_space_format.
#   0x42b9  display plane format immediate 0x1c000000 -> 0x18000000
NO_ALPHA = [(0x42b4, 'c70100' '00001c', 'c70100' '000018')]


def main():
    args = [a for a in sys.argv[1:] if a != '--minimal']
    minimal = '--minimal' in sys.argv[1:]
    no_overlay = no_alpha = not minimal
    if len(args) != 2:
        sys.exit(__doc__)
    src, dst = args
    data = bytearray(open(src, 'rb').read())
    md5 = hashlib.md5(data).hexdigest()
    if len(data) != STOCK_SIZE or md5 != STOCK_MD5:
        sys.exit('refusing: %s is not the stock ZETA 1.21 extreme2.accelerant\n'
                 '  size %d (want %d), md5 %s (want %s)' % (src, len(data), STOCK_SIZE, md5, STOCK_MD5))
    if bytes(data[OFFSET:OFFSET + 29]) != ORIGINAL:
        sys.exit('refusing: expected original bytes not found at 0x%x' % OFFSET)
    data[OFFSET:OFFSET + 29] = PATCHED
    if no_overlay:
        for off, old, new in NO_OVERLAY:
            old, new = bytes.fromhex(old), bytes.fromhex(new)
            if bytes(data[off:off + len(old)]) != old:
                sys.exit('refusing: expected original bytes not found at 0x%x' % off)
            data[off:off + len(new)] = new
    if no_alpha:
        for off, old, new in NO_ALPHA:
            old, new = bytes.fromhex(old), bytes.fromhex(new)
            if bytes(data[off:off + len(old)]) != old:
                sys.exit('refusing: expected original bytes not found at 0x%x' % off)
            data[off:off + len(new)] = new
    open(dst, 'wb').write(data)
    print('wrote %s (%d bytes, md5 %s)' % (dst, len(data), hashlib.md5(data).hexdigest()))


if __name__ == '__main__':
    main()
