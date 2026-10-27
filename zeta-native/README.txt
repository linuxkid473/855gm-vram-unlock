NOTE FOR THE GITHUB COPY: this folder holds the patcher, installer and docs only. The repository ships no
ZETA files. The prebuilt driver mentioned below is in ZETA-855GM-native-video-1.0.1.zip at
https://thebeosarchive.de/downloads/Drivers/ ; or build your own with patch_extreme2.py (section 4).
The long story behind this is in WRITEUP.txt.

ZETA 1.21 native Intel 855GM video: full 1024x768, 32-bit colour
=================================================================
Version 1.0.1 -   for ZETA 1.21 on laptops with the Intel 855GM (Dell Inspiron 510m and similar)

CONTENTS
  1. What this is
  2. Tested setup and results
  3. Quick install (prebuilt driver)
  4. Build the driver yourself (recommended: uses your own copy of the file)
  5. Installing and removing
  6. Troubleshooting
  7. How it works (the three fixes)
  8. Checksums
  9. Limits and risks
 10. Credits


1. WHAT THIS IS
---------------
ZETA ships a native Intel graphics driver (extreme2.driver + extreme2.accelerant). It lists the
855GM (PCI 8086:3582) but is not used by default; ZETA falls back to the plain VESA driver. VESA
limits you to the modes the boot menu offers, which is 16-bit colour at best.

If you switch the native driver on, three things go wrong on a laptop LCD:

  * At 1024x768 only the top-left ~800x600 is lit; the rest of the 1024x768 desktop is cut off by
    black. 800x600 looks fine.
  * At 32-bit colour, programs that draw straight into video memory (DOSBox, video players)
    show a black screen. 16-bit is fine.
  * With the driver's video overlay on, VLC and MediaPlayer show a solid pink window instead of the
    video.

This package fixes all three with a 36-byte change to the accelerant, and gives you either a
prebuilt copy or a script that patches your own file.


