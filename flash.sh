#!/bin/bash
# Write build/usb.img to a USB stick. DESTROYS everything on the stick.
#
#   ./flash.sh              # lists external disks
#   ./flash.sh disk4        # writes to /dev/rdisk4 (asks you to retype the id)
#
# Refuses internal disks, non-external disks and anything over 128 GB.
set -euo pipefail

cd "$(dirname "$0")"
IMG=build/usb.img

if [[ $# -eq 0 ]]; then
    echo "External disks:"
    diskutil list external physical
    echo
    echo "Pick the stick and run: $0 diskN"
    exit 0
fi

DISK="$1"
[[ "$DISK" =~ ^disk[0-9]+$ ]] || { echo "give a whole-disk id like disk4"; exit 1; }
[[ -f "$IMG" ]] || { echo "$IMG missing - run ./build.py first"; exit 1; }

INFO=$(diskutil info "$DISK")
echo "$INFO" | grep -E "Device / Media Name|Device Location|Removable Media|Protocol|Disk Size|Whole" || true

echo "$INFO" | grep -q "Device Location:.*External" || { echo "REFUSING: $DISK is not an external disk"; exit 1; }
echo "$INFO" | grep -q "Whole:.*Yes" || { echo "REFUSING: $DISK is not a whole disk"; exit 1; }
BYTES=$(echo "$INFO" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p' | head -1)
[[ -n "$BYTES" && "$BYTES" -le 137438953472 ]] || { echo "REFUSING: size unknown or over 128 GB"; exit 1; }
[[ "$BYTES" -ge 33554432 ]] || { echo "REFUSING: stick smaller than 32 MB"; exit 1; }

echo
echo "This ERASES $DISK ($((BYTES / 1000000)) MB). Type the disk id again to continue:"
read -r CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || { echo "aborted"; exit 1; }

diskutil unmountDisk "$DISK"
sudo dd if="$IMG" of="/dev/r$DISK" bs=1m
sync
echo
echo "Done. Replug the stick (or: diskutil mountDisk $DISK) to see the BEOSPATCH volume,"
echo "then eject it cleanly before booting the laptop: diskutil eject $DISK"
