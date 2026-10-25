; origmbr.asm - test-only stand-in for a plain "boot the active partition" MBR (like Windows XP's).
; Prints ORIG-MBR, finds the active partition, loads its boot sector and jumps to it.
cpu 386
bits 16
org 0x0600
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
    mov si, msg
    call puts
    mov si, 0x0600 + 0x1BE
    mov cx, 4
.f: cmp byte [si], 0x80
    je .found
    add si, 16
    loop .f
    mov si, msg_none
    call puts
.h: hlt
    jmp .h
.found:
    mov [ent], si
    mov eax, [si + 8]
    mov [dap + 8], eax
    mov dl, [bootdrv]
    mov si, dap
    mov ah, 0x42
    int 0x13
    jc .err
    mov dl, [bootdrv]
    mov si, [ent]
    jmp 0x0000:0x7C00
.err:
    mov si, msg_err
    call puts
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
msg:      db "ORIG-MBR ", 0
msg_none: db "no active partition", 0
msg_err:  db "read error", 0
bootdrv:  db 0
ent:      dw 0
dap:      db 0x10, 0
          dw 1
          dw 0x7C00, 0
          dq 0
    times 0x1B8 - ($ - $$) db 0
