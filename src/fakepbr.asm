; fakepbr.asm - test-only partition boot sector. Prints DL and SI as handed over by the stick.
cpu 386
bits 16
org 0x7C00
start:
    cli
    mov [dlv], dl
    mov [siv], si
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov si, m1
    call puts
    mov al, [dlv]
    call hex8
    mov si, m2
    call puts
    mov ax, [siv]
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
dlv: db 0
siv: dw 0
%ifdef XP
m1: db "FAKE-XP PBR reached, DL=0x", 0
%else
m1: db "FAKE-PBR reached, DL=0x", 0
%endif
m2: db " SI=0x", 0
m3: db " [END]", 0
    times 510 - ($ - $$) db 0
    dw 0xAA55
