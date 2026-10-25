; fakecd.asm - test-only El Torito no-emulation boot image.
; BIOS/stub jumps to 07C0:0000 with DL = CD drive.

cpu 386
bits 16
org 0x7C00

; BIOSes differ: 07C0:0000 (spec) or 0000:7C00 (SeaBIOS). Normalise to 0000:xxxx.
start:
    jmp 0x0000:go
go:
    cli
    xor ax, ax
    mov ds, ax
    mov [dl_save], dl
    sti
    mov si, m1
    call puts
    mov al, [dl_save]
    call hex8
    mov si, m2
    call puts
    mov ax, cs
    call hex16
    mov si, m3
    call puts
.h: hlt
    jmp .h

putc:
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    ret
puts:
    lodsb
    test al, al
    jz .r
    call putc
    jmp puts
.r: ret
hex16:
    push ax
    mov al, ah
    call hex8
    pop ax
hex8:
    push ax
    shr al, 4
    call hex4
    pop ax
hex4:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
    jmp putc

m1: db "FAKE-CD reached, DL=0x", 0
m2: db " CS=", 0
m3: db " [END]", 0
dl_save: db 0
    times 2048 - ($ - $$) db 0
