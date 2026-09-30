// lcvex_c2_perf_mc.S
// C2 dual-core performance workload kernel.
//
// Loaded as a flat little-endian AArch64 image at BASE=0x40000000.
// Core0 starts at BASE+0x000, core1 starts at BASE+0x100.  The image is
// deliberately self-contained: no MMU, no C library, no OS.  It performs:
//   1. Mailbox ping-pong with DMB barriers.
//   2. Parallel reduction over a shared 64-word array.
//   3. Same-cache-line store contention, then different-line stores.
// Marker stores let the SystemVerilog testbench record completion cycles.

    .equ PP_ITERS,   16
    .equ RED_WORDS,  32
    .equ SAME_ITERS, 32
    .equ DIFF_ITERS, 32

    .section .text
    .global _start

_start:
    b core0_main
    .org 0x100
core1_entry:
    b core1_main
    .org 0x200

core0_main:
    // ---- Phase 1: mailbox ping-pong (core0 sender) ----
    mov  x9, #PP_ITERS
    adr  x10, ping_mb
    adr  x11, ping_flag
    adr  x12, ping_done0
    mov  w13, #0
pp0_send:
    add  w13, w13, #1
    str  w13, [x10]          // mailbox
    dmb  sy
    mov  w14, #1
    str  w14, [x11]          // flag = 1
    dmb  sy
pp0_wait:
    ldr  w15, [x11]
    cmp  w15, #2
    b.ne pp0_wait
    dmb  sy
    subs x9, x9, #1
    b.ne pp0_send
    mov  w16, #0x5678
    movk w16, #0x1234, lsl #16
    str  w16, [x12]          // ping_done0 = 0x12345678
    dmb  sy

    // ---- Phase 2: parallel reduction, first half ----
    adr  x20, red_part0
    adr  x21, red_array
    mov  x22, #RED_WORDS
    mov  w23, #0
red0_loop:
    ldr  w24, [x21], #4
    add  w23, w23, w24
    subs x22, x22, #1
    b.ne red0_loop
    str  w23, [x20]          // red_part0
    dmb  sy
    adr  x25, red_part1
    adr  x26, red_flag
red0_wait:
    ldr  w27, [x26]
    cmp  w27, #1
    b.ne red0_wait
    dmb  sy
    ldr  w28, [x25]          // red_part1
    add  w29, w23, w28
    adr  x30, red_result
    str  w29, [x30]          // red_result = 64
    dmb  sy
    mov  w16, #0xEF01
    movk w16, #0xABCD, lsl #16
    adr  x28, red_done
    str  w16, [x28]          // red_done = 0xABCDEF01
    dmb  sy

    // ---- Phase 3a: same-cache-line contention ----
    adr  x10, ctr_same
    mov  x11, #SAME_ITERS
    mov  w12, #0
same0_loop:
    add  w12, w12, #1
    str  w12, [x10]
    subs x11, x11, #1
    b.ne same0_loop
    adr  x13, same0_done
    mov  w14, #0x1111
    str  w14, [x13]          // same0_done
    dmb  sy

    // Wait for core1 to finish the same-line phase.
    adr  x13, same1_done
same0_wait_same:
    ldr  w15, [x13]
    cmp  w15, #0
    b.eq same0_wait_same
    dmb  sy

    // ---- Phase 3b: different-line stores ----
    adr  x10, ctr_line0
    mov  x11, #DIFF_ITERS
    mov  w12, #0
diff0_loop:
    add  w12, w12, #1
    str  w12, [x10]
    subs x11, x11, #1
    b.ne diff0_loop
    adr  x13, diff0_done
    mov  w14, #0x2222
    str  w14, [x13]          // diff0_done
    dmb  sy
    b .

core1_main:
    // ---- Phase 1: mailbox ping-pong (core1 receiver) ----
    mov  x9, #PP_ITERS
    adr  x10, ping_mb
    adr  x11, ping_flag
    adr  x12, ping_done1
pp1_wait:
    ldr  w14, [x11]
    cmp  w14, #1
    b.ne pp1_wait
    dmb  sy
    ldr  w15, [x10]          // mailbox
    dmb  sy
    mov  w16, #2
    str  w16, [x11]          // ack = 2
    dmb  sy
    subs x9, x9, #1
    b.ne pp1_wait
    mov  w16, #0x4321
    movk w16, #0x8765, lsl #16
    str  w16, [x12]          // ping_done1 = 0x87654321
    dmb  sy

    // ---- Phase 2: parallel reduction, second half ----
    adr  x20, red_part1
    adr  x21, red_array
    add  x21, x21, #(RED_WORDS * 4)
    mov  x22, #RED_WORDS
    mov  w23, #0
red1_loop:
    ldr  w24, [x21], #4
    add  w23, w23, w24
    subs x22, x22, #1
    b.ne red1_loop
    str  w23, [x20]          // red_part1
    dmb  sy
    adr  x26, red_flag
    mov  w27, #1
    str  w27, [x26]          // red_flag = 1
    dmb  sy

    // Wait for core0 to publish red_done before starting contention.
    adr  x28, red_done
red1_wait_done:
    ldr  w29, [x28]
    cmp  w29, #0
    b.eq red1_wait_done
    dmb  sy

    // ---- Phase 3a: same-cache-line contention ----
    adr  x10, ctr_same
    mov  x11, #SAME_ITERS
    mov  w12, #1000
same1_loop:
    add  w12, w12, #1
    str  w12, [x10]
    subs x11, x11, #1
    b.ne same1_loop
    adr  x13, same1_done
    mov  w14, #0x3333
    str  w14, [x13]          // same1_done
    dmb  sy

    // Wait for core0 to finish the same-line phase.
    adr  x13, same0_done
same1_wait_same:
    ldr  w15, [x13]
    cmp  w15, #0
    b.eq same1_wait_same
    dmb  sy

    // ---- Phase 3b: different-line stores ----
    adr  x10, ctr_line1
    mov  x11, #DIFF_ITERS
    mov  w12, #2000
diff1_loop:
    add  w12, w12, #1
    str  w12, [x10]
    subs x11, x11, #1
    b.ne diff1_loop
    adr  x13, diff1_done
    mov  w14, #0x4444
    str  w14, [x13]          // diff1_done
    dmb  sy
    b .

// ---- Shared data (initialized through the same program-load port) ----
    .org 0x2000
ping_mb:     .word 0
ping_flag:   .word 0
ping_done0:  .word 0
ping_done1:  .word 0

    .org 0x2100
red_array:   .fill RED_WORDS * 2, 4, 1   // 64 words of 1
red_part0:   .word 0
red_part1:   .word 0
red_flag:    .word 0
red_result:  .word 0
red_done:    .word 0

    .org 0x2300
ctr_same:    .word 0
same0_done:  .word 0
same1_done:  .word 0

    .org 0x2400
ctr_line0:   .word 0
diff0_done:  .word 0

    .org 0x2440
ctr_line1:   .word 0
diff1_done:  .word 0
