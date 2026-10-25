; stage.asm - BeOS VBIOS patch stage (real mode, loaded at 1000:0000)
;
;   1. logs the machine, PCI, VBIOS and VBE state to files on the USB stick
;   2. optionally patches the shadowed Intel 855GM VBIOS mode table in RAM
;   3. chain-loads the internal hard disk MBR (BeOS boot loader lives there)
;
; Everything it writes goes to pre-allocated files on the stick's FAT16
; volume, addressed by absolute LBA (see layout.inc).  No FAT code needed.

cpu 386
bits 16
org 0

%include "layout.inc"

%macro SAY 1+
    call puts_inl
    db %1, 0
%endmacro

%define H(x) ((x) - hook_img)

%define DUMPBUF_SECTORS 8

section .text

; ===================================================================== entry
start:
    jmp short .go
    db "BVBPSTG1"                   ; signature the disk MBR checks before it jumps here
.go:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFF0
    sti
    cld
    mov bl, dl                  ; keep the boot drive across the bss clear
    mov di, bss_start
    mov cx, bss_end - bss_start
    xor al, al
    rep stosb
    mov [boot_drive], bl
    mov ax, 0x0040
    mov gs, ax
    mov word [vb_seg], 0xC000

    mov ax, 0x0003
    int 0x10

    mov dl, [boot_drive]
    call probe_drive
%ifdef HDDMODE
    jmp hdd_main
%endif
    call init_log

    SAY "=== BeOS VBIOS patch stage v0.1 ===", 10
    SAY "run #"
    mov ax, [run_no]
    call dec16
    SAY "  log slot "
    mov ax, [run_no]
    and ax, 3
    call dec16
    SAY "  boot drive 0x"
    mov al, [boot_drive]
    call hex8
    SAY "  int13-ext="
    mov al, [cur_ext]
    call hex8
    call nl

    call load_config
    cmp word [cfg_fake], 2
    jne .a20
    call a20_break
.a20:
    call a20_setup
    call log_env
    call log_hdd
    call log_cd
    call log_pci
    call prepare_vbios
    call log_vbios
    mov word [dump_lba_lo], 0
    mov eax, VBA_LBA
    call dump_vbios
    call find_mode_table
    jc .nomt
    call log_mode_table
.nomt:
    call vbe_scan
    cmp word [cfg_testset], 0
    je menu
    call vbe_test

; ===================================================================== menu
menu:
    call nl
    SAY "=== MENU ===", 10
    SAY " H = boot internal HARD DISK"
    call patchnote
    SAY " C = boot CD/DVD (El Torito)"
    call patchnote
    SAY " N = hard disk MBR, NO patch (Windows)      D = CD/DVD, NO patch", 10
    cmp word [cfg_part], 0
    je .nopart
    SAY " (PART="
    mov ax, [cfg_part]
    call dec16
    SAY ": H boots partition "
    mov ax, [cfg_part]
    call dec16
    SAY "'s own boot sector, the MBR stays untouched)", 10
.nopart:
    SAY " B = default per BOOTSEL (now "
    cmp word [cfg_bootsel], 0
    je .bh
    SAY "CD/DVD"
    jmp short .bd
.bh:
    SAY "hard disk"
.bd:
    SAY ")", 10
    SAY " X = patch, then hand back to BIOS (INT 18h: next device in boot order)", 10
    SAY " Y = same as X without the patch", 10
    SAY " M = memory probe: tell the VBIOS it has VMEM KB of video RAM (restored after)", 10
    SAY " K = SEE IT: full-screen 1024x768x32 bars, GTT filled through the MMIO window", 10
    SAY " Q = state capture: PCI, MMIO, GTT window, aperture in text / stock gfx / raised gfx", 10
    SAY " I = INSTALL the loader on the internal hard disk (then the stick is not needed)", 10
    SAY " U = UNINSTALL it again (restores the original boot sector)", 10
    SAY " T = rerun VBE set-mode test  R = reboot", 10
    mov ax, [cfg_auto]
    call wait_key
    test al, al
    jnz .k
    SAY "(auto-boot)", 10
    mov al, 'B'
.k: cmp al, 'B'
    jne .k2
    mov al, 'H'
    cmp word [cfg_bootsel], 0
    je .k2
    mov al, 'C'
    cmp word [cfg_bootsel], 1
    je .k2
    mov al, 'X'
