; mbrhdd.asm - boot code for the hybrid MBR installed on the internal disk.
;
; Only the code area (bytes 0..0x1B7) is built here; the installer keeps the disk's own
; signature and partition table (bytes 0x1B8..0x1FF) from the original MBR.
;
;   * relocates itself to 0000:0600, as MBRs do
;   * if SHIFT/CTRL/ALT is held, or the loader cannot be read, it boots the ORIGINAL MBR
;     (saved at HDD_BACKUP_LBA) with the current partition table - a broken loader can never
;     leave the machine unbootable
;   * otherwise loads STAGE_SECTORS sectors from LBA 1 to 1000:0000 and jumps there with DL

cpu 386
bits 16
org 0x0600

%include "layout.inc"

start:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00
    mov ds, ax
    mov es, ax
    mov si, 0x7C00
    mov di, 0x0600
    mov cx, 256
    cld
    rep movsw
    jmp 0x0000:reloc

reloc:
    sti
    mov [bootdrv], dl
    test byte [0x0417], 0x0F        ; BDA keyboard flags: shift / ctrl / alt held?
    jnz bypass

    mov dl, [bootdrv]
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc .chs
    cmp bx, 0xAA55
    jne .chs
    test cl, 1
    jz .chs
    mov dl, [bootdrv]
    mov si, dap_stage
    mov ah, 0x42
    int 0x13
    jc bypass
    jmp go

.chs:                               ; LBA 1..56 are CHS 0/0/2.. on a 63-sector track
    mov dl, [bootdrv]
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov ax, 0x0200 + STAGE_SECTORS
    mov cx, 0x0002
    xor dh, dh
    int 0x13
    jc bypass

go:
    mov ax, 0x1000
    mov es, ax
    cmp dword [es:2], 'BVBP'        ; is what we loaded really the loader? else fall back
    jne bypass
    cmp dword [es:6], 'STG1'
    jne bypass
    xor ax, ax
    mov es, ax
    mov dl, [bootdrv]
    jmp 0x1000:0x0000

bypass:                             ; boot the original MBR code + the current table
    xor ax, ax
    mov es, ax
    mov dl, [bootdrv]
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc .chs2
    cmp bx, 0xAA55
    jne .chs2
    mov dl, [bootdrv]
    mov si, dap_back
    mov ah, 0x42
    int 0x13
    jnc .ok
.chs2:
    xor ax, ax
    mov es, ax
    mov dl, [bootdrv]
    mov bx, 0x7C00
    mov ax, 0x0201
    mov cx, HDD_BACKUP_LBA + 1      ; CHS 0/0/(lba+1)
    xor dh, dh
    int 0x13
    jc fail
.ok:
    mov si, 0x0600 + 0x1B8          ; our copy of the current MBR has the live table
    mov di, 0x7C00 + 0x1B8
    mov cx, 36
    cld
    rep movsw
    cmp word [0x7DFE], 0xAA55
    jne fail
    mov dl, [bootdrv]
    xor si, si
    xor di, di
    jmp 0x0000:0x7C00

fail:
    mov si, msg
.p: lodsb
    test al, al
    jz .h
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    jmp .p
.h: hlt
    jmp .h

msg:     db "BVBP: loader and backup MBR unreadable", 0
bootdrv: db 0

dap_stage:
    db 0x10, 0
    dw STAGE_SECTORS
    dw 0x0000, 0x1000
    dq 1
dap_back:
    db 0x10, 0
    dw 1
    dw 0x7C00, 0x0000
    dq HDD_BACKUP_LBA

code_end:
    times 0x1B8 - ($ - $$) db 0     ; assembly fails here if the code outgrows the code area
