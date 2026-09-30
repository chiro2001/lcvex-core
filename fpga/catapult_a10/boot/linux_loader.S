// Standalone AArch64 Flash-to-DDR Linux loader for the Catapult A10 BRAM.
//
// All addresses and descriptor fields come from linux_flash_layout.json via
// the generated linux_layout.inc. The Flash aperture is still a candidate
// platform interface; this image is not wired into the current SoC top.

.include "linux_layout.inc"
.include "linux_crc32_table.inc"

.equ ERROR_CAL_FAILED, 1
.equ ERROR_CAL_TIMEOUT, 2
.equ ERROR_FORMAT, 3
.equ ERROR_RANGE, 4
.equ ERROR_DESCRIPTOR_CRC, 5
.equ ERROR_SEGMENT_CRC, 6
.equ ERROR_COPY_CRC, 7
.equ ERROR_CPU_CONTEXT, 8

.section .text.boot, "ax"
.global _start
.type _start, %function

_start:
    ldr     x0, =STACK_TOP
    mov     sp, x0
    ldr     x1, =last_error
    str     wzr, [x1]

    // The fixed CPU addresses below are physical addresses. Check the active
    // exception level's SCTLR before touching the memory map.
    mrs     x14, CurrentEL
    lsr     x14, x14, #2
    cmp     x14, #1
    b.eq    check_el1_context
    cmp     x14, #2
    b.eq    check_el2_context
    cmp     x14, #3
    b.eq    check_el3_context
    b       fail_cpu_context
check_el1_context:
    mrs     x0, SCTLR_EL1
    b       check_physical_context
check_el2_context:
    mrs     x0, SCTLR_EL2
    b       check_physical_context
check_el3_context:
    mrs     x0, SCTLR_EL3
check_physical_context:
    tbnz    x0, #0, fail_cpu_context   // physical fixed-address reads need M=C=0
    tbnz    x0, #2, fail_cpu_context

    ldr     x0, =msg_banner
    bl      uart_puts
    bl      wait_for_calibration
    cmp     w0, #0
    b.eq    loader_start
    cmp     w0, #1
    b.eq    fail_calibration
    b       fail_calibration_timeout

loader_start:
    ldr     x29, =FLASH_APERTURE_BASE
    ldr     x9, =FLASH_PAYLOAD_OFFSET
    add     x29, x29, x9

    // Header: magic[8], version, header size, segment count, segment size,
    // entry address, DTB address. The trailer CRC covers header + table.
    ldr     x0, [x29]
    ldr     x1, =FORMAT_MAGIC_LE
    cmp     x0, x1
    b.ne    fail_format
    ldr     w0, [x29, #8]
    cmp     w0, #FORMAT_VERSION
    b.ne    fail_format
    ldr     w0, [x29, #12]
    cmp     w0, #HEADER_SIZE
    b.ne    fail_format
    ldr     w0, [x29, #16]
    cmp     w0, #SEGMENT_COUNT
    b.ne    fail_format
    ldr     w0, [x29, #20]
    cmp     w0, #SEGMENT_SIZE
    b.ne    fail_format
    ldr     x19, [x29, #24]              // Linux Image entry
    ldr     x20, [x29, #32]              // DTB address passed in x0

    mov     x18, #HEADER_SIZE
    mov     x9, #(SEGMENT_COUNT * SEGMENT_SIZE)
    add     x18, x18, x9                 // bytes covered by descriptor CRC
    add     x12, x29, x18
    ldr     w15, [x12]                   // descriptor CRC32
    ldr     w0, [x12, #4]
    cbnz    w0, fail_format              // reserved trailer word
    mov     x0, x29
    mov     x1, x18
    bl      crc32_buffer
    cmp     w0, w15
    b.ne    fail_descriptor_crc

    // This version has exactly two ordered entries: kernel then DTB.
    // Keeping the role order fixed makes entry/DTB cross-checking explicit.
    add     x9, x29, #HEADER_SIZE
    ldr     w10, [x9, #28]
    cmp     w10, #SEG_KERNEL
    b.ne    fail_format
    ldr     x21, [x9]                    // kernel Flash offset
    ldr     x22, [x9, #8]                // kernel DDR destination
    ldr     x23, [x9, #16]               // kernel load span
    ldr     w24, [x9, #24]               // kernel CRC32

    add     x9, x9, #SEGMENT_SIZE
    ldr     w10, [x9, #28]
    cmp     w10, #SEG_DTB
    b.ne    fail_format
    ldr     x25, [x9]                    // DTB Flash offset
    ldr     x26, [x9, #8]                // DTB DDR destination
    ldr     x27, [x9, #16]               // DTB length
    ldr     w28, [x9, #24]               // DTB CRC32

    // The first data segment must start after the descriptor and its trailer.
    add     x9, x18, #TRAILER_SIZE
    add     x9, x9, #(SEGMENT_ALIGNMENT - 1)
    bic     x18, x9, #(SEGMENT_ALIGNMENT - 1)
    ldr     x9, =FLASH_PAYLOAD_OFFSET
    add     x18, x18, x9                 // minimum absolute Flash source offset

    mov     x0, x21
    mov     x1, x22
    mov     x2, x23
    mov     x3, x18
    bl      validate_segment
    cbnz    w0, fail_range
    mov     x0, x25
    mov     x1, x26
    mov     x2, x27
    mov     x3, x18
    bl      validate_segment
    cbnz    w0, fail_range

    // A pairwise check is sufficient for the fixed two-segment version.
    adds    x9, x21, x23
    b.cs    fail_range
    adds    x10, x25, x27
    b.cs    fail_range
    cmp     x9, x25
    b.ls    flash_ranges_disjoint
    cmp     x10, x21
    b.hi    fail_range
flash_ranges_disjoint:
    adds    x9, x22, x23
    b.cs    fail_range
    adds    x10, x26, x27
    b.cs    fail_range
    cmp     x9, x26
    b.ls    ddr_ranges_disjoint
    cmp     x10, x22
    b.hi    fail_range
ddr_ranges_disjoint:
    // The entry must be executable bytes in the kernel range; x0 at handoff
    // must name the DTB segment exactly.
    tst     x19, #3
    b.ne    fail_format
    cmp     x19, x22
    b.lo    fail_format
    adds    x9, x22, x23
    b.cs    fail_range
    cmp     x19, x9
    b.hs    fail_format
    cmp     x20, x26
    b.ne    fail_format

    ldr     x0, =msg_kernel_check
    bl      uart_puts
    ldr     x0, =FLASH_APERTURE_BASE
    add     x0, x0, x21
    mov     x1, x23
    bl      crc32_buffer
    cmp     w0, w24
    b.ne    fail_segment_crc
    ldr     x0, =FLASH_APERTURE_BASE
    add     x0, x0, x21
    mov     x1, x22
    mov     x2, x23
    bl      copy_buffer
    mov     x0, x22
    mov     x1, x23
    bl      crc32_buffer
    cmp     w0, w24
    b.ne    fail_copy_crc

    ldr     x0, =msg_dtb_check
    bl      uart_puts
    ldr     x0, =FLASH_APERTURE_BASE
    add     x0, x0, x25
    mov     x1, x27
    bl      crc32_buffer
    cmp     w0, w28
    b.ne    fail_segment_crc
    ldr     x0, =FLASH_APERTURE_BASE
    add     x0, x0, x25
    mov     x1, x26
    mov     x2, x27
    bl      copy_buffer
    mov     x0, x26
    mov     x1, x27
    bl      crc32_buffer
    cmp     w0, w28
    b.ne    fail_copy_crc

    ldr     x0, =msg_load_ok
    bl      uart_puts
    b       linux_handoff

fail_calibration:
    mov     w1, #ERROR_CAL_FAILED
    ldr     x0, =msg_cal_failed
    b       report_failure

fail_calibration_timeout:
    mov     w1, #ERROR_CAL_TIMEOUT
    ldr     x0, =msg_cal_timeout
    b       report_failure

fail_format:
    mov     w1, #ERROR_FORMAT
    ldr     x0, =msg_format
    b       report_failure

fail_range:
    mov     w1, #ERROR_RANGE
    ldr     x0, =msg_range
    b       report_failure

fail_descriptor_crc:
    mov     w1, #ERROR_DESCRIPTOR_CRC
    ldr     x0, =msg_descriptor_crc
    b       report_failure

fail_segment_crc:
    mov     w1, #ERROR_SEGMENT_CRC
    ldr     x0, =msg_segment_crc
    b       report_failure

fail_copy_crc:
    mov     w1, #ERROR_COPY_CRC
    ldr     x0, =msg_copy_crc
    b       report_failure

fail_cpu_context:
    mov     w1, #ERROR_CPU_CONTEXT
    ldr     x0, =msg_cpu_context

report_failure:
    ldr     x2, =last_error
    str     w1, [x2]
    bl      uart_puts
    b       loader_monitor

// Wait for real platform calibration status with a timeout measured by the
// 25 MHz free-running cycle counter. Returns w0=0 ready, 1 failed, 2 timeout.
wait_for_calibration:
    ldr     x9, =CYCLE_COUNTER
    ldr     x10, [x9]
    ldr     x11, =CAL_TIMEOUT_CYCLES
1:
    ldr     x12, =PLATFORM_STATUS
    ldr     w13, [x12]
    tst     w13, #CAL_FAILED_MASK
    b.ne    3f
    tst     w13, #CAL_READY_MASK
    b.ne    2f
    ldr     x12, =CYCLE_COUNTER
    ldr     x13, [x12]
    sub     x13, x13, x10
    cmp     x13, x11
    b.hs    4f
    b       1b
2:
    mov     w0, #0
    ret
3:
    mov     w0, #1
    ret
4:
    mov     w0, #2
    ret

// x0=absolute Flash source offset, x1=DDR destination, x2=length,
// x3=minimum permitted absolute Flash source. Returns w0=0 if all checks pass.
validate_segment:
    cmp     x0, x3
    b.lo    9f
    tst     x0, #(SEGMENT_ALIGNMENT - 1)
    b.ne    9f
    tst     x1, #(DDR_ALIGNMENT - 1)
    b.ne    9f
    cbz     x2, 9f
    adds    x9, x0, x2
    b.cs    9f
    ldr     x10, =FLASH_CAPACITY
    cmp     x9, x10
    b.hi    9f
    ldr     x10, =FLASH_APERTURE_SIZE
    cmp     x9, x10
    b.hi    9f
    ldr     x10, =DDR_BASE
    cmp     x1, x10
    b.lo    9f
    adds    x11, x1, x2
    b.cs    9f
    ldr     x12, =DDR_SIZE
    add     x12, x10, x12
    cmp     x11, x12
    b.hi    9f
    mov     w0, #0
    ret
9:
    mov     w0, #1
    ret

// x0=buffer, x1=byte length, w0=CRC-32/ISO-HDLC.
// Aligned words reduce Flash bridge transactions; any tail is handled by byte.
.macro CRC32_TABLE_STEP
    eor     w4, w2, w3
    and     w4, w4, #0xff
    lsr     w2, w2, #8
    ldr     w5, [x6, x4, lsl #2]
    eor     w2, w2, w5
.endm

crc32_buffer:
    mvn     w2, wzr
    ldr     x6, =crc32_table
crc_word_loop:
    cmp     x1, #4
    b.lo    crc_tail
    ldr     w3, [x0], #4
    CRC32_TABLE_STEP
    lsr     w3, w3, #8
    CRC32_TABLE_STEP
    lsr     w3, w3, #8
    CRC32_TABLE_STEP
    lsr     w3, w3, #8
    CRC32_TABLE_STEP
    subs    x1, x1, #4
    b       crc_word_loop
crc_tail:
    cbz     x1, crc_done
    ldrb    w3, [x0], #1
    CRC32_TABLE_STEP
    subs    x1, x1, #1
    b       crc_tail
crc_done:
    mvn     w0, w2
    ret

// x0=source, x1=destination, x2=length. Source and destination are aligned
// by validate_segment; byte tail preserves arbitrary Image/DTB file lengths.
copy_buffer:
copy_word_loop:
    cmp     x2, #4
    b.lo    copy_tail
    ldr     w3, [x0], #4
    str     w3, [x1], #4
    subs    x2, x2, #4
    b       copy_word_loop
copy_tail:
    cbz     x2, copy_done
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    x2, x2, #1
    b       copy_tail
copy_done:
    ret

// Turn each failure into a stable diagnostic state. The BRAM monitor remains
// available for `p` (PONG), `?` (READY), and `r` (retry after fixing the cause).
loader_monitor:
    ldr     x9, =UART_DATA
1:
    ldr     w10, [x9]
    tbz     w10, #15, 1b                // RVALID
    and     w0, w10, #0xff
    cmp     w0, #0x70                    // p
    b.eq    monitor_ping
    cmp     w0, #0x3f                    // ?
    b.eq    monitor_status
    cmp     w0, #0x72                    // r
    b.eq    _start
    b       1b
monitor_ping:
    ldr     x0, =msg_pong
    bl      uart_puts
    b       loader_monitor
monitor_status:
    ldr     x0, =msg_ready
    bl      uart_puts
    b       loader_monitor

// Prepare both loaded ranges for Linux, disable EL1 MMU/data/instruction
// caches, select non-secure EL1h when starting above EL1, and pass only DTB in
// x0. D-cache writes are cleaned before I-cache invalidation and the branch.
linux_handoff:
    mrs     x9, CTR_EL0
    ubfx    x10, x9, #16, #4
    mov     x11, #4
    lsl     x11, x11, x10                // D-cache line bytes
    mov     x12, x22
    add     x13, x22, x23
1:
    dc      cvac, x12
    add     x12, x12, x11
    cmp     x12, x13
    b.lo    1b
    mov     x12, x26
    add     x13, x26, x27
2:
    dc      cvac, x12
    add     x12, x12, x11
    cmp     x12, x13
    b.lo    2b
    dsb     sy
    ic      iallu
    dsb     sy

    mrs     x9, SCTLR_EL1
    mov     x10, #0x1005                 // M, C, I
    bic     x9, x9, x10
    msr     SCTLR_EL1, x9
    dsb     sy
    isb
    msr     daifset, #0xf

    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #1
    b.eq    linux_enter_el1
    cmp     x9, #3
    b.eq    linux_enter_el3
    b       linux_enter_el2

linux_enter_el3:
    // ERET to non-secure AArch64 EL2, then use the same EL2->EL1 path.
    adr     x9, linux_enter_el2
    msr     ELR_EL3, x9
    mov     x9, #0x3c9                  // EL2h, mask Debug/SError/IRQ/FIQ
    msr     SPSR_EL3, x9
    mrs     x9, SCR_EL3
    orr     x9, x9, #(1 << 10)          // SCR_EL3.RW = AArch64 lower ELs
    orr     x9, x9, #1                  // SCR_EL3.NS = non-secure
    msr     SCR_EL3, x9
    isb
    eret

linux_enter_el2:
    // This label also runs after the EL3->non-secure EL2 transition so the
    // non-secure EL1 SCTLR bank is cleared before the final ERET.
    mrs     x9, SCTLR_EL1
    mov     x10, #0x1005                // M, C, I
    bic     x9, x9, x10
    msr     SCTLR_EL1, x9
    isb
    msr     CNTVOFF_EL2, xzr
    mrs     x9, CNTHCTL_EL2
    orr     x9, x9, #3                  // allow EL1 physical counter/timer
    msr     CNTHCTL_EL2, x9
    mrs     x9, HCR_EL2
    orr     x9, x9, #(1 << 31)          // HCR_EL2.RW = AArch64 EL1
    bic     x9, x9, #1                  // HCR_EL2.VM = no stage-2 translation
    msr     HCR_EL2, x9
    adr     x9, linux_enter_el1
    msr     ELR_EL2, x9
    mov     x9, #0x3c5                  // EL1h, mask Debug/SError/IRQ/FIQ
    msr     SPSR_EL2, x9
    isb
    eret

linux_enter_el1:
    mov     x0, x20
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    br      x19

// Polled JTAG-UART helpers. TX has a finite WSPACE wait so a disconnected
// terminal cannot prevent the loader from reaching its safe monitor.
uart_puts:
    stp     x17, x30, [sp, #-16]!
    mov     x17, x0
1:
    ldrb    w0, [x17], #1
    cbz     w0, 2f
    bl      uart_putc
    b       1b
2:
    ldp     x17, x30, [sp], #16
    ret

uart_putc:
    mov     w9, w0
    ldr     x10, =UART_TX_WAIT_LIMIT
1:
    ldr     x11, =UART_CONTROL
    ldr     w12, [x11]
    lsr     w12, w12, #16                // CONTROL.WSPACE
    cbnz    w12, 2f
    subs    x10, x10, #1
    b.ne    1b
    ret                                 // finite timeout: drop this byte
2:
    ldr     x11, =UART_DATA
    str     w9, [x11]
    ret

.section .rodata, "a"
msg_banner:
    .asciz  "LCVX AArch64 Linux loader\r\n"
msg_cal_failed:
    .asciz  "ERR CAL-FAIL; READY\r\n"
msg_cal_timeout:
    .asciz  "ERR CAL-TIMEOUT; READY\r\n"
msg_format:
    .asciz  "ERR FORMAT; READY\r\n"
msg_range:
    .asciz  "ERR RANGE; READY\r\n"
msg_descriptor_crc:
    .asciz  "ERR DESC-CRC; READY\r\n"
msg_segment_crc:
    .asciz  "ERR FLASH-CRC; READY\r\n"
msg_copy_crc:
    .asciz  "ERR DDR-CRC; READY\r\n"
msg_cpu_context:
    .asciz  "ERR CPU-CONTEXT (M/C must be off); READY\r\n"
msg_kernel_check:
    .asciz  "CHECK KERNEL\r\n"
msg_dtb_check:
    .asciz  "CHECK DTB\r\n"
msg_load_ok:
    .asciz  "LOAD OK; EL1 HANDOFF\r\n"
msg_pong:
    .asciz  "PONG\r\n"
msg_ready:
    .asciz  "READY; p PONG, r RETRY\r\n"

.section .bss, "aw", %nobits
.balign 4
last_error:
    .word   0
