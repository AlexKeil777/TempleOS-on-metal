; boot.asm - USB/hard-disk boot sector for TempleOS running from a RAM disk.
; Assembled by mkusb.py:
;   nasm -f bin -DRAMDSK_BASE=n -DIMG_SECTS=n -DKERNEL_BLK=n -DKERNEL_BYTES=n
;        -DDISK_SECTS=n boot.asm
;
; TempleOS has no USB driver, so it can't read the stick once the BIOS is gone.
; The disk image therefore *is* the RAM disk: disk sector n = block n of drive
; A:.  This sector (block 0) uses the BIOS to copy the first IMG_SECTS sectors
; to RAMDSK_BASE, copies the kernel file out of that copy to 0:7C00 and enters
; it the way TempleOS's own BootHD does.  The kernel (built by mkusb.py) mounts
; A: on the memory at RAMDSK_BASE (16MB) and keeps its heap away from it.

REDSEA_BLK       equ 88         ; RedSea file system starts here, as on the ISO
BUF              equ 0x10000    ; bounce buffer for BIOS reads (32K, real-mode RAM)
CHUNK            equ 64         ; sectors per read; small on purpose for picky USB BIOSes
KERNEL_ADDR      equ 0x7C00     ; BOOT_RAM_BASE in KernelA.HH
BOOT_SRC_HARDDRV equ 3          ; makes /Once.HC skip its "install to hard drive?" prompt

%if IMG_SECTS % CHUNK
%error IMG_SECTS must be a multiple of CHUNK
%endif

        bits 16
        org 0x600

start:  cli                             ; BIOS loaded us at 0:7C00, where the kernel must go
        xor ax, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ds, ax
        mov es, ax
        cld
        mov si, 0x7C00
        mov di, 0x600
        mov cx, 256
        rep movsw
        jmp 0:main

main:   sti
        mov [drive], dl
        mov si, msg_name
        call puts

        mov eax, 0x80000000             ; long mode? same test as TempleOS's BootDVD
        cpuid
        cmp eax, 0x80000001
        jb no64
        mov eax, 0x80000001
        cpuid
        bt edx, 29
        jnc no64

        call unreal                     ; A20 really on? 1MB+start must not alias start
        mov ax, [start]                 ; (start has already run, so it's free scratch)
        not ax
        mov [dword 0x100000+start], ax
        cmp ax, [start]
        je noa20

.read:  mov byte [tries], 3
.try:   mov si, dap
        mov dl, [drive]
        mov ah, 0x42                    ; extended read, LBA
        int 0x13
        jnc .copy
        xor ah, ah                      ; reset the drive and try again
        mov dl, [drive]
        int 0x13
        dec byte [tries]
        jnz .try
        mov si, msg_disk
        jmp die

.copy:  call unreal                     ; the BIOS call may have undone it
        mov esi, BUF
        mov edi, [dest]
        mov ecx, CHUNK*512/4
        a32 rep movsd
        mov [dest], edi
        add dword [dap.lba], CHUNK
        test byte [chunks], 15          ; a dot every 16 chunks (512K)
        jnz .next
        mov al, '.'
        call putc
.next:  dec word [chunks]
        jnz .read

        call unreal
        mov esi, RAMDSK_BASE + KERNEL_BLK*512
        mov edi, KERNEL_ADDR
        mov ecx, (KERNEL_BYTES+3)/4
        a32 rep movsd
        mov eax, BOOT_SRC_HARDDRV       ; KStart16.HC: EAX=boot src, EBX=boot blk
        xor ebx, ebx
        xor edx, edx                    ; Tidy registers, as from a BIOS.  Except ESI: KStart16 used
        xor edi, edi                    ; to read its memory map from the wrong megabyte when ESI's
        xor ebp, ebp                    ; top half wasn't 0, as it isn't now.  mkusb.py patches that
        movzx esp, sp                   ; (TempleOS's own hard disk boot needs it), so test it here.
        jmp (KERNEL_ADDR>>4):0          ; CBinFile header starts with a jmp to the code

; A20 on (port 0x92, the one method the kernel itself relies on) and 4GB segment
; limits for DS/ES ("unreal mode"), so real-mode code can reach RAMDSK_BASE.
unreal: cli
        in al, 0x92
        test al, 2
        jnz .a20
        or al, 2
        and al, 0xFE                    ; bit 0 is "reset the machine"
        out 0x92, al
.a20:   lgdt [gdtr]
        mov eax, cr0
        or al, 1
        mov cr0, eax
        mov bx, 8
        mov ds, bx
        mov es, bx
        and al, 0xFE
        mov cr0, eax
        xor bx, bx
        mov ds, bx
        mov es, bx
        sti
        cld
        ret

no64:   mov si, msg_no64
        jmp die
noa20:  mov si, msg_a20
die:    call puts
.hang:  hlt
        jmp .hang

puts:   cld
        lodsb
        test al, al
        jz putc.ret
        call putc
        jmp puts
putc:   mov ah, 0x0E
        mov bx, 7
        int 0x10
.ret:   ret

msg_name db "TempleOS", 0
msg_no64 db " needs a 64-bit CPU", 0
msg_a20  db " A20 error", 0
msg_disk db " disk read error", 0
drive    db 0
tries    db 0
chunks   dw IMG_SECTS/CHUNK
dest     dd RAMDSK_BASE
dap:     db 16, 0
         dw CHUNK
         dw 0, BUF>>4
.lba:    dq 0                           ; start with this very sector
gdtr:    dw 15
         dd gdt
gdt:     dq 0, 0x00CF92000000FFFF       ; null, flat 4GB data

%macro chs 1                            ; LBA as CHS for a 255 head, 63 sector disk
        db ((%1)/63) % 255
        db ((%1) % 63 + 1) | ((((%1)/(63*255)) >> 8) << 6)
        db ((%1)/(63*255)) & 0xFF
%endmacro

        times 440-($-$$) db 0           ; fails to assemble if the code outgrows the MBR
        dd 0x21534F54                   ; disk signature; non-zero so Windows won't write one
        dw 0
        db 0x80                         ; one active partition: the RedSea file system,
        chs REDSEA_BLK                  ; so the stick is also a valid TempleOS disk
        db 0x88                         ; MBR_PT_REDSEA
        chs DISK_SECTS-1
        dd REDSEA_BLK, DISK_SECTS-REDSEA_BLK
        times 48 db 0
        dw 0xAA55