.k2:
    mov byte [want_part], 0
    mov byte [want_patch], 1
    mov byte [boot_kind], 0
    cmp al, 'H'
    jne .nh
    mov byte [want_part], 1         ; H honours PART=n (boot that partition's boot sector)
    jmp .go
.nh:
    mov byte [boot_kind], 1
    cmp al, 'C'
    je .go
    mov byte [want_patch], 0
    cmp al, 'D'
    je .go
    mov byte [boot_kind], 0
    cmp al, 'N'
    je .go
    mov byte [boot_kind], 2
    cmp al, 'Y'
    je .go
    mov byte [want_patch], 1
    cmp al, 'X'
    je .go
    cmp al, 'M'
    je .mprobe
    cmp al, 'K'
    je .kprobe
    cmp al, 'Q'
    je .qprobe
    cmp al, 'I'
    je .hinst
    cmp al, 'U'
    je .huninst
    cmp al, 'T'
    je .test
    cmp al, 'R'
    je do_reboot
    jmp menu
.test:
    call vbe_scan
    call vbe_test
    jmp menu
.mprobe:
    call mem_probe
    jmp menu
.kprobe:
    call gfx_probe
    jmp menu
.qprobe:
    call diag_run
    jmp menu
.hinst:
    call hdd_install
    jmp menu
.huninst:
    call hdd_uninstall
    jmp menu
.go:
    cmp byte [want_patch], 0
    je .launch
    cmp word [cfg_patch], 0
    je .launch
    call do_patch
    jnc .post
    SAY "!! patch FAILED - not booting automatically.", 10
    SAY "   Y = boot anyway, anything else = back to menu", 10
    xor ax, ax
    call wait_key
    cmp al, 'Y'
    jne menu
    jmp .launch
.post:
    call vbe_scan
    mov eax, VBB_LBA
    call dump_vbios
    cmp word [cfg_testset], 0
    je .pz
    call vbe_test
.pz:
    cmp word [cfg_pause], 0
    je .launch
    SAY "patched. press any key to boot...", 10
    xor ax, ax
    call wait_key
.launch:
    cmp byte [boot_kind], 0
    jne .l1
    call chainload
    jmp menu
.l1:
    cmp byte [boot_kind], 1
    jne .l2
    call chain_cd
    jmp menu
.l2:
    call handback
    jmp menu

patchnote:
    cmp word [cfg_patch], 0
    je .np
    SAY " WITH VBIOS patch (PATCH=1)", 10
    ret
.np:
    SAY " (PATCH=0, no patch)", 10
    ret

do_reboot:
    SAY "rebooting...", 10
    mov al, 0xFE
    out 0x64, al
    jmp 0xFFFF:0x0000

; ============================================================ console + log
puts_inl:                       ; string follows the CALL, zero terminated
    pusha
    mov bp, sp
    mov si, [bp + 16]
.l: lodsb
    test al, al
    jz .d
    call putc
    jmp .l
.d: mov [bp + 16], si
    popa
    ret

puts:                           ; DS:SI zero terminated
    push ax
    push si
.l: lodsb
    test al, al
    jz .d
    call putc
    jmp .l
.d: pop si
    pop ax
    ret

nl:
    push ax
    mov al, 10
    call putc
    pop ax
    ret

putc:                           ; AL -> screen and log buffer, preserves all
    pusha
    mov [pc_ch], al
    cmp al, 10
    jne .s
    mov al, 13
    call scr_out
.s: mov al, [pc_ch]
    call scr_out
    cmp byte [log_on], 0
    je .done
    mov bx, [logpos]
    mov al, [pc_ch]
    mov [logbuf + bx], al
    inc bx
    mov [logpos], bx
    cmp al, 10
    jne .f
    call log_flush              ; flush every line so a hang leaves a trail
.f: cmp word [logpos], 512
    jb .done
    call log_flush
    call log_advance
.done:
    popa
    ret

scr_out:
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
%ifdef SERIAL
    mov dx, 0x3FD
.w: in al, dx
    test al, 0x20
    jz .w
    mov dx, 0x3F8
    mov al, [pc_ch]
    out dx, al
%endif
    ret

hex4:
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p: call putc
    pop ax
    ret

hex8:
    push ax
    shr al, 4
    call hex4
    pop ax
    call hex4
    ret

hex16:
    push ax
    mov al, ah
    call hex8
    pop ax
    call hex8
    ret

hex32:
    push eax
    shr eax, 16
    call hex16
    pop eax
    call hex16
    ret

dec32:                          ; EAX unsigned
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.d: xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .d
.p: pop ax
    add al, '0'
    call putc
    loop .p
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

dec16:                          ; AX unsigned
    push eax
    movzx eax, ax
    call dec32
    pop eax
    ret

hexdump:                        ; SI = buffer, CX = length (multiple of 16)
    pusha
    xor bx, bx
.row:
    SAY "  "
    mov ax, bx
    call hex16
    SAY ": "
    push cx
    mov cx, 16
.b: lodsb
    call hex8
    mov al, ' '
    call putc
    loop .b
    pop cx
    call nl
    add bx, 16
    sub cx, 16
    jnz .row
    popa
    ret

; ============================================================== disk (INT 13)
probe_drive:                    ; DL = drive; sets cur_*; CF = unusable
    mov [cur_drv], dl
    mov byte [cur_ext], 0
    mov dword [cur_heads], 255
    mov dword [cur_spt], 63
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc .geo
    cmp bx, 0xAA55
    jne .geo
    test cl, 1
    jz .geo
    mov byte [cur_ext], 1
.geo:
    mov dl, [cur_drv]
    mov ah, 0x08
    xor di, di
    int 0x13
    push ds
    pop es
    jc .bad
    movzx eax, dh
    inc eax
    mov [cur_heads], eax
    movzx eax, cl
    and eax, 0x3F
    jnz .s
    mov eax, 63
.s: mov [cur_spt], eax
    clc
    ret
.bad:
    cmp byte [cur_ext], 1
    je .ok
    stc
    ret
.ok:
    clc
    ret

; dio_lba / dio_cnt / dio_off / dio_seg / dio_write -> CF on failure
disk_io:
    pusha
    cmp byte [dio_write], 0
    je .rok
%ifdef HDDMODE
    jmp .deny                   ; SAFETY: the disk loader never writes anywhere
%else
    cmp byte [hook_on], 0       ; SAFETY: with the swap hook live, 0x80 is the
    jne .deny                   ; internal disk - never write
    mov al, [cur_drv]
    cmp al, [boot_drive]        ; SAFETY: never write to any drive but the stick...
    je .rok
    cmp byte [hdd_wr_ok], 0     ; ...except inside the installer's window,
    je .deny
    cmp al, [tgt]               ; and then only the target disk,
    jne .deny
    mov eax, [dio_lba]
    movzx ecx, word [dio_cnt]
    add eax, ecx
    cmp eax, 63                 ; and only its first 63 sectors (MBR + the gap before sector 63)
    ja .deny
    jmp .rok
%endif
.deny:
    popa
    stc
    ret
.rok:
    mov byte [dio_try], 3
.retry:
    cmp byte [cur_ext], 0
    je .chs
    mov byte [dap], 0x10
    mov byte [dap + 1], 0
    mov ax, [dio_cnt]
    mov [dap + 2], ax
    mov ax, [dio_off]
    mov [dap + 4], ax
    mov ax, [dio_seg]
    mov [dap + 6], ax
    mov eax, [dio_lba]
    mov [dap + 8], eax
    mov dword [dap + 12], 0
    mov si, dap
    mov dl, [cur_drv]
    mov ah, 0x42
    cmp byte [dio_write], 0
    je .x
    mov ah, 0x43
.x: xor al, al
    int 0x13
    jnc .ok
    jmp short .err
.chs:
    mov eax, [dio_lba]
    mov [chs_lba], eax
    mov ax, [dio_off]
    mov [chs_off], ax
    mov ax, [dio_cnt]
    mov [chs_n], ax
.cl:
    mov eax, [chs_lba]
    xor edx, edx
    div dword [cur_spt]
    mov bl, dl
    inc bl
    xor edx, edx
    div dword [cur_heads]
    mov dh, dl
    mov ch, al
    mov cl, ah
    shl cl, 6
    or cl, bl
    mov dl, [cur_drv]
    mov bx, [dio_seg]
    mov es, bx
    mov bx, [chs_off]
    mov ax, 0x0201
    cmp byte [dio_write], 0
    je .c2
    mov ax, 0x0301
.c2:
    int 0x13
    push ds
    pop es
    jc .err
    add word [chs_off], 512
    inc dword [chs_lba]
    dec word [chs_n]
    jnz .cl
.ok:
    popa
    clc
    ret
.err:
    xor ax, ax
    mov dl, [cur_drv]
    int 0x13
    dec byte [dio_try]
    jnz .retry
    popa
    stc
    ret

rd_sector:                      ; EAX = lba, DI = dest offset in DS
    mov [dio_lba], eax
    mov word [dio_cnt], 1
    mov [dio_off], di
    mov [dio_seg], ds
    mov byte [dio_write], 0
    jmp disk_io

wr_sector:                      ; EAX = lba, DI = source offset in DS
    mov [dio_lba], eax
    mov word [dio_cnt], 1
    mov [dio_off], di
    mov [dio_seg], ds
    mov byte [dio_write], 1
    jmp disk_io

; ================================================================= log file
log_reset:
    pusha
    cld
    mov di, logbuf
    mov cx, 256
    mov ax, 0x2020
    rep stosw
    mov word [logpos], 0
    popa
    ret

log_advance:
    inc dword [log_lba]
    jmp log_reset

log_flush:
    pusha
    mov eax, [log_lba]
    cmp eax, [log_end]
    jae .full
    mov di, logbuf
    call wr_sector
    jnc .ok
    mov byte [log_on], 0
    SAY "!! log write failed, disk logging off", 10
.ok:
    popa
    ret
.full:
    mov byte [log_on], 0
    SAY "!! log slot full, disk logging off", 10
    jmp .ok

init_log:
    mov byte [log_on], 0
    mov eax, PART_LBA
    mov di, bigbuf
    call rd_sector
    jc .nolog
    cmp dword [bigbuf + 3], 'BEOS'
    jne .nolog
    cmp dword [bigbuf + 7], 'VBP '
    jne .nolog

    mov eax, COUNTER_LBA
    mov di, cntbuf
    call rd_sector
    jc .nolog
    xor dx, dx
    mov cx, 4
    mov si, cntbuf
.dg:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .bad
    xor ah, ah
    imul dx, dx, 10
    add dx, ax
    inc si
    loop .dg
    jmp short .have
.bad:
    xor dx, dx
.have:
    inc dx
    cmp dx, 10000
    jb .w
    xor dx, dx
.w: mov [run_no], dx
    mov ax, dx
    mov di, cntbuf + 3
    mov cx, 4
    mov bx, 10
.wd:
    xor dx, dx
    div bx
    add dl, '0'
    mov [di], dl
    dec di
    loop .wd
    mov eax, COUNTER_LBA
    mov di, cntbuf
    call wr_sector
    jc .nolog

    mov bx, [run_no]
    and bx, 3
    shl bx, 2
    mov eax, [run_lbas + bx]
    mov [log_lba], eax
    add eax, RUN_SECTORS
    mov [log_end], eax

    cld
    mov di, bigbuf
    mov cx, 2048
    mov ax, 0x2020
    rep stosw
    mov eax, [log_lba]
    mov cx, RUN_SECTORS / 8
.cl:
    push cx
    push eax
    mov [dio_lba], eax
    mov word [dio_cnt], 8
    mov word [dio_off], bigbuf
    mov [dio_seg], ds
    mov byte [dio_write], 1
    call disk_io
    pop eax
    pop cx
    jc .nolog
    add eax, 8
    loop .cl
    call log_reset
    mov byte [log_on], 1
    ret
.nolog:
    SAY "!! disk logging disabled (layout check or write failed)", 10
    ret

; ============================================================ configuration
load_config:
    mov eax, CONFIG_LBA
    mov di, cfgbuf
    call rd_sector
    jc .none
    cmp dword [cfgbuf], 'BEOS'
    jne .none
    call parse_config
    SAY "config: PATCH="
    mov ax, [cfg_patch]
    call dec16
    SAY " MODE=0x"
    mov ax, [cfg_mode]
    call hex8
    SAY " SRC=0x"
    mov ax, [cfg_src]
    call hex8
    SAY " BPP="
    mov ax, [cfg_bpp]
    call dec16
    SAY " TESTSET="
    mov ax, [cfg_testset]
    call dec16
    SAY " AUTOBOOT="
    mov ax, [cfg_auto]
    call dec16
    SAY " PAUSE="
    mov ax, [cfg_pause]
    call dec16
    SAY " BOOTDRV=0x"
    mov ax, [cfg_bootdrv]
    call hex8
    SAY " FAKEVB="
    mov ax, [cfg_fake]
    call dec16
    SAY " BOOTSEL="
    mov ax, [cfg_bootsel]
    call dec16
    SAY " VMEM="
    mov ax, [cfg_vmem]
    call dec16
    SAY " SELFTEST="
    mov ax, [cfg_selftest]
    call dec16
    SAY " PART="
    mov ax, [cfg_part]
    call dec16
    call nl
    ret
.none:
    SAY "config: CONFIG.TXT missing or unreadable, using defaults", 10
    ret

parse_config:
    mov si, cfgbuf
.line:
.ws:
    cmp si, cfgbuf + 512
    jae .done
    mov al, [si]
    test al, al
    jz .done
    cmp al, ' '
    ja .tok
    inc si
    jmp .ws
.tok:
    cmp al, '#'
    je .eol
    mov bx, cfgtab
.k: mov di, [bx]
    test di, di
    jz .eol
    push si
.c: mov al, [di]
    test al, al
    jz .kend
    cmp al, [si]
    jne .nm
    inc di
    inc si
    jmp .c
.kend:
    cmp byte [si], '='
    jne .nm
    inc si
    mov cx, [bx + 2]
    call parse_num
    mov di, [bx + 4]
    mov [di], ax
    add sp, 2
    jmp .eol
.nm:
    pop si
    add bx, 6
    jmp .k
.eol:
    cmp si, cfgbuf + 512
    jae .done
    mov al, [si]
    inc si
    cmp al, 10
    je .line
    test al, al
    jnz .eol
.done:
    ret

parse_num:                      ; SI text, CX base -> AX; SI advanced
    xor di, di
.l: mov al, [si]
    cmp al, '0'
    jb .end
    cmp al, '9'
    jbe .dg
    or al, 0x20
    cmp al, 'a'
    jb .end
    cmp al, 'f'
    ja .end
    sub al, 'a' - 10
    jmp short .ck
.dg:
    sub al, '0'
.ck:
    xor ah, ah
    cmp ax, cx
    jae .end
    imul di, cx
    add di, ax
    inc si
    jmp .l
.end:
    mov ax, di
    ret

; ============================================================ environment log
log_env:
    SAY "BIOS date: "
    mov ax, 0xF000
    mov fs, ax
    mov bx, 0xFFF5
    mov cx, 8
.d: mov al, [fs:bx]
    cmp al, 0x20
    jae .p
    mov al, '?'
.p: call putc
    inc bx
    loop .d
    call nl

    SAY "int12 base KB="
    int 0x12
    call dec16
    SAY "  int15/88 ext KB="
    mov ah, 0x88
    int 0x15
    jnc .e1
    xor ax, ax
.e1:
    call dec16
    call nl

    SAY "E820 memory map:", 10
    xor ebx, ebx
    mov cx, 32
.e: push cx
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    mov di, e820buf
    int 0x15
    jc .ed
    cmp eax, 0x534D4150
    jne .ed
    SAY "  base="
    mov eax, [e820buf + 4]
    call hex32
    mov eax, [e820buf]
    call hex32
    SAY " len="
    mov eax, [e820buf + 12]
    call hex32
    mov eax, [e820buf + 8]
    call hex32
    SAY " type="
    mov ax, [e820buf + 16]
    call dec16
    call nl
    pop cx
    test ebx, ebx
    jz .e2
    loop .e
    jmp short .e2
.ed:
    pop cx
.e2:
    push ds
    pop es

    SAY "disks:", 10
    mov byte [ld_n], 0x80
.dl:
    mov dl, [ld_n]
    mov ah, 0x08
    xor di, di
    int 0x13
    mov [ld_dx], dx
    mov [ld_cx], cx
    pushf
    push ds
    pop es
    popf
    jc .dn
    SAY "  drv 0x"
    mov al, [ld_n]
    call hex8
    SAY " heads="
    mov al, [ld_dx + 1]
    xor ah, ah
    inc ax
    call dec16
    SAY " spt="
    mov al, [ld_cx]
    and ax, 0x3F
    call dec16
    SAY " maxcyl="
    mov ax, [ld_cx]
    mov cl, 6
    mov dx, ax
    shr dx, 6
    and dx, 3
    shl dx, 8
    mov al, ah
    xor ah, ah
    or ax, dx
    ; (cyl low byte is CH, high bits are CL[7:6]; rebuilt above)
    mov ax, [ld_cx]
    mov bl, al
    mov al, ah
    mov ah, bl
    shr ah, 6
    call dec16
    SAY " count="
    mov al, [ld_dx]
    xor ah, ah
    call dec16
    mov word [dpbuf], 0x1E
    mov si, dpbuf
    mov dl, [ld_n]
    mov ah, 0x48
    int 0x13
    jc .nx
    SAY " sectors=0x"
    mov eax, [dpbuf + 20]
    call hex32
    mov eax, [dpbuf + 16]
    call hex32
    SAY " bps="
    mov ax, [dpbuf + 24]
    call dec16
.nx:
    call nl
.dn:
    inc byte [ld_n]
    cmp byte [ld_n], 0x86
    jb .dl
    ret

; ===================================================================== PCI
pci_read32:                     ; EAX = config address -> EAX
    push dx
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    pop dx
    ret

pam_read:                       ; AL = host bridge reg 0x5A
    mov eax, 0x80000058
    call pci_read32
    shr eax, 16
    ret

pam_write:                      ; AL = value for host bridge reg 0x5A
    push dx
    push eax
    mov eax, 0x80000058
    mov dx, 0x0CF8
    out dx, eax
    pop eax
    mov dx, 0x0CFE
    out dx, al
    pop dx
    ret

log_pci:
    SAY "PCI bus 0:", 10
    xor si, si
.d: movzx ebx, si
    shl ebx, 11
    mov eax, 0x80000000
    or eax, ebx
    mov [pci_base], eax
    call pci_read32
    cmp ax, 0xFFFF
    je .n
    push eax
    SAY "  00:"
    mov ax, si
    call hex8
    SAY ".0 "
    pop eax
    push eax
    call hex16
    mov al, ':'
    call putc
    pop eax
    shr eax, 16
    call hex16
    SAY " class="
    mov eax, [pci_base]
    add eax, 8
    call pci_read32
    shr eax, 16
    call hex16
    call nl
.n: inc si
    cmp si, 32
    jb .d

    mov bl, 0
    mov bh, 0
    call pci_dump
    mov bl, 2
    mov bh, 0
    call pci_dump
    mov bl, 2
    mov bh, 1
    call pci_dump
    ret

pci_dump:                       ; BL = device, BH = function (bus 0)
    pusha
    movzx eax, bl
    shl eax, 11
    movzx edx, bh
    shl edx, 8
    or eax, edx
    or eax, 0x80000000
    mov [pci_base], eax
    call pci_read32
    cmp ax, 0xFFFF
    jne .p
    SAY "PCI 00:"
    mov al, bl
    call hex8
    SAY "."
    mov al, bh
    call hex8
    SAY " not present", 10
    popa
    ret
.p: SAY "PCI config space 00:"
    mov al, bl
    call hex8
    SAY "."
    mov al, bh
    call hex8
    call nl
    mov di, pcibuf
    xor cx, cx
.r: movzx eax, cx
    add eax, [pci_base]
    call pci_read32
    mov [di], eax
    add di, 4
    add cx, 4
    cmp cx, 256
    jb .r
    mov si, pcibuf
    mov cx, 256
    call hexdump
    popa
    ret

; =================================================================== VBIOS
prepare_vbios:
    cmp word [cfg_fake], 0
    je .real
    SAY "FAKEVB=1: loading FAKEVB.BIN as pretend VBIOS at 3000:0000", 10
    mov word [vb_seg], 0x3000
    mov eax, FAKEVB_LBA
    mov cx, 16
    xor bx, bx
.l: push cx
    push eax
    push bx
    mov [dio_lba], eax
    mov word [dio_cnt], 8
    mov [dio_off], bx
    mov word [dio_seg], 0x3000
    mov byte [dio_write], 0
    call disk_io
    pop bx
    pop eax
    pop cx
    jc .fail
    add eax, 8
    add bx, 4096
    loop .l
.real:
    ret
.fail:
    SAY "!! could not load FAKEVB.BIN", 10
    mov word [vb_seg], 0xC000
    ret

vb_checksum:                    ; EAX = byte sum of first 32 KB of the VBIOS
    push bx
    push cx
    push edx
    mov fs, [vb_seg]
    xor edx, edx
    xor bx, bx
    mov cx, 0x8000
.l: movzx eax, byte [fs:bx]
    add edx, eax
    inc bx
    loop .l
    mov eax, edx
    pop edx
    pop cx
    pop bx
    ret

log_vbios:
    mov fs, [vb_seg]
    SAY "VBIOS at segment 0x"
    mov ax, [vb_seg]
    call hex16
    SAY ": signature="
    mov al, [fs:0]
    call hex8
    mov al, [fs:1]
    call hex8
    SAY " size="
    mov al, [fs:2]
    xor ah, ah
    call dec16
    SAY " x512  checksum32k=0x"
    call vb_checksum
    call hex32
    call nl
    cmp word [cfg_fake], 0
    jne .pam
    SAY "PAM regs 0x59..0x5F: "
    mov bx, 0x59
.pr:
    movzx eax, bx
    and eax, 0xFFFC
    or eax, 0x80000000
    call pci_read32
    mov cl, bl
    and cl, 3
    shl cl, 3
    shr eax, cl
    call hex8
    mov al, ' '
    call putc
    inc bx
    cmp bx, 0x60
    jb .pr
    call nl
.pam:
    SAY "VBIOS header:", 10
    push ds
    mov ds, [vb_seg]
    xor si, si
    mov di, vhdr
    push es
    push cs
    pop es
    mov cx, 32
    rep movsw
    pop es
    pop ds
    mov si, vhdr
    mov cx, 64
    call hexdump
    ret

; EAX = first LBA of a 128-sector file; copies 64 KB of the VBIOS into it
dump_vbios:
    mov [dv_lba], eax
    SAY "dumping VBIOS to file (lba "
    mov eax, [dv_lba]
    call hex32
    SAY ")", 10
    xor bx, bx
    mov cx, 16
.l: push cx
    push bx
    push ds
    mov ds, [vb_seg]
    mov si, bx
    push cs
    pop es
    mov di, bigbuf
    mov cx, 2048
    cld
    rep movsw
    pop ds
    mov eax, [dv_lba]
    mov [dio_lba], eax
    mov word [dio_cnt], DUMPBUF_SECTORS
    mov word [dio_off], bigbuf
    mov [dio_seg], ds
    mov byte [dio_write], 1
    call disk_io
    pop bx
    pop cx
    jc .fail
    add dword [dv_lba], DUMPBUF_SECTORS
    add bx, 4096
    loop .l
    SAY "  dump ok", 10
    ret
.fail:
    SAY "!! VBIOS dump write failed", 10
    ret

find_mode_table:                ; CF = not found; sets mt_off, mt_cnt
    push bx
    push cx
    mov fs, [vb_seg]
    mov bx, 16
.s: cmp bx, 0xFFE8
    ja .nf
    mov al, [fs:bx]
    and al, 0xF0
    cmp al, 0x30
    jne .n
    mov al, [fs:bx + 5]
    and al, 0xF0
    cmp al, 0x30
    jne .n
    mov al, [fs:bx + 10]
    and al, 0xF0
    cmp al, 0x30
    jne .n
    mov al, [fs:bx + 15]
    and al, 0xF0
    cmp al, 0x30
    je .f
.n: inc bx
    jmp .s
.f: mov [mt_off], bx
    xor cx, cx
.c: cmp byte [fs:bx], 0xFF
    je .d
    inc cx
    add bx, 5
    cmp cx, 64
    jb .c
.d: mov [mt_cnt], cx
    pop cx
    pop bx
    clc
    ret
.nf:
    mov word [mt_off], 0
    mov word [mt_cnt], 0
    pop cx
    pop bx
    stc
    ret

log_mode_table:
    mov fs, [vb_seg]
    SAY "mode table at VBIOS+0x"
    mov ax, [mt_off]
    call hex16
    SAY ", "
    mov ax, [mt_cnt]
    call dec16
    SAY " entries (mode, bpp, record offset, unknown, record bytes, type1 WxH):", 10
    mov bx, [mt_off]
    mov cx, [mt_cnt]
    test cx, cx
    jz .e
.l: push cx
    SAY "  mode 0x"
    mov al, [fs:bx]
    call hex8
    SAY " bpp "
    mov al, [fs:bx + 1]
    xor ah, ah
    call dec16
    SAY " rec@0x"
    mov ax, [fs:bx + 2]
    call hex16
    SAY " unk 0x"
    mov al, [fs:bx + 4]
    call hex8
    mov si, [fs:bx + 2]
    cmp si, 0xFFF0
    ja .nr
    SAY "  rec:"
    mov cx, 8
.r: mov al, ' '
    call putc
    mov al, [fs:si]
    call hex8
    inc si
    loop .r
    mov si, [fs:bx + 2]
    SAY "  "
    mov al, [fs:si + 4]
    and al, 0xF0
    xor ah, ah
    shl ax, 4
    mov dl, [fs:si + 2]
    or al, dl
    call dec16
    mov al, 'x'
    call putc
    mov al, [fs:si + 7]
    and al, 0xF0
    xor ah, ah
    shl ax, 4
    mov dl, [fs:si + 5]
    or al, dl
    call dec16
.nr:
    call nl
    add bx, 5
    pop cx
    dec cx
    jnz near .l
.e: ret

; ===================================================================== patch
; returns CF set on any failure; never leaves PAM unlocked
do_patch:
    SAY "--- VBIOS PATCH ---", 10
    call vmem_patch
    jnc .vm
    stc
    ret
.vm:
    call vmem_selftest
    cmp word [cfg_mode], 0
    jne .m
    SAY "MODE=0: no mode-table patch, video memory patch only", 10
    clc
    ret
.m: mov byte [pam_used], 0
    cmp word [cfg_fake], 0
    jne .go
    mov eax, 0x80000000
    call pci_read32
    push eax
    SAY "host bridge id 0x"
    call hex32
    call nl
    pop eax
    cmp eax, 0x35808086
    je .chip
    SAY "!! not an 82855GM host bridge (8086:3580) - refusing to touch VBIOS", 10
    stc
    ret
.chip:
    call pam_read
    mov [pam_save], al
    SAY "PAM reg 0x5A before: 0x"
    call hex8
    call nl
    mov byte [pam_used], 1
.go:
    call vb_checksum
    mov [sum1], eax
    mov byte [p_status], 1
    cli
    cmp byte [pam_used], 0
    je .nu
    mov al, 0x33
    call pam_write
.nu:
    call vb_checksum
    mov [sum2], eax
    cmp eax, [sum1]
    jne .restore
    mov byte [p_status], 2
    call find_mode_table
    jc .restore
    mov byte [p_status], 3
    call apply_patch
    jc .restore
    mov byte [p_status], 0
.restore:
    cmp byte [pam_used], 0
    je .rs
    mov al, [pam_save]
    call pam_write
.rs:
    sti
    cld
    SAY "checksum32k before unlock 0x"
    mov eax, [sum1]
    call hex32
    SAY ", after 0x"
    mov eax, [sum2]
    call hex32
    call nl
    mov al, [p_status]
    test al, al
    jz .ok
    cmp al, 1
    jne .s2
    SAY "!! shadow RAM did not match VBIOS after unlock (not populated?) - aborted", 10
    jmp .bad
.s2:
    cmp al, 2
    jne .s3
    SAY "!! could not find the mode table - aborted", 10
    jmp .bad
.s3:
    SAY "!! MODE/SRC not found in mode table - aborted", 10
.bad:
    stc
    ret
.ok:
    SAY "patched "
    mov ax, [p_count]
    call dec16
    SAY " entr"
    cmp word [p_count], 1
    jne .pl
    SAY "y"
    jmp short .pe
.pl:
    SAY "ies"
.pe:
    SAY " for mode 0x"
    mov al, [cfg_mode]
    call hex8
    call nl
    SAY "  before:"
    mov si, pb_before
    call dump5
    SAY "  after: "
    mov si, pb_after
    call dump5
    call nl
    ; re-read from live memory after PAM was restored
    mov fs, [vb_seg]
    SAY "  verify (live, PAM restored):"
    mov bx, [p_entry]
    mov cx, 5
.v: mov al, ' '
    call putc
    mov al, [fs:bx]
    call hex8
    inc bx
    loop .v
    call nl
    SAY "patch ok", 10
    clc
    ret

dump5:
    mov cx, 5
.l: mov al, ' '
    call putc
    lodsb
    call hex8
    loop .l
    ret

; applies cfg_mode / cfg_src / cfg_bpp to the live table; no BIOS calls here
apply_patch:
    mov fs, [vb_seg]
    mov word [p_srcres], 0
    mov word [p_count], 0
    cmp word [cfg_src], 0
    je .tgt
    mov bx, [mt_off]
    mov cx, [mt_cnt]
.s: mov al, [fs:bx]
    cmp al, [cfg_src]
    jne .sn
    mov ax, [fs:bx + 2]
    mov [p_srcres], ax
    jmp short .tgt
.sn:
    add bx, 5
    loop .s
    stc
    ret
.tgt:
    mov bx, [mt_off]
    mov cx, [mt_cnt]
.t: mov al, [fs:bx]
    cmp al, [cfg_mode]
    jne .tn
    inc word [p_count]
    cmp word [p_count], 1
    jne .nosave
    mov [p_entry], bx
    mov si, 0
.sv:
    mov al, [fs:bx + si]
    mov [pb_before + si], al
    inc si
    cmp si, 5
    jb .sv
.nosave:
    cmp word [cfg_src], 0
    je .nb
    mov ax, [p_srcres]
    mov [fs:bx + 2], ax
.nb:
    cmp word [cfg_bpp], 0
    je .nb2
    mov al, [cfg_bpp]
    mov [fs:bx + 1], al
.nb2:
    cmp word [p_count], 1
    jne .tn
    mov si, 0
.sa:
    mov al, [fs:bx + si]
    mov [pb_after + si], al
    inc si
    cmp si, 5
    jb .sa
.tn:
    add bx, 5
    dec cx
    jnz .t
    cmp word [p_count], 0
    je .none
    clc
    ret
.none:
    stc
    ret

; ====================================================================== VBE
vbe_scan:
    SAY "VBE controller info:", 10
    mov dword [vbebuf], 0x32454256      ; 'VBE2'
    mov di, vbebuf
    mov ax, 0x4F00
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    je .ok
    SAY "  VBE 4F00 failed, AX=0x"
    call hex16
    call nl
    mov word [vbe_n], 0
    ret
.ok:
    SAY "  sig="
    mov ax, 4
    mov si, vbebuf
    mov cx, 4
.sg:
    lodsb
    call putc
    loop .sg
    SAY " version=0x"
    mov ax, [vbebuf + 4]
    call hex16
    SAY " caps=0x"
    mov eax, [vbebuf + 10]
    call hex32
    SAY " mem="
    movzx eax, word [vbebuf + 18]
    shl eax, 6
    call dec32
    SAY " KB", 10
    SAY "  oem: "
    mov si, [vbebuf + 6]
    mov dx, [vbebuf + 8]
    call copy_far_str
    mov si, strbuf
    call puts
    call nl
    SAY "  vendor: "
    mov si, [vbebuf + 22]
    mov dx, [vbebuf + 24]
    call copy_far_str
    mov si, strbuf
    call puts
    SAY "  product: "
    mov si, [vbebuf + 26]
    mov dx, [vbebuf + 28]
    call copy_far_str
    mov si, strbuf
    call puts
    call nl

    mov si, [vbebuf + 14]
    mov dx, [vbebuf + 16]
    mov di, vbemodes
    xor cx, cx
    push ds
    mov ds, dx
.cp:
    lodsw
    mov [es:di], ax
    add di, 2
    cmp ax, 0xFFFF
    je .cd
    inc cx
    cmp cx, 127
    jb .cp
.cd:
    pop ds
    mov [vbe_n], cx
    SAY "  "
    mov ax, [vbe_n]
    call dec16
    SAY " modes:", 10

    mov word [cand_n], 0
    mov si, vbemodes
    mov cx, [vbe_n]
    test cx, cx
    jz .done
.m: lodsw
    mov [cur_mode], ax
    push si
    push cx
    mov cx, ax
    mov di, modebuf
    mov ax, 0x4F01
    int 0x10
    push ds
    pop es
    mov [vbe_ax], ax
    pop cx
    pop si
    cmp word [vbe_ax], 0x004F
    jne .bad
    SAY "  0x"
    mov ax, [cur_mode]
    call hex16
    mov al, ' '
    call putc
    mov ax, [modebuf + 18]
    call dec16
    mov al, 'x'
    call putc
    mov ax, [modebuf + 20]
    call dec16
    mov al, 'x'
    call putc
    mov al, [modebuf + 25]
    xor ah, ah
    call dec16
    SAY " attr=0x"
    mov ax, [modebuf]
    call hex16
    SAY " pitch="
    mov ax, [modebuf + 16]
    call dec16
    SAY " model="
    mov al, [modebuf + 27]
    xor ah, ah
    call dec16
    SAY " lfb=0x"
    mov eax, [modebuf + 40]
    call hex32
    test word [modebuf], 1
    jnz .sup
    SAY " (unsupported)"
.sup:
    call nl
    cmp word [modebuf + 18], 1024
    jne .nx
    cmp word [modebuf + 20], 768
    jne .nx
    test word [modebuf], 1
    jz .nx
    mov bx, [cand_n]
    cmp bx, 16
    jae .nx
    shl bx, 1
    mov ax, [cur_mode]
    mov [cand + bx], ax
    inc word [cand_n]
.nx:
    dec cx
    jnz near .m
    jmp short .done
.bad:
    SAY "  0x"
    mov ax, [cur_mode]
    call hex16
    SAY " 4F01 failed AX=0x"
    mov ax, [vbe_ax]
    call hex16
    call nl
    dec cx
    jnz near .m
.done:
    ret

copy_far_str:                   ; DX:SI far string -> strbuf (max 63 chars)
    pusha
    push ds
    mov ds, dx
    mov di, strbuf
    mov cx, 63
.l: lodsb
    mov [es:di], al
    inc di
    test al, al
    jz .d
    loop .l
    mov byte [es:di], 0
.d: pop ds
    popa
    ret

vbe_test:
    cmp word [cand_n], 0
    jne .go
    SAY "VBE test: no 1024x768 modes in the VBE list", 10
    ret
.go:
    SAY "VBE set-mode test (each 1024x768 mode, plain then LFB bit):", 10
    mov ax, [cand_n]
    shl ax, 1
    mov [cand_bytes], ax
    xor si, si
.l: cmp si, [cand_bytes]
    jae .done
    mov ax, [cand + si]
    mov [t_mode], ax
    push si
    mov [t_val], ax
    call vbe_try
    mov ax, [t_mode]
    or ax, 0x4000
    mov [t_val], ax
    call vbe_try
    pop si
    add si, 2
    jmp .l
.done:
    ret

vbe_try:
    SAY "  try mode 0x"
    mov ax, [t_val]
    call hex16
    call nl
    mov bx, [t_val]
    mov ax, 0x4F02
    int 0x10
    mov [t_ax], ax
    mov ax, 0x4F03
    int 0x10
    mov [t_cur], bx
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    SAY "    set AX=0x"
    mov ax, [t_ax]
    call hex16
    SAY " current=0x"
    mov ax, [t_cur]
    call hex16
    call nl
    ret

; ================================================================ chainload
wait_key:                       ; AX = seconds (0 = forever) -> AL key (upper), 0 on timeout
    push ebx
    push ecx
    movzx ecx, ax
    imul ecx, ecx, 18
    mov ebx, [gs:0x6C]
.l: mov ah, 1
    int 0x16
    jnz .key
    test ecx, ecx
    jz .l
    mov eax, [gs:0x6C]
    sub eax, ebx
    cmp eax, ecx
    jb .l
    xor al, al
    jmp short .out
.key:
    xor ax, ax
    int 0x16
    cmp al, 'a'
    jb .out
    cmp al, 'z'
    ja .out
    sub al, 0x20
.out:
    pop ecx
    pop ebx
    ret

chainload:
    SAY "--- CHAINLOAD ---", 10
    mov byte [tgt], 0x80
    mov byte [swap], 0
    cmp byte [boot_drive], 0x80
    jne .a
    mov byte [tgt], 0x81
    mov byte [swap], 1
.a: cmp word [cfg_bootdrv], 0
    je .b
    mov al, [cfg_bootdrv]
    mov [tgt], al
    mov byte [swap], 0
    cmp al, 0x80
    je .b
    mov byte [swap], 1
.b: SAY "boot drive 0x"
    mov al, [boot_drive]
    call hex8
    SAY ", target 0x"
    mov al, [tgt]
    call hex8
    SAY ", int13 swap="
    mov al, [swap]
    call hex8
    call nl
%ifndef HDDMODE
    mov al, [tgt]
    cmp al, [boot_drive]
    jne .c
    SAY "!! target equals the USB boot drive, refusing", 10
    ret
%endif
.c: mov byte [rd_ok], 0
    mov dl, [tgt]
    call probe_drive
    jc .c2
    mov dword [dio_lba], 0
    mov word [dio_cnt], 1
    mov word [dio_off], 0x7C00
    mov word [dio_seg], 0
    mov byte [dio_write], 0
    call disk_io
    jc .c2
    mov byte [rd_ok], 1
.c2:
    mov dl, [boot_drive]        ; logging context goes back to the USB stick
    call probe_drive
    cmp byte [rd_ok], 0
    jne .e
    SAY "!! could not read target MBR (drive missing?)", 10
    ret
.e: xor ax, ax
    mov fs, ax
    cmp word [fs:0x7DFE], 0xAA55
    je .f
    SAY "!! target MBR has no 55AA signature", 10
    ret
.f: SAY "target MBR loaded, signature ok", 10
    cmp byte [want_part], 0
    je .np
    cmp word [cfg_part], 0
    je .np
    call load_part_pbr
    jnc .np
    ret
.np:
    cmp byte [swap], 0
    je .g
    SAY "will install int13 drive-swap hook (0x80 <-> 0x"
    mov al, [tgt]
    call hex8
    SAY ")", 10
.g: SAY "jumping to MBR (disk logging ends here)", 10
    mov byte [log_on], 0        ; nothing may be written once the hook is live
    cmp byte [swap], 0
    je .j
    call install_hook
.j: xor si, si
    cmp byte [want_part], 0
    je .ns
    cmp word [cfg_part], 0
    je .ns
    mov si, [pbr_ent]           ; DS:SI -> the partition's entry in the MBR copy at 0000:0600
.ns:
    mov dl, [tgt]
    cmp byte [swap], 0
    je .h
    mov dl, 0x80
.h: cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    xor di, di
    jmp 0x0000:0x7C00

; Load the boot sector of partition PART (1-4) from the target disk's MBR to 0000:7C00, leaving a
; copy of the MBR at 0000:0600 so DS:SI can point at the partition entry (the convention an MBR
; follows when it hands over to a partition boot sector).  Read-only.
load_part_pbr:                  ; CF on failure (message already printed)
    push ds
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov si, 0x7C00
    mov di, 0x0600
    mov cx, 256
    cld
    rep movsw
    pop ds
    push ds
    pop es
    xor ax, ax
    mov fs, ax
    mov ax, [cfg_part]
    cmp ax, 9
    jne .fixed
    mov cx, 1                   ; PART=9: first partition whose type is 0xEB (BeOS / BFS)
    mov bx, 0x0600 + 0x1BE
.s: cmp byte [fs:bx + 4], 0xEB
    je .found
    add bx, 16
    inc cx
    cmp cx, 4
    jbe .s
    SAY "!! PART=9: no BeOS (type 0xEB) partition in the MBR", 10
    stc
    ret
.found:
    mov [part_eff], cx
    jmp short .slot
.fixed:
    cmp ax, 4
    jbe .okn
    SAY "!! PART must be 1-4 (or 9 = first BeOS partition)", 10
    stc
    ret
.okn:
    mov [part_eff], ax
.slot:
    movzx bx, byte [part_eff]
    dec bx
    shl bx, 4
    add bx, 0x0600 + 0x1BE
    mov [pbr_ent], bx
    cmp byte [fs:bx + 4], 0
    jne .have
    SAY "!! that partition slot is empty", 10
    stc
    ret
.have:
    mov eax, [fs:bx + 8]
    mov [pbr_lba], eax
    SAY "chaining partition "
    mov ax, [part_eff]
    call dec16
    SAY ": type 0x"
    mov bx, [pbr_ent]
    xor ax, ax
    mov fs, ax
    mov al, [fs:bx + 4]
    call hex8
    SAY ", boot sector at LBA "
    mov eax, [pbr_lba]
    call dec32
    call nl
    mov byte [rd_ok], 0
    mov dl, [tgt]
    call probe_drive
    jc .back
    mov eax, [pbr_lba]
    mov [dio_lba], eax
    mov word [dio_cnt], 1
    mov word [dio_off], 0x7C00
    mov word [dio_seg], 0
    mov byte [dio_write], 0
    call disk_io
    jc .back
    mov byte [rd_ok], 1
.back:
    mov dl, [boot_drive]        ; logging context goes back to the USB stick
    call probe_drive
    cmp byte [rd_ok], 0
    jne .chk
    SAY "!! could not read the partition boot sector", 10
    stc
    ret
.chk:
    xor ax, ax
    mov fs, ax
    cmp word [fs:0x7DFE], 0xAA55
    je .ok
    SAY "!! partition boot sector has no 55AA signature", 10
    stc
    ret
.ok:
    SAY "partition boot sector loaded, signature ok", 10
    clc
    ret

; ======================================================== CD/DVD (El Torito)
cd_cand: db 0xE0, 0xE1, 0xE2, 0xE3, 0x81, 0x82, 0x83, 0x84, 0x80, 0

find_cd:                        ; CF = none; sets cd_drv (drive with 2048-byte sectors)
    mov byte [cd_i], 0
.l: movzx bx, byte [cd_i]
    mov dl, [cd_cand + bx]
    test dl, dl
    jz .none
    cmp dl, [boot_drive]
    je .n
    mov [cd_try], dl
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc .n
    cmp bx, 0xAA55
    jne .n
    mov word [dpbuf], 0x1E
    mov si, dpbuf
    mov dl, [cd_try]
    mov ah, 0x48
    int 0x13
    jc .n
    cmp word [dpbuf + 24], 2048
    jne .n
    mov al, [cd_try]
    mov [cd_drv], al
    clc
    ret
.n: inc byte [cd_i]
    jmp .l
.none:
    stc
    ret

cd_read:                        ; [cd_lba] [cd_cnt] 2K sectors -> [cd_seg]:[cd_off]; CF on error
    pusha
    mov byte [dio_try], 3
.r: mov byte [dap], 0x10
    mov byte [dap + 1], 0
    mov ax, [cd_cnt]
    mov [dap + 2], ax
    mov ax, [cd_off]
    mov [dap + 4], ax
    mov ax, [cd_seg]
    mov [dap + 6], ax
    mov eax, [cd_lba]
    mov [dap + 8], eax
    mov dword [dap + 12], 0
    mov si, dap
    mov dl, [cd_drv]
    mov ah, 0x42
    xor al, al
    int 0x13
    jnc .ok
    xor ax, ax
    mov dl, [cd_drv]
    int 0x13
    dec byte [dio_try]
    jnz .r
    popa
    stc
    ret
.ok:
    popa
    clc
    ret

; reads the El Torito boot record + catalog default entry
; out: CF set on failure; cd_media cd_ldseg cd_count cd_rba filled
cd_catalog:
    call find_cd
    jc .nodrive
    mov dword [cd_lba], 17
    mov word [cd_cnt], 1
    mov word [cd_off], bigbuf
    mov [cd_seg], ds
    call cd_read
    jc .rerr
    cmp byte [bigbuf], 0
    jne .nobr
    cmp dword [bigbuf + 1], 'CD00'
    jne .nobr
    cmp dword [bigbuf + 7], 'EL T'
    jne .nobr
    mov eax, [bigbuf + 0x47]
    mov [cd_lba], eax
    call cd_read
    jc .rerr
    cmp byte [bigbuf], 1
    jne .nocat
    cmp word [bigbuf + 30], 0xAA55
    jne .nocat
    cmp byte [bigbuf + 32], 0x88
    jne .notboot
    mov al, [bigbuf + 33]
    and al, 0x0F
    mov [cd_media], al
    mov ax, [bigbuf + 34]
    test ax, ax
    jnz .s
    mov ax, 0x07C0
.s: mov [cd_ldseg], ax
    mov ax, [bigbuf + 38]
    mov [cd_count], ax
    mov eax, [bigbuf + 40]
    mov [cd_rba], eax
    clc
    ret
.nodrive:
    mov byte [cd_err], 1
    stc
    ret
.rerr:
    mov byte [cd_err], 2
    stc
    ret
.nobr:
    mov byte [cd_err], 3
    stc
    ret
.nocat:
    mov byte [cd_err], 4
    stc
    ret
.notboot:
    mov byte [cd_err], 5
    stc
    ret

cd_report_err:
    mov al, [cd_err]
    cmp al, 1
    jne .2
    SAY "no CD/DVD drive found with a readable disc", 10
    ret
.2: cmp al, 2
    jne .3
    SAY "CD/DVD read error (disc spinning up? try again)", 10
    ret
.3: cmp al, 3
    jne .4
    SAY "disc has no El Torito boot record (not a bootable disc)", 10
    ret
.4: cmp al, 4
    jne .5
    SAY "El Torito catalog invalid", 10
    ret
.5: SAY "catalog default entry is not bootable", 10
    ret

log_cd:
    SAY "CD/DVD:", 10
    call cd_catalog
    jnc .ok
    SAY "  "
    call cd_report_err
    ret
.ok:
    SAY "  drive 0x"
    mov al, [cd_drv]
    call hex8
    SAY "  El Torito default entry: media="
    mov al, [cd_media]
    call hex8
    SAY " (0=no-emulation 1-3=floppy 4=hdd)  load seg 0x"
    mov ax, [cd_ldseg]
    call hex16
    SAY "  sectors(512B)="
    mov ax, [cd_count]
    call dec16
    SAY "  image RBA="
    mov eax, [cd_rba]
    call dec32
    call nl
    ret

chain_cd:
    SAY "--- CHAIN CD/DVD ---", 10
    call cd_catalog
    jnc .got
    SAY "!! "
    call cd_report_err
    ret
.got:
    SAY "CD drive 0x"
    mov al, [cd_drv]
    call hex8
    SAY ", boot image media type "
    mov al, [cd_media]
    call hex8
    SAY ", load seg 0x"
    mov ax, [cd_ldseg]
    call hex16
    SAY ", "
    mov ax, [cd_count]
    call dec16
    SAY " x 512 bytes", 10
    cmp byte [cd_media], 0
    je .noemu
    SAY "!! this disc boots with floppy/HDD emulation, which this stub does not", 10
    SAY "   emulate yet - cannot boot it through the patch (see README)", 10
    ret
.noemu:
    movzx eax, word [cd_count]
    test eax, eax
    jnz .c1
    mov eax, 1
.c1:
    mov ecx, eax                ; 512-byte sectors to load
    shl ecx, 9
    movzx edx, word [cd_ldseg]
    shl edx, 4
    add edx, ecx
    cmp edx, 0x10000            ; must end below our own stage at 1000:0000
    jbe .fit
    SAY "!! boot image too large for low memory (limit 0x10000 linear)", 10
    ret
.fit:
    add eax, 3
    shr eax, 2                  ; 2048-byte sectors
    mov [cd_cnt], ax
    mov eax, [cd_rba]
    mov [cd_lba], eax
    mov word [cd_off], 0
    mov ax, [cd_ldseg]
    mov [cd_seg], ax
    call cd_read
    jnc .ld
    SAY "!! could not read the boot image", 10
    ret
.ld:
    SAY "boot image loaded, jumping (disk logging ends here)", 10
    mov byte [log_on], 0
    mov dl, [cd_drv]
    mov ax, [cd_ldseg]
    cli
    xor bx, bx
    mov ss, bx
    mov sp, 0x7C00
    push ax
    push bx
    mov ds, bx
    mov es, bx
    retf

; The BIOS only exposes the optical drive through INT 13h while it is booting
; from it, so instead of reading the disc ourselves we can hand control back:
; INT 18h tells a BBS BIOS "this boot device failed, try the next one".  No
; POST runs, so the patched VBIOS shadow survives.
handback:
    SAY "--- HAND BACK TO BIOS (INT 18h) ---", 10
    SAY "the BIOS should now try the next device in its boot order", 10
    SAY "(set Setup boot order to: USB, CD/DVD, hard disk)", 10
    mov byte [log_on], 0
    sti
    int 0x18
    SAY "!! INT 18h returned - this BIOS does not continue the boot sequence", 10
    ret

; ===================================================== video memory (855patch)
; The VBIOS decides which VBE modes fit from a scratch register in the graphics
; chip (MMIO 0x71414, bits 31:16, in 4 KB pages).  MMIO is reached through the
; IGD's I/O BAR: index port at base, data port at base+4 (the VBIOS does the same).
;
; mem_probe is read-mostly: it logs registers and the GTT, raises that word to
; VMEM KB, re-lists/re-tests the VBE modes, then restores the original value.

gdt:    dq 0
        dq 0x00CF92000000FFFF
gdtr:   dw 15
        dd 0

go_unreal:                      ; FS := 4 GB data segment, still in real mode
    push eax
    cli
    xor eax, eax
    mov ax, ds
    shl eax, 4
    add eax, gdt
    mov [gdtr + 2], eax
    lgdt [gdtr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .p1
.p1:
    mov ax, 8
    mov fs, ax
    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp short .p2
.p2:
    sti
    pop eax
    ret

mmio_init:                      ; CF = no I/O BAR on 00:02.0
    mov eax, 0x80001018
    call pci_read32
    test al, 1
    jz .no
    and ax, 0xFFFC
    mov [io_base], ax
    clc
    ret
.no:
    stc
    ret

mmio_rd:                        ; EAX = register offset -> EAX
    push dx
    mov dx, [io_base]
    out dx, eax
    add dx, 4
    in eax, dx
    pop dx
    ret

mmio_wr:                        ; EAX = register offset, EBX = value
    push dx
    push eax
    mov dx, [io_base]
    out dx, eax
    add dx, 4
    mov eax, ebx
    out dx, eax
    pop eax
    pop dx
    ret

%macro SHOWREG 1
    SAY "  MMIO 0x"
    mov eax, %1
    call hex32
    SAY " = 0x"
    mov eax, %1
    call mmio_rd
    call hex32
    call nl
%endmacro

unreal_selftest:
    mov ax, 0xF000
    mov fs, ax
    mov eax, [fs:0x10]
    mov [ut_a], eax
    call go_unreal
    mov ebx, 0xF0010
    mov eax, [fs:ebx]
    mov [ut_b], eax
    mov ebx, 0x00100000
    mov eax, [fs:ebx]
    mov [ut_c], eax
    SAY "unreal mode self-test: F000:0010="
    mov eax, [ut_a]
    call hex32
    SAY " flat 0xF0010="
    mov eax, [ut_b]
    call hex32
    SAY " flat 1MB="
    mov eax, [ut_c]
    call hex32
    mov eax, [ut_a]
    cmp eax, [ut_b]
    jne .bad
    call a20_check
    test ax, ax
    jnz .ok
    SAY "  A20 CLOSED - addresses above 1 MB wrap", 10
    stc
    ret
.ok:
    SAY "  OK (A20 open)", 10
    clc
    ret
.bad:
    SAY "  MISMATCH", 10
    stc
    ret

mem_probe:
    SAY "--- VIDEO MEMORY PROBE (855patch-style) ---", 10
    cmp word [cfg_fake], 0
    jne .fake
    mov eax, 0x80000000
    call pci_read32
    cmp eax, 0x35808086
    je .chip
    SAY "!! not an 82855GM, refusing", 10
    ret
.fake:
    SAY "FAKEVB=1: no Intel IGD here, running the unreal-mode self-test only", 10
    call unreal_selftest
    ret
.chip:
    call unreal_selftest
    jnc .su
    ret                         ; A20 closed or unreal mode broken: do nothing
.su:
    call mmio_init
    jnc .io
    SAY "!! no I/O BAR on 00:02.0, cannot reach MMIO", 10
    ret
.io:
    SAY "IGD I/O BAR base 0x"
    mov ax, [io_base]
    call hex16
    call nl
    SAY "scratch / display registers before:", 10
    SHOWREG 0x71410
    SHOWREG 0x71414
    SHOWREG 0x71418
    SHOWREG 0x7141C
    SHOWREG 0x2020
    SHOWREG 0x2024
    SHOWREG 0x70008
    SHOWREG 0x70180
    SHOWREG 0x70184
    SHOWREG 0x70188
    mov eax, 0x71414
    call mmio_rd
    mov [swf_old], eax
    SAY "VBIOS memory word (0x71414 >> 16) = "
    mov eax, [swf_old]
    shr eax, 16
    shl eax, 2
    call dec32
    SAY " KB", 10
.raise:
    movzx ebx, word [cfg_vmem]
    shr ebx, 2
    jz .zero
    shl ebx, 16
    mov eax, [swf_old]
    and eax, 0xFFFF
    or ebx, eax
    SAY "raising VBIOS memory word to "
    mov ax, [cfg_vmem]
    call dec16
    SAY " KB: writing 0x71414 = 0x"
    mov eax, ebx
    call hex32
    call nl
    mov eax, 0x71414
    call mmio_wr
    mov eax, 0x71414
    call mmio_rd
    SAY "read back 0x"
    call hex32
    call nl
    call vbe_scan
    cmp word [cfg_testset], 0
    je .restore
    call vbe_test
.restore:
    mov ebx, [swf_old]
    mov eax, 0x71414
    call mmio_wr
    mov eax, 0x71414
    call mmio_rd
    SAY "restored 0x71414 = 0x"
    call hex32
    call nl
    SAY "probe over - press R to reboot before booting anything", 10
    ret
.zero:
    SAY "VMEM too small", 10
    ret

; ===================================================== K: see it on screen
; Raise the VBIOS memory word, set 1024x768x32 (VBE 0x118, LFB), paint the top
; 208 lines (backed by real stolen memory), look, then point GTT entries
; 208..767 at a block of ordinary RAM, paint the rest, look, restore everything.
VRAM_BLOCK equ 0x1D000000       ; 464 MB, inside the BIOS' usable RAM map

kregs: dd 0x70008, 0x70180, 0x70184, 0x70188, 0x6001C, 0x60000, 0x6000C
       dd 0x71008, 0x71180, 0x71184, 0x71188, 0x7118C, 0x71190, 0x6101C
       dd 0x61000, 0x61004, 0x61008, 0x6100C, 0x61010, 0x61014
       dd 0x61230, 0x61180, 0x71400, 0x2020, 0x2024
       dd 0x71410, 0x71414, 0x71418, 0x7141C, 0
colors: dd 0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFF00
        dd 0x00FF00FF, 0x0000FFFF, 0x00FF8000, 0x00808080

draw_bars:                      ; lines [d_start, d_end), colour xor d_xor
    call go_unreal
    cli
    movzx eax, word [g_pitch]
    mov [d_pitch], eax
    movzx ecx, word [d_start]
    imul ecx, eax
    add ecx, [g_lfb]
    mov ebx, ecx
    movzx edx, word [d_start]
.line:
    mov eax, edx
    shr eax, 4
    and eax, 7
    mov eax, [colors + eax * 4]
    xor eax, [d_xor]
    cmp edx, 208
    jb .nm
    cmp edx, 212
    jae .nm
    mov eax, 0x00FFFFFF         ; white band marks the end of the stolen-backed lines
.nm:
    push ebx
    xor ebp, ebp
.px:
    mov edi, eax
    test ebp, 0x7C              ; x mod 128 < 4: vertical ruler every 128 pixels
    jnz .t1
    mov edi, 0x00FFFFFF
.t1:
    cmp ebp, 2                  ; left border
    jae .t2
    mov edi, 0x00FFFFFF
.t2:
    cmp ebp, 1022               ; right border
    jb .t3
    mov edi, 0x00FFFFFF
.t3:
    cmp edx, 2                  ; top border
    jae .t4
    mov edi, 0x00FFFFFF
.t4:
    cmp edx, 766                ; bottom border
    jb .t5
    mov edi, 0x00FFFFFF
.t5:
    mov [fs:ebx], edi
    add ebx, 4
    inc ebp
    cmp ebp, 1024
    jb .px
    pop ebx
    add ebx, [d_pitch]
    inc edx
    movzx ecx, word [d_end]
    cmp edx, ecx
    jb .line
    sti
    ret

kgi: dw 0, 100, 223, 224, 767

gtt_fill_window:                ; GTT entries 0..767 -> VRAM_BLOCK pages, via MMIO BAR + 0x10000
    mov eax, 0x80001014
    call pci_read32
    and eax, 0xFFFFFFF0
    add eax, 0x10000
    mov [dg_gtt], eax
    call go_unreal
    cli
    mov ebp, [dg_gtt]
    mov eax, VRAM_BLOCK | 1
    xor ebx, ebx
.l: mov [fs:ebp + ebx * 4], eax
    add eax, 0x1000
    inc ebx
    cmp ebx, 768
    jb .l
    mov si, kgi
    mov di, kgt
    mov cx, 5
.r: movzx ebx, word [si]
    mov eax, [fs:ebp + ebx * 4]
    mov [di], eax
    add si, 2
    add di, 4
    dec cx
    jnz .r
    sti
    mov eax, 0x2020             ; rewrite PGTBL_CTL so the chip re-reads the table
    call mmio_rd
    mov ebx, eax
    mov eax, 0x2020
    call mmio_wr
    ret

gfx_probe:
    SAY "--- K: 1024x768x32 on screen, GTT filled through the MMIO window ---", 10
    cmp word [cfg_fake], 0
    jne fake_gfx_test
    mov eax, 0x80000000
    call pci_read32
    cmp eax, 0x35808086
    je .chip
    SAY "!! not an 82855GM, refusing", 10
    ret
.chip:
    call unreal_selftest
    jnc .u
    SAY "!! unreal mode / A20 problem, aborting", 10
    ret
.u: call mmio_init
    jnc .io
    SAY "!! no I/O BAR", 10
    ret
.io:
    mov eax, 0x71414
    call mmio_rd
    mov [swf_old], eax
    movzx ebx, word [cfg_vmem]
    shr ebx, 2
    jnz .vm
    SAY "VMEM too small", 10
    ret
.vm:
    shl ebx, 16
    and eax, 0xFFFF
    or ebx, eax
    mov eax, 0x71414
    call mmio_wr
    mov cx, 0x0118
    mov di, modebuf
    mov ax, 0x4F01
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    jne .nomode
    test word [modebuf], 1
    jz .nomode
    mov eax, [modebuf + 40]
    mov [g_lfb], eax
    mov ax, [modebuf + 16]
    mov [g_pitch], ax
    SAY "mode 0x118: lfb 0x"
    mov eax, [g_lfb]
    call hex32
    SAY " pitch "
    mov ax, [g_pitch]
    call dec16
    SAY ", extra VRAM block at 0x"
    mov eax, VRAM_BLOCK
    call hex32
    call nl
    SAY "NEXT: the screen switches to full-screen 1024x768 colour bars with white rulers.", 10
    SAY "LOOK at it, then press any key. It ends back in text mode.", 10
    SAY "Press a key to start.", 10
    xor ax, ax
    call wait_key
    mov bx, 0x4118
    mov ax, 0x4F02
    int 0x10
    push ds
    pop es
    mov [g_ax], ax
    cmp ax, 0x004F
    jne .restore
    call gtt_fill_window
    mov eax, 0x2024
    call mmio_rd
    mov [k_er0], eax
    mov ebx, eax
    mov eax, 0x2024             ; clear the sticky page-table error bits
    call mmio_wr
    mov eax, 0x2024
    call mmio_rd
    mov [k_er1], eax
    mov word [d_start], 0
    mov word [d_end], 768
    mov dword [d_xor], 0
    call draw_bars
    mov eax, 0x2024
    call mmio_rd
    mov [k_er2], eax
    mov si, kregs
    mov di, regbuf
.cl:
    mov eax, [si]
    test eax, eax
    jz .cd
    call mmio_rd
    mov [di], eax
    add si, 4
    add di, 4
    jmp .cl
.cd:
    xor ax, ax
    call wait_key
.restore:
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    mov ebx, [swf_old]
    mov eax, 0x71414
    call mmio_wr
    SAY "text mode back, VBIOS memory word restored, VBE set-mode AX=0x"
    mov ax, [g_ax]
    call hex16
    call nl
    cmp word [g_ax], 0x004F
    jne .end
    SAY "PGTBL_ER (0x2024) before clear 0x"
    mov eax, [k_er0]
    call hex32
    SAY ", after clear 0x"
    mov eax, [k_er1]
    call hex32
    SAY ", after drawing the whole screen 0x"
    mov eax, [k_er2]
    call hex32
    call nl
    SAY "GTT entries read back through the window [0 100 223 224 767] (window reads back zero on this chip):"
    mov si, kgt
    mov cx, 5
    call print_dwords
    SAY "registers with the mode active:", 10
    mov si, kregs
    mov di, regbuf
.pl:
    mov eax, [si]
    test eax, eax
    jz .end
    SAY "  MMIO 0x"
    call hex32
    SAY " = 0x"
    mov eax, [di]
    call hex32
    call nl
    add si, 4
    add di, 4
    jmp .pl
.end:
    SAY "probe over - press R to reboot before booting anything", 10
    ret
.nomode:
    SAY "!! VBE does not offer mode 0x118 even with the raised memory", 10
    mov ebx, [swf_old]
    mov eax, 0x71414
    call mmio_wr
    ret

; QEMU-only check of the drawing path: same bars, VBE mode 0x144, no Intel registers.
fake_gfx_test:
    SAY "FAKEVB=1: drawing test on VBE mode 0x144 (no Intel registers)", 10
    mov cx, 0x0144
    mov di, modebuf
    mov ax, 0x4F01
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    jne .no
    mov eax, [modebuf + 40]
    mov [g_lfb], eax
    mov ax, [modebuf + 16]
    mov [g_pitch], ax
    mov bx, 0x4144
    mov ax, 0x4F02
    int 0x10
    push ds
    pop es
    mov word [d_start], 0
    mov word [d_end], 208
    mov dword [d_xor], 0
    call draw_bars
    mov word [d_start], 208
    mov word [d_end], 768
    mov dword [d_xor], 0x00FFFFFF
    call draw_bars
    xor ax, ax
    call wait_key
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    SAY "draw test done", 10
    ret
.no:
    SAY "!! mode 0x144 not available", 10
    ret

; ======================================================================== A20
; Booting from USB leaves the A20 gate closed on this BIOS, so flat accesses
; above 1 MB wrap (address bit 20 is masked).  Open it before any unreal-mode
; access.  Try INT 15h/2401, then port 0x92, then the keyboard controller.

a20_check:                      ; AX = 1 if A20 is open (non-destructive)
    push ds
    push es
    push si
    push di
    push bx
    push cx
    xor ax, ax
    mov ds, ax
    not ax
    mov es, ax
    mov si, 0x0600
    mov di, 0x0610              ; FFFF:0610 = 0x100600 when A20 is open, 0x000600 when closed
    mov bl, [ds:si]
    mov cl, [es:di]
    mov byte [ds:si], 0x00
    mov byte [es:di], 0xFF
    cmp byte [ds:si], 0xFF
    mov byte [es:di], cl
    mov byte [ds:si], bl
    mov ax, 0
    je .off
    inc ax
.off:
    pop cx
    pop bx
    pop di
    pop si
    pop es
    pop ds
    ret

kbc_wait_in:
    push cx
    mov cx, 0xFFFF
.l: in al, 0x64
    test al, 2
    jz .d
    loop .l
.d: pop cx
    ret

kbc_wait_out:
    push cx
    mov cx, 0xFFFF
.l: in al, 0x64
    test al, 1
    jnz .d
    loop .l
.d: pop cx
    ret

a20_setup:
    call a20_check
    mov [a20_was], ax
    test ax, ax
    jz .off
    SAY "A20 gate: already open", 10
    ret
.off:
    SAY "A20 gate: CLOSED (BIOS boot-from-USB default) - opening it...", 10
    mov ax, 0x2401
    int 0x15
    call a20_check
    test ax, ax
    jz .p92
    SAY "A20 gate: opened with INT 15h/2401", 10
    ret
.p92:
    in al, 0x92
    or al, 2
    and al, 0xFE                ; never set bit 0 (that resets the machine)
    out 0x92, al
    call a20_check
    test ax, ax
    jz .kbc
    SAY "A20 gate: opened through port 0x92", 10
    ret
.kbc:
    cli
    call kbc_wait_in
    mov al, 0xAD
    out 0x64, al
    call kbc_wait_in
    mov al, 0xD0
    out 0x64, al
    call kbc_wait_out
    in al, 0x60
    push ax
    call kbc_wait_in
    mov al, 0xD1
    out 0x64, al
    call kbc_wait_in
    pop ax
    or al, 2
    out 0x60, al
    call kbc_wait_in
    mov al, 0xAE
    out 0x64, al
    call kbc_wait_in
    sti
    call a20_check
    test ax, ax
    jz .fail
    SAY "A20 gate: opened through the keyboard controller", 10
    ret
.fail:
    SAY "!! A20 gate could not be opened - unreal-mode tests above 1 MB are INVALID", 10
    ret

a20_break:                      ; QEMU test hook only: close A20 so a20_setup has work to do
    in al, 0x92
    and al, 0xFD
    out 0x92, al
    ret

; ==================================================== Q: capture the chip state
; Three snapshots: VGA text mode, a stock BIOS-supported graphics mode, and the
; raised-memory 1024x768x32 mode.  Each snapshot: a few PCI/host-bridge/MMIO
; registers, GTT entries read through the MMIO window (BAR1 + 0x10000), tagged
; writes + read-back through the aperture, and direct reads of the stolen RAM.
DGP_N equ 5
DGH_N equ 4
DGM_N equ 7
DGG_N equ 13
DGA_N equ 6
DGS_N equ 4
DG_TOTAL equ DGP_N + DGH_N + DGM_N + DGG_N + DGA_N + DGS_N

dg_pci: dd 0x04, 0x10, 0x14, 0x18, 0x1C
dg_hb:  dd 0x50, 0x58, 0xB0, 0xB4
dg_mm:  dd 0x2020, 0x2024, 0x71180, 0x71184, 0x71188, 0x6101C, 0x71414
dg_gi:  dw 0, 1, 2, 100, 205, 207, 208, 223, 224, 255, 256, 512, 767
dg_ao:  dd 0x000000, 0x001000, 0x064000, 0x0CF000, 0x0E0000, 0x100000
dg_sp:  dd 0x1FF00000, 0x1FF01000, 0x1FFE0000, 0x1FFFF000

diag_collect:
    mov di, dgbuf
    mov si, dg_pci
    mov cx, DGP_N
.p: mov eax, [si]
    or eax, 0x80001000
    call pci_read32
    mov [di], eax
    add si, 4
    add di, 4
    dec cx
    jnz .p
    mov si, dg_hb
    mov cx, DGH_N
.h: mov eax, [si]
    or eax, 0x80000000
    call pci_read32
    mov [di], eax
    add si, 4
    add di, 4
    dec cx
    jnz .h
    mov si, dg_mm
    mov cx, DGM_N
.m: mov eax, [si]
    call mmio_rd
    mov [di], eax
    add si, 4
    add di, 4
    dec cx
    jnz .m
    mov eax, 0x80001014          ; MMIO BAR; GTT window at +0x10000
    call pci_read32
    and eax, 0xFFFFFFF0
    add eax, 0x10000
    mov [dg_gtt], eax
    mov eax, 0x80001010          ; aperture BAR
    call pci_read32
    and eax, 0xFFFFFFF0
    mov [dg_ap], eax
    call go_unreal
    cli
    mov ebp, [dg_gtt]
    mov si, dg_gi
    mov cx, DGG_N
.g: movzx ebx, word [si]
    mov eax, [fs:ebp + ebx * 4]
    mov [di], eax
    add si, 2
    add di, 4
    dec cx
    jnz .g
    mov ebp, [dg_ap]
    mov si, dg_ao
    xor edx, edx
.w: mov ebx, [si]
    mov eax, 0xDADA0000
    add eax, edx
    mov [fs:ebp + ebx], eax
    add si, 4
    inc edx
    cmp edx, DGA_N
    jb .w
    mov si, dg_ao
    mov cx, DGA_N
.r: mov ebx, [si]
    mov eax, [fs:ebp + ebx]
    mov [di], eax
    add si, 4
    add di, 4
    dec cx
    jnz .r
    mov si, dg_sp
    mov cx, DGS_N
.s: mov ebx, [si]
    mov eax, [fs:ebx]
    mov [di], eax
    add si, 4
    add di, 4
    dec cx
    jnz .s
    sti
    ret

print_dwords:                   ; SI = source, CX = count; prints " xxxxxxxx" each; SI advanced
.l: mov al, ' '
    call putc
    mov eax, [si]
    call hex32
    add si, 4
    dec cx
    jnz .l
    call nl
    ret

diag_print:
    mov si, dgbuf
    SAY "  PCI 00:02.0 cmd/BAR0/BAR1/BAR2/BAR3 :"
    mov cx, DGP_N
    call print_dwords
    SAY "  host bridge 0x50 0x58 0xB0 0xB4     :"
    mov cx, DGH_N
    call print_dwords
    SAY "  MMIO 2020 2024 71180 71184 71188 6101C 71414:"
    mov cx, DGM_N
    call print_dwords
    SAY "  GTT via MMIO window [0 1 2 100 205 207 208 223 224 255 256 512 767]:"
    mov cx, DGG_N
    call print_dwords
    SAY "  aperture read-back, wrote DADA000x at offsets 0 1000 64000 CF000 E0000 100000:"
    mov cx, DGA_N
    call print_dwords
    SAY "  stolen RAM read directly 1FF00000 1FF01000 1FFE0000 1FFFF000:"
    mov cx, DGS_N
    call print_dwords
    ret

diag_scenario:
    mov bx, [dg_mode]
    mov ax, 0x4F02
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    je .ok
    SAY "  VBE set-mode failed, AX=0x"
    call hex16
    call nl
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    ret
.ok:
    call diag_collect
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    call diag_print
    ret

diag_run:
    SAY "--- STATE CAPTURE (Q) ---", 10
    cmp word [cfg_fake], 0
    jne .fake
    mov eax, 0x80000000
    call pci_read32
    cmp eax, 0x35808086
    je .chip
    SAY "!! not an 82855GM, refusing", 10
    ret
.fake:
    SAY "FAKEVB=1: QEMU dry run with harmless fake MMIO ports 0xE0/0xE4", 10
    mov word [io_base], 0x00E0
    call diag_collect
    call diag_print
    ret
.chip:
    call unreal_selftest
    jnc .u
    SAY "!! unreal mode / A20 problem, aborting", 10
    ret
.u: call mmio_init
    jnc .io
    SAY "!! no I/O BAR", 10
    ret
.io:
    mov eax, 0x71414
    call mmio_rd
    mov [swf_old], eax
    SAY "state 1: VGA text mode", 10
    call diag_collect
    call diag_print
    SAY "state 2: stock BIOS memory, VBE 0x4118 is NOT offered; using 0x4105 (1024x768x8)", 10
    mov word [dg_mode], 0x4105
    call diag_scenario
    movzx ebx, word [cfg_vmem]
    shr ebx, 2
    jz .end
    shl ebx, 16
    mov eax, [swf_old]
    and eax, 0xFFFF
    or ebx, eax
    mov eax, 0x71414
    call mmio_wr
    SAY "state 3: VBIOS memory word raised, VBE 0x4118 (1024x768x32)", 10
    mov word [dg_mode], 0x4118
    call diag_scenario
    mov ebx, [swf_old]
    mov eax, 0x71414
    call mmio_wr
.end:
    SAY "capture over - press R to reboot", 10
    ret

; ===================================================== video memory patch (855patch-style)
; What the K test proved on the 510m:
;   * the VBIOS decides which VBE modes fit from the upper word of MMIO 0x71414
;     (4 KB pages)
;   * GTT entries written through the MMIO window (BAR1 + 0x10000) make graphics
;     addresses resolve to ordinary RAM, for the CPU (aperture) and the display
; So: raise the word, point GTT[0..VMEM/4) at a block of RAM taken from the top of
; the usable E820 range, and hide that block from the OS by hooking INT 15h.

%define H15(x) ((x) - hook15_img)

find_vram_base:                 ; top usable E820 entry -> vr_top/vr_hide/vr_base; CF = no room
    mov dword [vr_top], 0
    xor ebx, ebx
    mov cx, 32
.l: push cx
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    mov di, e820buf
    int 0x15
    jc .d
    cmp eax, 0x534D4150
    jne .d
    cmp dword [e820buf + 16], 1
    jne .n
    cmp dword [e820buf + 4], 0
    jne .n
    cmp dword [e820buf + 12], 0
    jne .n
    mov eax, [e820buf]
    add eax, [e820buf + 8]
    jc .n
    cmp eax, [vr_top]
    jbe .n
    mov [vr_top], eax
    mov eax, [e820buf + 8]
    mov [vr_elen], eax
.n: pop cx
    test ebx, ebx
    jz .e
    loop .l
    jmp short .e
.d: pop cx
.e: push ds
    pop es
    mov eax, [vr_top]
    test eax, eax
    jz .fail
    test eax, 0xFFF
    jnz .fail
    movzx edx, word [cfg_vmem]
    shl edx, 10
    mov [vr_hide], edx
    cmp [vr_elen], edx
    jbe .fail
    sub eax, edx
    mov [vr_base], eax
    clc
    ret
.fail:
    stc
    ret

gtt_fill_n:                     ; GTT[0 .. VMEM/4) -> vr_base pages through the MMIO window
    mov eax, 0x80001014
    call pci_read32
    and eax, 0xFFFFFFF0
    add eax, 0x10000
    mov [dg_gtt], eax
    call go_unreal
    cli
    mov ebp, [dg_gtt]
    mov eax, [vr_base]
    or eax, 1
    xor ebx, ebx
    movzx ecx, word [cfg_vmem]
    shr ecx, 2
.l: mov [fs:ebp + ebx * 4], eax
    add eax, 0x1000
    inc ebx
    cmp ebx, ecx
    jb .l
    sti
    mov eax, 0x2020             ; rewrite PGTBL_CTL so the chip re-reads the table
    call mmio_rd
    mov ebx, eax
    mov eax, 0x2020
    call mmio_wr
    ret

install_hook15:
    mov ax, [gs:0x13]
    dec ax
    mov [gs:0x13], ax
    shl ax, 6
    mov es, ax
    mov si, hook15_img
    xor di, di
    mov cx, hook15_end - hook15_img
    cld
    rep movsb
    xor ax, ax
    mov fs, ax
    mov eax, [fs:0x15 * 4]
    mov [es:H15(h15_old)], eax
    mov eax, [vr_hide]
    mov [es:H15(h15_len)], eax
    mov eax, [vr_base]
    mov [es:H15(h15_base)], eax
    mov eax, [vr_hide]
    shr eax, 16
    mov [es:H15(h15_blk)], ax
    mov eax, [vr_hide]
    shr eax, 10
    mov [es:H15(h15_kb)], ax
    cli
    mov word [fs:0x15 * 4], H15(hook15_entry)
    mov [fs:0x15 * 4 + 2], es
    sti
    push ds
    pop es
    ret

e820_dump:                      ; the map as the BIOS (and our hook) reports it now
    SAY "E820 as seen through INT 15h now:", 10
    xor ebx, ebx
    mov cx, 32
.e: push cx
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    mov di, e820buf
    int 0x15
    jc .ed
    cmp eax, 0x534D4150
    jne .ed
    SAY "  base="
    mov eax, [e820buf + 4]
    call hex32
    mov eax, [e820buf]
    call hex32
    SAY " len="
    mov eax, [e820buf + 12]
    call hex32
    mov eax, [e820buf + 8]
    call hex32
    SAY " type="
    mov ax, [e820buf + 16]
    call dec16
    call nl
    pop cx
    test ebx, ebx
    jz .e2
    loop .e
    jmp short .e2
.ed:
    pop cx
.e2:
    push ds
    pop es
    mov ax, 0xE801
    int 0x15
    jc .no801
    SAY "  E801: 1-16MB KB="
    call dec16
    SAY "  above 16MB 64KB blocks="
    mov ax, bx
    call dec16
    call nl
.no801:
    push ds
    pop es
    ret

vmem_patch:                     ; CF on failure
    SAY "--- VIDEO MEMORY PATCH (855patch-style) ---", 10
    cmp word [cfg_vmem], 0
    jne .go
    SAY "VMEM=0: skipped", 10
    clc
    ret
.go:
    cmp word [cfg_fake], 0
    jne .fake
    mov eax, 0x80000000
    call pci_read32
    cmp eax, 0x35808086
    je .chip
    SAY "!! not an 82855GM host bridge, refusing", 10
    stc
    ret
.chip:
    call a20_check
    test ax, ax
    jnz .a20
    SAY "!! A20 gate is closed, refusing", 10
    stc
    ret
.a20:
    call mmio_init
    jnc .io
    SAY "!! no I/O BAR on 00:02.0, refusing", 10
    stc
    ret
.io:
    call find_vram_base
    jnc .room
    SAY "!! no room at the top of usable RAM, refusing", 10
    stc
    ret
.room:
    SAY "video RAM block 0x"
    mov eax, [vr_base]
    call hex32
    SAY ", "
    mov ax, [cfg_vmem]
    call dec16
    SAY " KB, top of usable RAM 0x"
    mov eax, [vr_top]
    call hex32
    call nl
    mov eax, 0x71414
    call mmio_rd
    mov [swf_old], eax
    movzx ebx, word [cfg_vmem]
    shr ebx, 2
    shl ebx, 16
    and eax, 0xFFFF
    or ebx, eax
    SAY "VBIOS memory register 0x71414: 0x"
    mov eax, [swf_old]
    call hex32
    SAY " -> 0x"
    mov eax, ebx
    call hex32
    call nl
    mov eax, 0x71414
    call mmio_wr
    call gtt_fill_n
    SAY "GTT filled through the MMIO window", 10
    call install_hook15
    SAY "INT 15h memory-map hook installed (hides the video RAM block from the OS)", 10
    call install_hook10
    SAY "INT 10h hook installed (refills the GTT after every VBE mode set)", 10
    call e820_dump
    clc
    ret
.fake:
    SAY "FAKEVB=1: no Intel chip - testing only the memory-map hook", 10
    call find_vram_base
    jnc .froom
    SAY "!! no room at the top of usable RAM", 10
    stc
    ret
.froom:
    SAY "video RAM block 0x"
    mov eax, [vr_base]
    call hex32
    call nl
    call install_hook15
    mov word [io_base], 0x00E0      ; harmless unused ports so the hook's I/O loop is a no-op here
    call install_hook10
    SAY "INT 10h hook installed (fake ports)", 10
    call e820_dump
    clc
    ret

vmem_selftest:                  ; same order the OS loader will use: patch first, then set the mode
    cmp word [cfg_selftest], 0
    je .done
    cmp word [cfg_fake], 0
    je .real
    mov bx, 0x4144                  ; QEMU: set a VBE mode THROUGH the INT 10h hook
    mov ax, 0x4F02
    int 0x10
    push ds
    pop es
    mov [g_ax], ax
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    SAY "selftest (fake): VBE set-mode through the INT 10h hook returned AX=0x"
    mov ax, [g_ax]
    call hex16
    call nl
    ret
.real:
    SAY "SELFTEST: full-screen 1024x768x32 bars. Press a key to start, again to continue.", 10
    xor ax, ax
    call wait_key
    mov cx, 0x0118
    mov di, modebuf
    mov ax, 0x4F01
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    jne .no
    test word [modebuf], 1
    jz .no
    mov eax, [modebuf + 40]
    mov [g_lfb], eax
    mov ax, [modebuf + 16]
    mov [g_pitch], ax
    mov bx, 0x4118
    mov ax, 0x4F02
    int 0x10
    push ds
    pop es
    cmp ax, 0x004F
    jne .no
    mov word [d_start], 0
    mov word [d_end], 768
    mov dword [d_xor], 0
    call draw_bars
    xor ax, ax
    call wait_key
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    SAY "selftest: bars shown and dismissed", 10
    ret
.no:
    mov ax, 0x0003
    int 0x10
    push ds
    pop es
    SAY "!! SELFTEST: VBE did not offer or set mode 0x118 after the patch", 10
.done:
    ret

; Resident INT 15h shim: trims the top usable E820 entry (and E801 / 88h) by the
; size of the video RAM block so the OS never allocates it.
hook15_img:
h15_old:  dd 0
h15_len:  dd 0
h15_base: dd 0
h15_blk:  dw 0
h15_kb:   dw 0
hook15_entry:
    cmp ax, 0xE820
    je .e820
    cmp ax, 0xE801
    je .e801
    cmp ah, 0x88
    je .a88
    jmp far [cs:H15(h15_old)]
.e820:
    pushf
    call far [cs:H15(h15_old)]
    jc .r
    cmp eax, 0x534D4150
    jne .ok
    cmp dword [es:di + 16], 1
    jne .ok
    push eax
    push edx
    mov eax, [es:di]
    add eax, [es:di + 8]
    mov edx, [cs:H15(h15_base)]
    add edx, [cs:H15(h15_len)]
    cmp eax, edx
    jne .skip
    mov eax, [cs:H15(h15_len)]
    cmp [es:di + 8], eax
    jbe .skip
    sub [es:di + 8], eax
.skip:
    pop edx
    pop eax
.ok:
    clc
.r:
    retf 2
.e801:
    pushf
    call far [cs:H15(h15_old)]
    jc .r
    cmp bx, [cs:H15(h15_blk)]
    jbe .s1
    sub bx, [cs:H15(h15_blk)]
.s1:
    cmp dx, [cs:H15(h15_blk)]
    jbe .s2
    sub dx, [cs:H15(h15_blk)]
.s2:
    clc
    retf 2
.a88:
    pushf
    call far [cs:H15(h15_old)]
    jc .r
    cmp ax, 0xFC00
    jae .s3
    cmp ax, [cs:H15(h15_kb)]
    jbe .s3
    sub ax, [cs:H15(h15_kb)]
.s3:
    clc
    retf 2
hook15_end:

; Resident INT 10h shim: the VBIOS clears the GTT every time a mode is set, and the
; OS boot loader sets its mode AFTER this stage ran.  So after any successful VBE
; set-mode (AX=4F02) we refill GTT[0..N) and re-arm PGTBL_CTL, using only port I/O
; to the IGD's index/data pair (the GTT window is part of the MMIO space).
%define H10(x) ((x) - hook10_img)

install_hook10:
    mov ax, [gs:0x13]
    dec ax
    mov [gs:0x13], ax
    shl ax, 6
    mov es, ax
    mov si, hook10_img
    xor di, di
    mov cx, hook10_end - hook10_img
    cld
    rep movsb
    xor ax, ax
    mov fs, ax
    mov eax, [fs:0x10 * 4]
    mov [es:H10(h10_old)], eax
    mov eax, [vr_base]
    or eax, 1
    mov [es:H10(h10_val)], eax
    movzx eax, word [cfg_vmem]
    shr eax, 2
    mov [es:H10(h10_cnt)], eax
    mov ax, [io_base]
    mov [es:H10(h10_io)], ax
    cli
    mov word [fs:0x10 * 4], H10(hook10_entry)
    mov [fs:0x10 * 4 + 2], es
    sti
    push ds
    pop es
    ret

hook10_img:
h10_old: dd 0
h10_val: dd 0
h10_cnt: dd 0
h10_io:  dw 0
hook10_entry:
    cmp ax, 0x4F02
    je .vbe
    jmp far [cs:H10(h10_old)]
.vbe:
    pushf
    call far [cs:H10(h10_old)]
    pushf
    cmp ax, 0x004F
    jne .out
    pushad
    mov dx, [cs:H10(h10_io)]
    mov ecx, [cs:H10(h10_cnt)]
    mov esi, [cs:H10(h10_val)]
    mov ebx, 0x10000
.l: mov eax, ebx
    out dx, eax
    add dx, 4
    mov eax, esi
    out dx, eax
    sub dx, 4
    add ebx, 4
    add esi, 0x1000
    dec ecx
    jnz .l
    mov eax, 0x2020
    out dx, eax
    add dx, 4
    in eax, dx
    or eax, 1
    mov esi, eax
    sub dx, 4
    mov eax, 0x2020
    out dx, eax
    add dx, 4
    mov eax, esi
    out dx, eax
    popad
.out:
    popf
    retf 2
hook10_end:

; Read-only: log the internal disk's MBR partition table so the user's real layout is known
; before anything destructive (shrinking Windows, installing ZETA) is planned.
log_hdd:
    SAY "internal disk MBR / partition table:", 10
    mov dl, 0x80
    cmp byte [boot_drive], 0x80
    jne .t
    mov dl, 0x81
.t: mov [hd_drv], dl
    mov byte [hd_ok], 0
    call probe_drive
    jc .back
    mov dword [dio_lba], 0
    mov word [dio_cnt], 1
    mov word [dio_off], bigbuf
    mov [dio_seg], ds
    mov byte [dio_write], 0
    call disk_io
    jc .back
    mov byte [hd_ok], 1
    mov dword [dio_lba], 1          ; the 62 sectors in front of the first partition (read only)
    mov word [dio_cnt], 62
    mov word [dio_off], 0
    mov word [dio_seg], 0x4000
    mov byte [dio_write], 0
    call disk_io
    jc .back
    mov byte [hd_gap], 1
.back:
    mov dl, [boot_drive]            ; logging context goes back to the USB stick
    call probe_drive
    cmp byte [hd_ok], 0
    jne .have
    SAY "  could not read the internal disk", 10
    ret
.have:
    SAY "  drive 0x"
    mov al, [hd_drv]
    call hex8
    SAY ", MBR signature 0x"
    mov ax, [bigbuf + 510]
    call hex16
    SAY ", disk id 0x"
    mov eax, [bigbuf + 0x1B8]
    call hex32
    call nl
    mov bx, bigbuf + 0x1BE
    mov cx, 4
    mov byte [hd_pn], 1
.p: push cx
    cmp byte [bx + 4], 0
    je .skip
    SAY "  partition "
    mov al, [hd_pn]
    xor ah, ah
    call dec16
    SAY ": active 0x"
    mov al, [bx]
    call hex8
    SAY " type 0x"
    mov al, [bx + 4]
    call hex8
    SAY " start LBA "
    mov eax, [bx + 8]
    call dec32
    SAY " sectors "
    mov eax, [bx + 12]
    call dec32
    SAY " = "
    mov eax, [bx + 12]
    shr eax, 11
    call dec32
    SAY " MB", 10
.skip:
    inc byte [hd_pn]
    add bx, 16
    pop cx
    dec cx
    jnz near .p
    SAY "  (type 0x07 NTFS, 0x0B/0x0C FAT32, 0xDE Dell utility, 0xEB BeOS, 0x05/0x0F extended)", 10
%ifndef HDDMODE
    call log_gap
%endif
    ret

%ifndef HDDMODE
; Which of sectors 1-62 are not all zero, and what is in the first few of them.
log_gap:
    cmp byte [hd_gap], 0
    jne .have
    SAY "  sectors 1-62: could not be read", 10
    ret
.have:
    mov byte [nz_n], 0
    push es
    mov ax, 0x4000
    mov es, ax
    xor bx, bx
    xor di, di
    cld
.s: push di
    mov cx, 512
    xor al, al
    repe scasb
    pop di
    je .z
    movzx si, byte [nz_n]
    cmp si, 62
    jae .z
    mov [nz_list + si], bl
    inc byte [nz_n]
.z: add di, 512
    inc bx
    cmp bx, 62
    jb .s
    pop es
    SAY "  sectors 1-62: "
    movzx ax, byte [nz_n]
    call dec16
    SAY " not empty"
    cmp byte [nz_n], 0
    jne .list
    SAY " (the gap is free)", 10
    ret
.list:
    SAY " - LBA:"
    xor si, si
.l: cmp si, 62
    jae .ld
    movzx bx, byte [nz_n]
    cmp si, bx
    jae .ld
    mov al, ' '
    call putc
    movzx ax, byte [nz_list + si]
    inc ax                          ; index 0 is LBA 1
    call dec16
    inc si
    jmp .l
.ld:
    call nl
    xor si, si                      ; dump the first 4 non-empty sectors: hex, then text
.d: cmp si, 4
    jae .done
    movzx bx, byte [nz_n]
    cmp si, bx
    jae .done
    push si
    movzx bx, byte [nz_list + si]
    mov ax, bx
    shl ax, 9                       ; offset of that sector inside the 0x4000 buffer
    mov si, ax
    mov bx, 0x4000
    mov di, bigbuf
    mov dx, ds
    mov cx, 32
    call farcopy
    pop si
    movzx bx, byte [nz_list + si]
    SAY "  LBA "
    movzx ax, byte [nz_list + si]
    inc ax
    call dec16
    SAY " (first 64 bytes):", 10
    push si
    mov si, bigbuf
    mov cx, 64
    call hexdump
    SAY "  text: "
    mov si, bigbuf
    mov cx, 64
.t: lodsb
    cmp al, 32
    jb .dot
    cmp al, 126
    jbe .p
.dot:
    mov al, '.'
.p: call putc
    dec cx
    jnz .t
    call nl
    pop si
    inc si
    jmp .d
.done:
    ret
%endif

; ============================================================ hard-disk loader mode
; Assembled with -DHDDMODE and installed into sectors 1..STAGE_SECTORS of the internal disk by
; the stick's installer.  It reads its config from the disk, offers Z (ZETA, patched) / W
; (Windows, original boot code) and can never write to any disk.
%ifdef HDDMODE
hdd_main:
    mov byte [log_on], 0
    mov eax, HDD_CONFIG_LBA
    mov di, cfgbuf
    call rd_sector
    jc .nocfg
    cmp dword [cfgbuf], 'BEOS'
    jne .nocfg
    call parse_config
.nocfg:
    mov al, [boot_drive]            ; chain the same disk we were loaded from
    xor ah, ah
    mov [cfg_bootdrv], ax
    cmp word [cfg_auto], 0
    jne .t
    mov word [cfg_auto], 5
.t: call a20_setup
    SAY "855gm-vram-unlock disk loader", 10
    SAY " Z or Enter = ZETA / BeOS (video patch)     W = Windows", 10
    SAY " default in "
    mov ax, [cfg_auto]
    call dec16
    SAY " seconds. Hold SHIFT at power-on to skip this loader.", 10
    mov ax, [cfg_auto]
    call wait_key
    cmp al, 'W'
    je hdd_windows
    test al, al
    jnz hdd_zeta
    cmp word [cfg_bootsel], 1       ; timeout: BOOTSEL=1 makes Windows the default
    je hdd_windows
hdd_zeta:
    cmp word [cfg_patch], 0
    je .go
    call vmem_patch
    jnc .go
    SAY "!! video patch failed - starting ZETA without it", 10
.go:
    mov byte [want_part], 1
    cmp word [cfg_part], 0
    jne .p
    mov word [cfg_part], 9
.p: call chainload
    SAY "!! could not start the ZETA partition, falling back to Windows", 10
hdd_windows:
    mov dword [dio_lba], HDD_BACKUP_LBA     ; original MBR code ...
    mov word [dio_cnt], 1
    mov word [dio_off], 0x7C00
    mov word [dio_seg], 0
    mov byte [dio_write], 0
    call disk_io
    jc .fail
    mov eax, 0                              ; ... with the CURRENT partition table
    mov di, bigbuf
    call rd_sector
    jc .fail
    xor ax, ax
    mov es, ax
    mov si, bigbuf + 0x1B8
    mov di, 0x7C00 + 0x1B8
    mov cx, 36
    cld
    rep movsw
    push ds
    pop es
    xor ax, ax
    mov fs, ax
    cmp word [fs:0x7DFE], 0xAA55
    jne .fail
    mov dl, [boot_drive]
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    xor si, si
    xor di, di
    jmp 0x0000:0x7C00
.fail:
    SAY "!! the saved original boot sector is unreadable - use the stick", 10
.h: hlt
    jmp .h

hdd_install:
hdd_uninstall:
    ret
%endif

; ======================================================== installer (stick only)
; Writes the loader into sectors 1..62 of the internal disk and swaps the MBR code last.
; Order: check -> save original MBR on the stick -> write+verify sectors 1..62 -> write+verify
; the new MBR.  Nothing changes the boot path until the final write, and each step is read back.
%ifndef HDDMODE
H_ORIG   equ 0x4000             ; sectors 0..62 read from the disk
H_STAGE  equ 0x5000             ; loader image (STAGE_SECTORS) read from the stick
H_RB     equ 0x6000             ; read-back buffer
H_NEW    equ 0x7000             ; the gap image to write (62 sectors)
H_MBR    equ 0x8000             ; the new MBR
GAP_SECT equ 62
BACK_OFF equ (HDD_BACKUP_LBA - 1) * 512
CONF_OFF equ (HDD_CONFIG_LBA - 1) * 512
MARK_OFF equ (HDD_MARK_LBA - 1) * 512

s_install: db "INSTALL", 0
s_uninst:  db "UNINSTALL", 0
s_mark:    db "BVBPHDD1"

farcopy:                        ; BX:SI -> DX:DI, CX words
    push ds
    push es
    mov ds, bx
    mov es, dx
    cld
    rep movsw
    pop es
    pop ds
    ret

farzero:                        ; DX:DI, CX words
    push es
    mov es, dx
    xor ax, ax
    cld
    rep stosw
    pop es
    ret

farcmp:                         ; BX:SI vs DX:DI, CX bytes (CX > 0) -> ZF if equal
    push ds
    push es
    mov ds, bx
    mov es, dx
    cld
    repe cmpsb
    pop es
    pop ds
    ret

stick_rd:                       ; EAX = lba, CX = sectors, BX = segment (offset 0); boot drive
    mov [dio_lba], eax
    mov [dio_cnt], cx
    mov word [dio_off], 0
    mov [dio_seg], bx
    mov byte [dio_write], 0
    jmp disk_io

hdd_target:                     ; the internal disk is 0x81 when the stick is 0x80, else 0x80
    mov byte [tgt], 0x80
    cmp byte [boot_drive], 0x80
    jne .d
    mov byte [tgt], 0x81
.d: ret

hdd_io:                         ; EAX = lba, CX = sectors, BX:DI = buffer, [h_wr] = 0/1 -> CF
    mov [h_lba], eax
    mov [h_cnt], cx
    mov [h_seg], bx
    mov [h_off], di
    mov byte [h_cf], 1
    mov dl, [tgt]
    call probe_drive
    jc .back
    mov eax, [h_lba]
    mov [dio_lba], eax
    mov ax, [h_cnt]
    mov [dio_cnt], ax
    mov ax, [h_off]
    mov [dio_off], ax
    mov ax, [h_seg]
    mov [dio_seg], ax
    mov al, [h_wr]
    mov [dio_write], al
    mov [hdd_wr_ok], al
    call disk_io
    jc .back
    mov byte [h_cf], 0
.back:
    mov byte [hdd_wr_ok], 0
    mov dl, [boot_drive]            ; logging context goes back to the stick
    call probe_drive
    cmp byte [h_cf], 0
    jne .fail
    clc
    ret
.fail:
    stc
    ret

confirm_typed:                  ; SI = expected text (uppercase); CF = no match
    mov di, typebuf
    xor cx, cx
.k: xor ax, ax
    int 0x16
    cmp al, 0x0D
    je .done
    cmp al, 0x08
    jne .c
    test cx, cx
    jz .k
    dec di
    dec cx
    mov al, 8
    call putc
    mov al, ' '
    call putc
    mov al, 8
    call putc
    jmp .k
.c: cmp al, ' '
    jb .k
    cmp cx, 16
    jae .k
    cmp al, 'a'
    jb .u
    cmp al, 'z'
    ja .u
    sub al, 0x20
.u: mov [di], al
    inc di
    inc cx
    call putc
    jmp .k
.done:
    mov byte [di], 0
    call nl
    mov di, typebuf
.m: mov al, [si]
    cmp al, [di]
    jne .no
    test al, al
    jz .yes
    inc si
    inc di
    jmp .m
.yes:
    clc
    ret
.no:
    stc
    ret

; checks the sectors read into H_ORIG; sets gap_err (0 = ok) and CF
hdd_check_gap:
    push es
    mov ax, H_ORIG
    mov es, ax
    mov byte [gap_err], 1                   ; no MBR signature
    cmp word [es:0x1FE], 0xAA55
    jne .out
    mov byte [gap_err], 2                   ; already installed
    mov si, s_mark
    mov di, MARK_OFF + 512
    mov cx, 8
    cld
    repe cmpsb
    je .out
    mov byte [gap_err], 3                   ; no partitions
    xor bx, bx
    mov cx, 4
    mov di, 0x1BE
.p: cmp byte [es:di + 4], 0
    je .np
    inc bx
    mov byte [gap_err], 4                   ; a partition starts inside the gap
    cmp dword [es:di + 8], 63
    jb .out
.np:
    add di, 16
    dec cx
    jnz .p
    mov byte [gap_err], 3
    test bx, bx
    jz .out
    mov byte [gap_err], 5                   ; gap not empty
    mov di, 512
    mov cx, GAP_SECT * 512
    xor al, al
    repe scasb
    jne .out
    mov byte [gap_err], 0
.out:
    pop es
    cmp byte [gap_err], 0
    je .ok
    stc
    ret
.ok:
    clc
    ret

gap_report:
    mov al, [gap_err]
    cmp al, 1
    jne .2
    SAY "!! the disk has no valid MBR signature, refusing", 10
    ret
.2: cmp al, 2
    jne .3
    SAY "!! the loader is already installed here. Use U first if you want to reinstall.", 10
    ret
.3: cmp al, 3
    jne .4
    SAY "!! the disk's partition table is empty, refusing", 10
    ret
.4: cmp al, 4
    jne .5
    SAY "!! a partition starts before sector 63, so there is no free gap, refusing", 10
    ret
.5: SAY "!! sectors 1-62 are not empty (another boot loader?), refusing to overwrite them", 10
    ret

hdd_install:
    SAY "--- INSTALL THE LOADER ON THE INTERNAL HARD DISK ---", 10
    SAY "Writes the disk's boot area (sectors 0-62) so the video patch runs without this stick.", 10
    SAY "The original boot sector is saved on the disk AND on the stick (MBRORIG.BIN).", 10
    SAY "Afterwards: hold SHIFT at power-on to skip the loader; menu key U undoes everything.", 10
    SAY "Type INSTALL and press Enter (anything else cancels): "
    mov si, s_install
    call confirm_typed
    jnc .go
    SAY "cancelled, nothing was written", 10
    ret
.go:
    call hdd_target
    mov byte [h_wr], 0
    xor eax, eax
    mov cx, 63
    mov bx, H_ORIG
    xor di, di
    call hdd_io
    jnc .rd
    SAY "!! could not read the internal disk, nothing was written", 10
    ret
.rd:
    call hdd_check_gap
    jnc .ok1
    call gap_report
    ret
.ok1:
    SAY "disk checks passed: valid MBR, partitions start at or after sector 63, gap is empty", 10
    mov eax, STAGEHDD_LBA
    mov cx, STAGE_SECTORS
    mov bx, H_STAGE
    call stick_rd
    jnc .s1
    SAY "!! could not read the loader image from the stick, nothing was written", 10
    ret
.s1:
    mov eax, MBRHDD_LBA
    mov cx, 1
    mov bx, H_MBR
    call stick_rd
    jnc .s2
    SAY "!! could not read the MBR code from the stick, nothing was written", 10
    ret
.s2:
    xor si, si
    mov bx, H_ORIG
    mov di, bigbuf
    mov dx, ds
    mov cx, 256
    call farcopy                    ; original MBR -> bigbuf
    mov eax, MBRORIG_LBA
    mov di, bigbuf
    call wr_sector
    jnc .s3
    SAY "!! could not save the original MBR on the stick, nothing was written to the disk", 10
    ret
.s3:
    SAY "original MBR saved on the stick", 10
    xor di, di                      ; build the gap image: zeros + loader + backup + config + marker
    mov dx, H_NEW
    mov cx, GAP_SECT * 256
    call farzero
    xor si, si
    mov bx, H_STAGE
    xor di, di
    mov dx, H_NEW
    mov cx, STAGE_SECTORS * 256
    call farcopy
    xor si, si
    mov bx, H_ORIG
    mov di, BACK_OFF
    mov dx, H_NEW
    mov cx, 256
    call farcopy
    mov si, cfgbuf
    mov bx, ds
    mov di, CONF_OFF
    mov dx, H_NEW
    mov cx, 256
    call farcopy
    mov si, s_mark
    mov bx, ds
    mov di, MARK_OFF
    mov dx, H_NEW
    mov cx, 4
    call farcopy
    mov byte [h_wr], 1
    mov eax, 1
    mov cx, GAP_SECT
    mov bx, H_NEW
    xor di, di
    call hdd_io
    jnc .w1
    SAY "!! writing sectors 1-62 failed; the boot sector is unchanged", 10
    ret
.w1:
    mov byte [h_wr], 0
    mov eax, 1
    mov cx, GAP_SECT
    mov bx, H_RB
    xor di, di
    call hdd_io
    jc .rb
    xor si, si
    mov bx, H_NEW
    xor di, di
    mov dx, H_RB
    mov cx, GAP_SECT * 512
    call farcmp
    je .w1ok
.rb:
    SAY "!! read-back of sectors 1-62 differs; the boot sector is unchanged (menu U cleans up)", 10
    ret
.w1ok:
    SAY "loader, saved MBR and config written to sectors 1-62 and verified", 10
    mov si, 0x1B8                   ; new MBR = our code + the ORIGINAL signature and partition table
    mov bx, H_ORIG
    mov di, 0x1B8
    mov dx, H_MBR
    mov cx, 36
    call farcopy
    push es
    mov ax, H_MBR
    mov es, ax
    cmp word [es:0x1FE], 0xAA55
    pop es
    je .sigok
    SAY "!! internal error: new MBR has no signature, not writing it", 10
    ret
.sigok:
    mov byte [h_wr], 1
    xor eax, eax
    mov cx, 1
    mov bx, H_MBR
    xor di, di
    call hdd_io
    jnc .w2
    SAY "!! writing the boot sector failed (BIOS virus protection?); the disk boots as before", 10
    ret
.w2:
    mov byte [h_wr], 0
    xor eax, eax
    mov cx, 1
    mov bx, H_RB
    xor di, di
    call hdd_io
    jc .mb
    xor si, si
    mov bx, H_MBR
    xor di, di
    mov dx, H_RB
    mov cx, 512
    call farcmp
    je .done
.mb:
    SAY "!! boot sector read-back differs! Hold SHIFT at power-on, or run U; MBRORIG.BIN has the original", 10
    ret
.done:
    SAY "boot sector written and verified. INSTALLED.", 10
    SAY "Power off, remove the stick, power on: the loader menu appears. SHIFT skips it.", 10
    ret

hdd_uninstall:
    SAY "--- UNINSTALL THE LOADER FROM THE INTERNAL HARD DISK ---", 10
    SAY "Restores the original boot code (keeping the current partition table) and clears sectors 1-62.", 10
    SAY "Type UNINSTALL and press Enter (anything else cancels): "
    mov si, s_uninst
    call confirm_typed
    jnc .go
    SAY "cancelled, nothing was written", 10
    ret
.go:
    call hdd_target
    mov byte [h_wr], 0
    xor eax, eax
    mov cx, 63
    mov bx, H_ORIG
    xor di, di
    call hdd_io
    jnc .rd
    SAY "!! could not read the internal disk, nothing was written", 10
    ret
.rd:
    push es
    mov ax, H_ORIG
    mov es, ax
    mov byte [gap_err], 1                   ; 1 = marker missing
    mov si, s_mark
    mov di, MARK_OFF + 512
    mov cx, 8
    cld
    repe cmpsb
    jne .m1
    mov byte [gap_err], 2                   ; 2 = backup damaged
    cmp word [es:BACK_OFF + 512 + 510], 0xAA55
    jne .m1
    mov byte [gap_err], 0
.m1:
    pop es
    cmp byte [gap_err], 0
    je .ok1
    cmp byte [gap_err], 1
    jne .bk
    SAY "the loader is not installed here (no marker), nothing to do", 10
    ret
.bk:
    SAY "!! the saved original MBR on the disk is damaged, refusing. Use MBRORIG.BIN from the stick.", 10
    ret
.ok1:
    xor si, si                              ; original code (backup) ...
    mov bx, H_ORIG
    mov si, BACK_OFF + 512
    xor di, di
    mov dx, H_MBR
    mov cx, 256
    call farcopy
    xor si, si                              ; ... plus the current table
    mov si, 0x1B8
    mov bx, H_ORIG
    mov di, 0x1B8
    mov dx, H_MBR
    mov cx, 36
    call farcopy
    mov byte [h_wr], 1
    xor eax, eax
    mov cx, 1
    mov bx, H_MBR
    xor di, di
    call hdd_io
    jnc .w1
    SAY "!! writing the boot sector failed; nothing changed", 10
    ret
.w1:
    mov byte [h_wr], 0
    xor eax, eax
    mov cx, 1
    mov bx, H_RB
    xor di, di
    call hdd_io
    jc .rb1
    xor si, si
    mov bx, H_MBR
    xor di, di
    mov dx, H_RB
    mov cx, 512
    call farcmp
    je .w1ok
.rb1:
    SAY "!! boot sector read-back differs! use MBRORIG.BIN from the stick", 10
    ret
.w1ok:
    SAY "original boot code restored and verified", 10
    xor di, di
    mov dx, H_NEW
    mov cx, GAP_SECT * 256
    call farzero
    mov byte [h_wr], 1
    mov eax, 1
    mov cx, GAP_SECT
    mov bx, H_NEW
    xor di, di
    call hdd_io
    jnc .done
    SAY "(the original boot sector is back; clearing sectors 1-62 failed, which is harmless)", 10
    ret
.done:
    SAY "UNINSTALLED. The disk boots as it did before the install.", 10
    ret
%endif

install_hook:
    xor ax, ax
    mov fs, ax
    mov ax, [gs:0x13]
    dec ax
    mov [gs:0x13], ax
    shl ax, 6
    mov es, ax
    mov si, hook_img
    xor di, di
    mov cx, hook_end - hook_img
    cld
    rep movsb
    mov eax, [fs:0x13 * 4]
    mov [es:H(h_old)], eax
    mov al, [tgt]
    mov [es:H(h_tgt)], al
    cli
    mov word [fs:0x13 * 4], H(hook_entry)
    mov [fs:0x13 * 4 + 2], es
    sti
    mov byte [hook_on], 1
    push ds
    pop es
    ret

; Resident INT 13h shim: swaps drive numbers 0x80 and tgt so a boot loader
; that insists on booting from 0x80 reaches the internal disk.
hook_img:
h_old: dd 0
h_tgt: db 0
h_sdl: db 0
h_sah: db 0
hook_entry:
    cmp dl, 0x80
    je .m1
    cmp dl, [cs:H(h_tgt)]
    je .m2
    jmp far [cs:H(h_old)]
.m1:
    mov [cs:H(h_sdl)], dl
    mov dl, [cs:H(h_tgt)]
    jmp short .go
.m2:
    mov [cs:H(h_sdl)], dl
    mov dl, 0x80
.go:
    mov [cs:H(h_sah)], ah
    pushf
    call far [cs:H(h_old)]
    pushf
    cmp byte [cs:H(h_sah)], 8
    je .k
    mov dl, [cs:H(h_sdl)]
.k: popf
    retf 2
hook_end:

; ===================================================================== data
section .data

run_lbas: dd RUN0_LBA, RUN1_LBA, RUN2_LBA, RUN3_LBA

cfg_patch:   dw 0
cfg_mode:    dw 0
cfg_src:     dw 0
cfg_bpp:     dw 0
cfg_testset: dw 1
cfg_auto:    dw 0
cfg_pause:   dw 1
cfg_bootdrv: dw 0
cfg_fake:    dw 0
cfg_bootsel: dw 0
cfg_vmem:    dw 4096
cfg_selftest: dw 1
cfg_part:    dw 0

cfgtab:
    dw k_patch, 10, cfg_patch
    dw k_mode, 16, cfg_mode
    dw k_src, 16, cfg_src
    dw k_bpp, 10, cfg_bpp
    dw k_testset, 10, cfg_testset
    dw k_auto, 10, cfg_auto
    dw k_pause, 10, cfg_pause
    dw k_bootdrv, 16, cfg_bootdrv
    dw k_fake, 10, cfg_fake
    dw k_bootsel, 10, cfg_bootsel
    dw k_vmem, 10, cfg_vmem
    dw k_selftest, 10, cfg_selftest
    dw k_part, 10, cfg_part
    dw 0
k_patch:   db "PATCH", 0
k_mode:    db "MODE", 0
k_src:     db "SRC", 0
k_bpp:     db "BPP", 0
k_testset: db "TESTSET", 0
k_auto:    db "AUTOBOOT", 0
k_pause:   db "PAUSE", 0
k_bootdrv: db "BOOTDRV", 0
k_fake:    db "FAKEVB", 0
k_bootsel: db "BOOTSEL", 0
k_vmem:    db "VMEM", 0
k_selftest: db "SELFTEST", 0
k_part:    db "PART", 0

; ===================================================================== bss
section .bss align=16

bss_start:
boot_drive: resb 1
log_on:     resb 1
pc_ch:      resb 1
dio_write:  resb 1
dio_try:    resb 1
cur_drv:    resb 1
cur_ext:    resb 1
tgt:        resb 1
swap:       resb 1
pam_used:   resb 1
pam_save:   resb 1
p_status:   resb 1
ld_n:       resb 1
            alignb 4
cur_heads:  resd 1
cur_spt:    resd 1
dio_lba:    resd 1
dio_cnt:    resw 1
dio_off:    resw 1
dio_seg:    resw 1
chs_lba:    resd 1
chs_off:    resw 1
chs_n:      resw 1
log_lba:    resd 1
log_end:    resd 1
logpos:     resw 1
run_no:     resw 1
vb_seg:     resw 1
mt_off:     resw 1
mt_cnt:     resw 1
dump_lba_lo: resw 1
dv_lba:     resd 1
sum1:       resd 1
sum2:       resd 1
pci_base:   resd 1
p_srcres:   resw 1
p_count:    resw 1
p_entry:    resw 1
rd_ok:      resb 1
hd_gap:     resb 1
nz_n:       resb 1
nz_list:    resb 64
hdd_wr_ok:  resb 1
h_wr:       resb 1
h_cf:       resb 1
gap_err:    resb 1
h_lba:      resd 1
h_cnt:      resw 1
h_seg:      resw 1
h_off:      resw 1
typebuf:    resb 20
part_eff:   resw 1
want_part:  resb 1
pbr_lba:    resd 1
pbr_ent:    resw 1
hd_drv:     resb 1
hd_ok:      resb 1
hd_pn:      resb 1
vr_top:     resd 1
vr_elen:    resd 1
vr_hide:    resd 1
vr_base:    resd 1
k_er0:      resd 1
k_er1:      resd 1
k_er2:      resd 1
kgt:        resd 5
dg_mode:    resw 1
dg_gtt:     resd 1
dg_ap:      resd 1
dgbuf:      resd 40
a20_was:    resw 1
g_ax:       resw 1
g_pitch:    resw 1
g_lfb:      resd 1
d_start:    resw 1
d_end:      resw 1
d_xor:      resd 1
d_pitch:    resd 1
regbuf:     resd 40
io_base:    resw 1
swf_old:    resd 1
gtt_base:   resd 1
gtt_firstinv: resd 1
ut_a:       resd 1
ut_b:       resd 1
ut_c:       resd 1
gcc1_old:   resw 1
cd_drv:     resb 1
cd_i:       resb 1
cd_try:     resb 1
cd_media:   resb 1
cd_err:     resb 1
boot_kind:  resb 1
want_patch: resb 1
hook_on:    resb 1
cd_lba:     resd 1
cd_rba:     resd 1
cd_cnt:     resw 1
cd_off:     resw 1
cd_seg:     resw 1
cd_ldseg:   resw 1
cd_count:   resw 1
pb_before:  resb 5
pb_after:   resb 5
ld_dx:      resw 1
ld_cx:      resw 1
vbe_n:      resw 1
vbe_ax:     resw 1
cur_mode:   resw 1
cand_n:     resw 1
cand_bytes: resw 1
cand:       resw 16
t_mode:     resw 1
t_val:      resw 1
t_ax:       resw 1
t_cur:      resw 1
dap:        resb 16
e820buf:    resb 32
dpbuf:      resb 32
strbuf:     resb 64
vhdr:       resb 64
vbemodes:   resw 130
            alignb 4
logbuf:     resb 512
cntbuf:     resb 512
cfgbuf:     resb 512
vbebuf:     resb 512
modebuf:    resb 256
pcibuf:     resb 256
bigbuf:     resb 4096
gttb1:      resb 4096
bss_end:
