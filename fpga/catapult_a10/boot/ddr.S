// ddr.S
// B5-SoC/Boot: DDR 0x40000000 trampoline（验证跳转后 DDR 可执行）。

.section .text.ddr, "ax"
.global ddr_entry

ddr_entry:
    ldr     x0, =0x09000000
    adrp    x1, ddr_marker
    add     x1, x1, :lo12:ddr_marker
    bl      ddr_puts
ddr_hang:
    b       ddr_hang

ddr_puts:
    ldrb    w2, [x1], #1
    cbz     w2, 2f
    str     w2, [x0]
    b       ddr_puts
2:
    ret

.section .rodata.ddr
ddr_marker:
    .asciz "DDR-OK\r\n"
