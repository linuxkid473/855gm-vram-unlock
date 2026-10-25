; fakehd.asm - test-only stand-in for the internal disk's MBR.
; Prints the DL it was started with, then reads LBA 1 of DL and prints the
; 6-byte tag found there.  If the int13 drive-swap hook works, DL is 0x80 and
; the tag read through 0x80 is the fake internal disk's "FAKEHD".

cpu 386
bits 16
org 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [drv], dl
    mov si, m1
    call puts
    mov al, [drv]
    call hex8
    mov si, m2
    call puts
    mov ah, 0x02
    mov al, 1
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [drv]
    mov bx, 0x8000
    int 0x13
    jc .fail
    mov si, 0x8000
    mov cx, 6
.t: lodsb
    call putc
    loop .t
    jmp .done
.fail:
    mov si, m3
    call puts
.done:
    mov si, m4
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

drv: db 0
m1: db "FAKE-MBR reached, DL=0x", 0
m2: db " tag via DL: ", 0
m3: db "READ-FAIL", 0
m4: db " [END]", 0

    times 510 - ($ - $$) db 0
    dw 0xAA55