2. TESTED SETUP AND RESULTS
---------------------------
Machine  : Dell Inspiron 510m, Intel 855GM, BIOS A07, 1024x768 LCD
OS       : ZETA 1.21 (magnussoft), user add-on only; nothing under /boot/beos is replaced
Boot     : with the author's pre-OS boot stub active, which raises the video memory the BIOS
           reports (https://github.com/linuxkid473/855gm-vram-unlock). NOT tested without it.

Result with the default patch in this package:
  * Preferences > Screen offers 1024x768 at 32 bits/pixel and shows the whole desktop.
  * DOSBox runs at 32-bit colour.
  * Video plays in VLC and MediaPlayer at 32-bit.
  * 800x600 still fills the panel.

Not tested: other 855GM laptops, other BIOS versions, ZETA 1.5 (different accelerant build, the
offsets do not apply), an external monitor on the VGA port, running without the boot stub.


3. QUICK INSTALL (PREBUILT DRIVER)
----------------------------------
prebuilt/intel_extreme.accelerant is a copy of ZETA 1.21's extreme2.accelerant with the default
patch applied (md5 b18748f0e23fae905b075eca4c12af4c). If you would rather patch your own file,
use section 4.

 1. Copy install.sh, revert.sh and prebuilt/intel_extreme.accelerant into ONE folder on the ZETA
    machine. A USB stick formatted FAT32, 2 GB or smaller, worked best; a 30 GB stick gave trouble.
 2. Open Terminal in that folder and run:      sh install.sh
 3. Reboot. In the ZETA boot menu choose "Continue booting".
    Do NOT use "Select fail-safe video mode": choosing a mode there forces the VESA driver.
 4. Open Preferences > Screen and select 1024x768 and 32 bits/pixel.


4. BUILD THE DRIVER YOURSELF
----------------------------
This needs a computer with Python 3 (Mac or PC). No ZETA files are included in the script.

 1. Copy your stock accelerant off the ZETA machine:
        /boot/beos/system/add-ons/accelerants/extreme2.accelerant
    The script checks size (43718) and md5 (2c4c7d8dfd9b79ad70e35ce91fbccfdf) and refuses
    anything else, including the ZETA 1.5 build.
 2. Run:
        python3 patch_extreme2.py extreme2.accelerant intel_extreme.accelerant
    The input is never modified. The output md5 should be b18748f0e23fae905b075eca4c12af4c.
 3. Continue with section 3, step 1, using your new intel_extreme.accelerant.

 Option --minimal applies only the plane-size fix (the 1024x768 crop), see section 7.
 No Python? Use a hex editor, or DiskProbe in ZETA, on a COPY of the file and make the edits in
 section 7 by hand.


5. INSTALLING AND REMOVING
--------------------------
install.sh (it finds its own folder, so you can run it from anywhere):
    mkdir -p /boot/home/config/settings/kernel/drivers /boot/home/config/add-ons/accelerants
    echo "hardware_cursor false" > /boot/home/config/settings/kernel/drivers/intel_extreme
    removes any line mentioning intel_extreme.accelerant from /boot/home/config/boot/UserBootscript
        (an old test script put a line there that deleted the driver 60 seconds after each boot)
    cp intel_extreme.accelerant /boot/home/config/add-ons/accelerants/intel_extreme.accelerant
It prints "copy FAILED" if the driver could not be copied.
The accelerant must be called intel_extreme.accelerant so it matches the driver's device name.
The settings line turns the hardware cursor off (used for all testing).

To go back to the plain VESA driver:           sh revert.sh
That deletes the two files created above. Nothing else was changed.

If the screen is unusable at boot: hold Left Shift in the boot menu, disable user add-ons, boot,
then run revert.sh.


6. TROUBLESHOOTING
------------------
 Picture is cropped / black on the right and bottom at 1024x768
     The plane-size fix is missing (you may have patched with something else, or installed a
     different file). Check the md5 of intel_extreme.accelerant.
 DOSBox or other full-screen programs black at 32-bit
     The no-alpha fix is missing.
 Video window is pink
     The no-overlay fix is missing.
 Still using VESA (Screen offers only 16-bit)
     You chose a mode in the boot menu. Boot with "Continue booting" instead.
 Nothing changed after install.sh, or the driver is gone after the next boot
     Check that /boot/home/config/add-ons/accelerants/intel_extreme.accelerant exists. If an old
     test script (zeta-capture-log.txt) put a "(sleep 60; ... rm ...intel_extreme.accelerant ...) &"
     line into /boot/home/config/boot/UserBootscript, it deletes the driver 60 seconds after every
     boot. install.sh version 1.0.1 removes that line; with 1.0 delete it by hand.
 ZETA's syslog shows nothing from this driver, so there is no log to read.


7. HOW IT WORKS (THE THREE FIXES)
---------------------------------
All offsets are file offsets in the stock 1.21 accelerant (43718 bytes), which equal virtual
addresses in the first LOAD segment.

 Fix 1: plane size.  0x4725, 29 bytes, inside intel_set_display_mode.
   The stock driver writes the LCD pipe image size (PIPEBSRC 0x6101c) and the plane base and
   stride, but never the plane size register DSPBSIZE (0x71190). The plane therefore keeps the
   800x600 the BIOS set at boot, and everything beyond it is black. At 800x600 the sizes agree.
   On the 510m the BIOS reads DSPBSIZE = 0x02FF03FF when it runs 1024x768.
   The 29 bytes (a format write for plane A, the unused CRT plane) become code that writes
       DSPBSIZE = ((v_display - 1) << 16) | (h_display - 1)
   original: 8b b3 e4 00 00 00 8b 06 8b 10 b9 80 01 07 00 8b 04 11 25 ff ff ff 83 0b 45 c4 89 04 11
   patched : 8b 06 8b 08 0f b7 45 e4 48 c1 e0 10 0f b7 55 dc 4a 09 d0 89 81 90 11 07 00 90 90 90 90

 Fix 2: 32-bit pixel format.  0x42b9, 1 byte, in get_color_space_format.
   The driver programs the display plane as "32bpp with alpha" (DSPCNTR format 0x1c000000). The
   BIOS uses "32bpp, no alpha" (0x18000000). Programs that write pixels directly into video memory
   (DOSBox, video players drawing without the overlay) leave the alpha byte at 0, which showed as
   black. The desktop is unaffected because ZETA's own drawing sets alpha.
   original: c7 01 00 00 00 1c      patched: c7 01 00 00 00 18

 Fix 3: no video overlay.  0x5690, 0x56c8, 0x58fc.
   With the overlay offered, VLC and MediaPlayer paint their window in the overlay key colour and
   expect the hardware to draw over it. On this setup it does not appear, leaving a pink window.
   The driver now reports no overlay, so players draw into the frame buffer instead.
     0x568f  b8 01 00 00 00 -> b8 00 00 00 00     intel_overlay_count returns 0
     0x56c8  55 89 e5       -> 31 c0 c3           intel_allocate_overlay_buffer returns NULL
     0x58fc  55 89 e5       -> 31 c0 c3           intel_allocate_overlay returns NULL

 Why the fixes were found
   The accelerant was disassembled and compared with the display registers captured from the
   510m's BIOS while it ran 1024x768 (pipe B timings 0x61000-0x61014, PIPEBSRC 0x6101c,
   DSPBCNTR 0x71180 = 0x99000000, DSPBSIZE 0x71190 = 0x02FF03FF). The stock driver trusts the
   BIOS-left state for the LCD pipe and plane, which is only right if the BIOS already ran the
   target mode.


8. CHECKSUMS
------------
 stock extreme2.accelerant (ZETA 1.21), 43718 bytes   2c4c7d8dfd9b79ad70e35ce91fbccfdf
 patched, default (all three fixes)                   b18748f0e23fae905b075eca4c12af4c
 patched, --minimal (fix 1 only)                      e67ab125d8b19542eb9e229cfc4da014


9. LIMITS AND RISKS
-------------------
 * ZETA 1.21 only. Other versions have different builds.
 * A user add-on only: nothing under /boot/beos is replaced, and revert.sh removes it.
 * Plane A (the CRT output) no longer has its format written; on a laptop that plane is unused.
   An external monitor on the VGA port is untested.
 * Video overlay (hardware scaling) is switched off, so video is drawn by the CPU.
 * This is a binary patch to a closed driver, made by reading its disassembly. Use it at your own
   risk and keep a way to boot (Left Shift in the boot menu, or a second boot partition).


CHANGES
-------
 1.0.1  install.sh finds its own folder and reports a failed copy instead of failing quietly;
        it also removes the self-deleting UserBootscript line left by old test scripts.
 1.0    first release.


10. CREDITS
-----------
Reverse engineering and testing: linuxkid473 (https://github.com/linuxkid473/855gm-vram-unlock),
on a Dell Inspiron 510m. The patched driver is derived from magnussoft's ZETA 1.21
extreme2.accelerant; all rights to the original remain with their owners.
