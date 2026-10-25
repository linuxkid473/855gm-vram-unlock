# Hardware logs (Dell Inspiron 510m, Intel 855GM)

The log of the run that each experiment produced, trimmed of padding. They are the evidence behind
the findings in the main README. Firmware dumps are deliberately not included.

| file | what it shows |
|---|---|
| `01-first-diagnostic.log` | first diagnostic boot: VBIOS mode table, VBE reports only 832 KB |
| `02-gms-experiment.log` | dead end: resizing the chipset's stolen memory at run time blanks the screen |
| `03-memprobe.log` | raising the VBIOS memory register (MMIO 0x71414) makes VBE offer 1024x768 at 16/32 bpp |
| `04-kprobe.log` | first colour-bar test (page table written by physical address: partly wrong) |
| `05-kprobe-pipeB.log` | bar test with display pipe B registers logged |
| `06-aperture.log` | aperture test in text mode |
| `07-aperture-gfxmode.log` | aperture test in graphics mode (A20 still closed: results invalid) |
| `08-a20fixed.log` | A20 opened; the chip's memory reads 0xFFFFFFFF by physical address |
| `09-statecapture.log` | chip state in text / stock / raised mode; aperture direct below 896 KB |
| `10-k-success.log` | page table written through the MMIO window: bottom of the screen correct |
| `11-k-fullscreen-success.log` | full-screen 1024x768x32 pattern correct |
| `12-zeta-attempt1.log` | first ZETA attempt: the VBIOS clears the page table on every mode set |
| `13-zeta-attempt2.log` | INT 18h restarts this BIOS's boot sequence (hooks survive) |
| `14-zeta-booted.log` | ZETA booting through the stick |
| `15-partition-table.log` | internal disk partition table before shrinking Windows |
| `16-zeta-install.log` | install boot, after the partition shrink |
