; boot.asm - MBR for the BeOS VBIOS-patch USB stick
;
; Loads STAGE_SECTORS sectors starting at LBA 1 to 1000:0000 and jumps there.
; Uses INT 13h extensions when present, plain CHS reads otherwise.
; The partition table at 0x1BE describes the FAT16 log/config volume
; (type 0E, marked active so strict BIOSes accept the stick as bootable).

cpu 386
bits 16
org 0x7C00

%include "layout.inc"

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov [bootdrv], dl

    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc .chs
    cmp bx, 0xAA55
    jne .chs
    test cl, 1
    jz .chs

    mov si, dap
    mov dl, [bootdrv]
    mov ah, 0x42
    int 0x13
    jc fail
    jmp go

.chs:
    mov dl, [bootdrv]
    mov ah, 0x08
    int 0x13
    jc fail
    movzx ax, dh
    inc ax
    mov [heads], ax
    movzx ax, cl
    and ax, 0x3F
    mov [spt], ax
    mov word [cur], 1
    mov word [dst], 0
.next:
    mov ax, [cur]
    xor dx, dx
    div word [spt]              ; ax = track, dx = sector - 1
    inc dx
    mov bl, dl                  ; sector
    xor dx, dx
    div word [heads]            ; ax = cylinder, dx = head
    mov dh, dl
    mov ch, al
    mov cl, ah
    shl cl, 6
    or cl, bl
    mov dl, [bootdrv]
    mov ax, 0x1000
    mov es, ax
    mov bx, [dst]
    mov ax, 0x0201
    int 0x13
    jc fail
    add word [dst], 512
    inc word [cur]
    cmp word [cur], STAGE_SECTORS + 1
    jbe .next

go:
    mov dl, [bootdrv]
    jmp 0x1000:0x0000

fail:
    mov si, msg
.p:
    lodsb
    test al, al
    jz .h
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    jmp .p
.h:
    hlt
    jmp .h

msg:     db "BEOSVBP: stage load failed", 13, 10, 0
bootdrv: db 0
heads:   dw 0
spt:     dw 0
cur:     dw 0
dst:     dw 0

dap:
    db 0x10, 0
    dw STAGE_SECTORS
    dw 0x0000, 0x1000
    dq 1

    times 446 - ($ - $$) db 0

; partition 1: FAT16 (LBA), active
    db 0x80
    db 0xFE, 0xFF, 0xFF
    db 0x0E
    db 0xFE, 0xFF, 0xFF
    dd PART_LBA
    dd PART_SECTORS
    times 48 db 0
    dw 0xAA55
