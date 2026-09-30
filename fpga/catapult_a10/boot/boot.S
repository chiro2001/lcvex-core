// B25 BRAM-resident AArch64 monitor.
//
// The image is linked entirely below 0x00010000.  The reset path never
// branches into DDR: it reports calibration, performs a bounded real DDR
// write/read test when calibration is available, and then remains in the
// BRAM monitor so UART diagnostics survive every failure mode.

.equ UART_DATA,       0x09000000
.equ UART_CONTROL,    0x09000004
.equ PLAT_STATUS,     0x09003000
.equ JTAG_READ_COUNT, 0x09003008
.equ JTAG_RX_EVENT,   0x09003010
.equ JTAG_BRIDGE_RESPONSE, 0x09003018
.equ JTAG_POC_RESPONSE,    0x09003020
.equ JTAG_DMEM_RESPONSE,   0x09003028
.equ JTAG_PATH_EVENTS,     0x09003030
.equ JTAG_TX_EVENT,        0x09003038
.equ DDR_TEST_A,      0x40001000
.equ DDR_MAGIC_A,     0xB007C0DE
.equ CAL_WAIT_LIMIT,  0x100
.equ CAL_WAIT,        0
.equ CAL_OK,          1
.equ CAL_FAIL,        2
.equ DDR_FAIL,        0
.equ DDR_OK,          1
.equ RXDBG_POLL_LIMIT, 0x40000
.equ UART_TX_WAIT_LIMIT, 0x00100000

.section .text.boot, "ax"
.global _start
.type _start, %function

_start:
    // The stack occupies [0xF000,0x10000); no DDR stack is ever used.
    ldr     x0, =__stack_top
    mov     sp, x0

    // Reset the software-visible status before the first report.
    ldr     x1, =cal_state
    mov     w0, #CAL_WAIT
    str     w0, [x1]
    ldr     x1, =ddr_state
    mov     w0, #DDR_FAIL
    str     w0, [x1]

    // Reset firmware-only observation state before any output or polling.
    ldr     x1, =obs_page
    mov     w0, #0
    str     w0, [x1]
    ldr     x1, =obs_getc_valid_count
    str     w0, [x1]
    ldr     x1, =obs_getc_last_raw
    str     w0, [x1]
    ldr     x1, =obs_dispatch_count
    str     w0, [x1]
    ldr     x1, =obs_dispatch_class_byte
    str     w0, [x1]
    ldr     x1, =obs_putc_success_count
    str     w0, [x1]
    ldr     x1, =obs_putc_drop_count
    str     w0, [x1]

    ldr     x0, =msg_boot
    bl      uart_puts

    // A bounded wait makes CAL-WAIT diagnosable even if EMIF never answers.
    bl      refresh_cal_state_wait
    bl      emit_cal_state
    ldr     x0, =msg_crlf
    bl      uart_puts
    ldr     x1, =cal_state
    ldr     w1, [x1]
    cmp     w1, #CAL_OK
    b.ne    startup_ddr_fail

    bl      ddr_test
    ldr     x1, =ddr_state
    str     w0, [x1]
    bl      emit_ddr_state
    ldr     x0, =msg_crlf
    bl      uart_puts
    b       startup_ready

startup_ddr_fail:
    // Calibration failure and timeout deliberately share the safe path.
    mov     w0, #DDR_FAIL
    ldr     x1, =ddr_state
    str     w0, [x1]
    bl      emit_ddr_state
    ldr     x0, =msg_crlf
    bl      uart_puts

startup_ready:
    ldr     x0, =msg_ready
    bl      uart_puts
    // Startup is always the legacy RXDBG page and does not advance the
    // autonomous rotation; the first 0x40000 empty polls emit RXDBG too.
    bl      emit_rxdbg_page
    ldr     w19, =RXDBG_POLL_LIMIT

// -------------------------------------------------------------------------
// Resident command monitor.
// -------------------------------------------------------------------------
monitor:
    ldr     x0, =UART_DATA
    bl      uart_getc
    cbnz    w1, monitor_byte
    subs    w19, w19, #1
    b.ne    monitor
    bl      emit_rx_observation
    ldr     w19, =RXDBG_POLL_LIMIT
    b       monitor

monitor_byte:
    ldr     w19, =RXDBG_POLL_LIMIT

    cmp     w0, #0x70                 // 'p'
    b.eq    command_ping
    cmp     w0, #0x3f                 // '?'
    b.eq    command_status
    cmp     w0, #0x6d                 // 'm'
    b.eq    command_memory
    cmp     w0, #0x64                 // 'd'
    b.eq    command_debug
    cmp     w0, #0x74                 // 't'
    b.eq    command_microbench
    cmp     w0, #0x76                 // 'v'
    b.eq    command_coremark_short
    cmp     w0, #0x63                 // 'c'
    b.eq    command_coremark_full

    // Printable bytes are echoed exactly once; control bytes are ignored.
    cmp     w0, #0x20
    b.lo    monitor_ignored
    cmp     w0, #0x7e
    b.hi    monitor_ignored
    mov     w2, w0
    mov     w1, #5                    // class=printable echo
    bl      record_dispatch
    ldr     x0, =UART_DATA
    bl      uart_putc
    b       monitor

command_ping:
    mov     w2, w0
    mov     w1, #1                    // class=ping
    bl      record_dispatch
    ldr     x0, =msg_pong
    bl      uart_puts
    b       monitor

command_status:
    mov     w2, w0
    mov     w1, #2                    // class=status
    bl      record_dispatch
    // Refreshing calibration here also permits a later `m` after an initial
    // CAL-WAIT timeout to observe a calibration that eventually succeeded.
    bl      refresh_cal_state_now
    bl      status_report
    b       monitor

command_debug:
    mov     w2, w0
    mov     w1, #4                    // class=debug
    bl      record_dispatch
    // Preserve the historical `d` response as one immediate RXDBG page;
    // autonomous observations use the rotating RXDBG/RXPATH/RXCPU pages.
    bl      emit_rxdbg_page
    b       monitor

command_memory:
    mov     w2, w0
    mov     w1, #3                    // class=memory
    bl      record_dispatch
    bl      refresh_cal_state_now
    ldr     x1, =cal_state
    ldr     w1, [x1]
    cmp     w1, #CAL_OK
    b.ne    command_memory_fail
    bl      ddr_test
    ldr     x1, =ddr_state
    str     w0, [x1]
    b       command_memory_report

command_memory_fail:
    mov     w0, #DDR_FAIL
    ldr     x1, =ddr_state
    str     w0, [x1]

command_memory_report:
    bl      emit_ddr_state
    ldr     x0, =msg_crlf
    bl      uart_puts
    b       monitor

command_microbench:
    mov     w2, w0
    mov     w1, #6                    // class=correctness microbench
    bl      record_dispatch
    bl      lcvex_run_correctness
    b       monitor

command_coremark_short:
    mov     w2, w0
    mov     w1, #7                    // class=CoreMark short CRC self-check
    bl      record_dispatch
    bl      lcvex_run_coremark_short
    b       monitor

command_coremark_full:
    mov     w2, w0
    mov     w1, #8                    // class=CoreMark standards-valid run
    bl      record_dispatch
    bl      lcvex_run_coremark_full
    b       monitor

monitor_ignored:
    // Valid control bytes are observable too, but have no command class.
    mov     w2, w0
    mov     w1, #0
    bl      record_dispatch
    b       monitor

record_dispatch:
    // w1=command class, w2=command byte.  Keep the functional command
    // comparisons and payload registers untouched.
    ldr     x3, =obs_dispatch_count
    ldr     w4, [x3]
    add     w4, w4, #1
    str     w4, [x3]
    lsl     w1, w1, #8
    orr     w1, w1, w2
    ldr     x3, =obs_dispatch_class_byte
    str     w1, [x3]
    ret

// -------------------------------------------------------------------------
// UART helpers.
// -------------------------------------------------------------------------

// Freestanding C ABI wrappers.  The internal monitor putc convention keeps
// its byte in w2, while AAPCS64 passes the first C argument in w0.  Tail
// branches preserve the caller's link register.
.global lcvex_uart_putc
.type lcvex_uart_putc, %function
lcvex_uart_putc:
    mov     w2, w0
    ldr     x0, =UART_DATA
    b       uart_putc

.global lcvex_uart_puts
.type lcvex_uart_puts, %function
lcvex_uart_puts:
    b       uart_puts

// Put the byte in w2.  CONTROL.WSPACE is checked before every DATA write.
// A finite wait prevents an unplugged/not-yet-connected host from trapping
// reset diagnostics forever; after expiry the byte is dropped without a
// DATA access, so a full vendor FIFO can never hold the core indefinitely.
.type uart_putc, %function
uart_putc:
    // JTAG-UART's TX FIFO is 64 bytes.  Allow the asynchronous JTAG host
    // time to drain it before dropping a byte; 64 loop iterations (a few
    // microseconds) was shorter than the host/USB service interval.
    ldr     w3, =UART_TX_WAIT_LIMIT
1:
    ldr     w4, [x0, #4]
    lsr     w4, w4, #16
    cbnz    w4, 2f
    subs    w3, w3, #1
    b.ne    1b
    ldr     x5, =obs_putc_drop_count
    ldr     w6, [x5]
    add     w6, w6, #1
    str     w6, [x5]
    b       3f
2:
    str     w2, [x0]
    ldr     x5, =obs_putc_success_count
    ldr     w6, [x5]
    add     w6, w6, #1
    str     w6, [x5]
3:
    ret

// x0 points at a NUL-terminated string.
.type uart_puts, %function
uart_puts:
    sub     sp, sp, #16
    str     x30, [sp]
    mov     x1, x0
    ldr     x0, =UART_DATA
1:
    ldrb    w2, [x1], #1
    cbz     w2, 2f
    bl      uart_putc
    b       1b
2:
    ldr     x30, [sp]
    add     sp, sp, #16
    ret

// Return w1=1 and w0=byte when DATA.RVALID (bit15) is set; otherwise w1=0.
.type uart_getc, %function
uart_getc:
    ldr     w0, [x0]
    tbnz    w0, #15, 1f
    mov     w1, #0
    ret
1:
    and     w6, w0, #0xffff
    ldr     x5, =obs_getc_last_raw
    str     w6, [x5]
    ldr     x5, =obs_getc_valid_count
    ldr     w7, [x5]
    add     w7, w7, #1
    str     w7, [x5]
    and     w0, w0, #0xff
    mov     w1, #1
    ret

// Emit one autonomous page and advance page 0 -> 1 -> 2 -> 0:
//   RXDBG  <read-count> <RX-event>\r\n
//   RXPATH <bridge-response> <PoC-response> <dmem-response> <path-events>\r\n
//   RXCPU  <getc-event> <dispatch-event> <putc-event> <TX-event>\r\n
.type emit_rx_observation, %function
emit_rx_observation:
    sub     sp, sp, #64
    stp     x19, x20, [sp]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    str     x30, [sp, #48]
    ldr     x1, =obs_page
    ldr     w19, [x1]
    add     w20, w19, #1
    cmp     w20, #3
    b.lo    1f
    mov     w20, #0
1:
    str     w20, [x1]
    cbz     w19, 2f
    cmp     w19, #1
    b.eq    3f
    bl      emit_rxcpu_page
    b       4f
2:
    bl      emit_rxdbg_page
    b       4f
3:
    bl      emit_rxpath_page
4:
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp]
    ldr     x30, [sp, #48]
    add     sp, sp, #64
    ret

// d emits one immediate RXDBG without consuming the autonomous page slot.
.type emit_rxdbg_page, %function
emit_rxdbg_page:
    sub     sp, sp, #32
    stp     x19, x20, [sp]
    str     x30, [sp, #16]
    ldr     x1, =JTAG_READ_COUNT
    ldr     w19, [x1]
    ldr     x1, =JTAG_RX_EVENT
    ldr     w20, [x1]
    ldr     x0, =msg_rxdbg
    bl      uart_puts
    mov     w0, w19
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w20
    bl      uart_puthex32
    ldr     x0, =msg_crlf
    bl      uart_puts
    ldp     x19, x20, [sp]
    ldr     x30, [sp, #16]
    add     sp, sp, #32
    ret

// Emit the bridge/PoC/core response path page.  Hardware offsets are read-only
// observations; no value is used to drive the monitor or memory handshake.
.type emit_rxpath_page, %function
emit_rxpath_page:
    sub     sp, sp, #48
    stp     x19, x20, [sp]
    stp     x21, x22, [sp, #16]
    str     x30, [sp, #32]
    ldr     x1, =JTAG_BRIDGE_RESPONSE
    ldr     w19, [x1]
    ldr     x1, =JTAG_POC_RESPONSE
    ldr     w20, [x1]
    ldr     x1, =JTAG_DMEM_RESPONSE
    ldr     w21, [x1]
    ldr     x1, =JTAG_PATH_EVENTS
    ldr     w22, [x1]
    ldr     x0, =msg_rxpath
    bl      uart_puts
    mov     w0, w19
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w20
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w21
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w22
    bl      uart_puthex32
    ldr     x0, =msg_crlf
    bl      uart_puts
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp]
    ldr     x30, [sp, #32]
    add     sp, sp, #48
    ret

// Emit packed firmware and hardware TX observations.  Each field is exactly
// one 32-bit word, keeping the complete diagnostic line below 64 bytes.
.type emit_rxcpu_page, %function
emit_rxcpu_page:
    sub     sp, sp, #64
    stp     x19, x20, [sp]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    str     x30, [sp, #48]
    ldr     x1, =obs_getc_valid_count
    ldr     w19, [x1]
    lsl     w19, w19, #16
    ldr     x1, =obs_getc_last_raw
    ldr     w20, [x1]
    and     w20, w20, #0xffff
    orr     w19, w19, w20
    ldr     x1, =obs_dispatch_count
    ldr     w20, [x1]
    lsl     w20, w20, #16
    ldr     x1, =obs_dispatch_class_byte
    ldr     w21, [x1]
    and     w21, w21, #0xffff
    orr     w20, w20, w21
    ldr     x1, =obs_putc_success_count
    ldr     w21, [x1]
    lsl     w21, w21, #16
    ldr     x1, =obs_putc_drop_count
    ldr     w22, [x1]
    and     w22, w22, #0xffff
    orr     w21, w21, w22
    ldr     x1, =JTAG_TX_EVENT
    ldr     w22, [x1]
    ldr     x0, =msg_rxcpu
    bl      uart_puts
    mov     w0, w19
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w20
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w21
    bl      uart_puthex32
    ldr     x0, =msg_space
    bl      uart_puts
    mov     w0, w22
    bl      uart_puthex32
    ldr     x0, =msg_crlf
    bl      uart_puts
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp]
    ldr     x30, [sp, #48]
    add     sp, sp, #64
    ret

// Emit w0 as exactly eight uppercase hexadecimal digits.
.type uart_puthex32, %function
uart_puthex32:
    sub     sp, sp, #32
    stp     x19, x20, [sp]
    str     x30, [sp, #16]
    mov     w19, w0
    mov     w20, #8
1:
    lsr     w2, w19, #28
    cmp     w2, #10
    b.lo    2f
    add     w2, w2, #55
    b       3f
2:
    add     w2, w2, #48
3:
    ldr     x0, =UART_DATA
    bl      uart_putc
    lsl     w19, w19, #4
    subs    w20, w20, #1
    b.ne    1b
    ldp     x19, x20, [sp]
    ldr     x30, [sp, #16]
    add     sp, sp, #32
    ret
// -------------------------------------------------------------------------
// Calibration/status reporting.
// -------------------------------------------------------------------------

// Read PLAT_STATUS once and update cal_state.  Return the same state in w0.
.type refresh_cal_state_now, %function
refresh_cal_state_now:
    ldr     x1, =PLAT_STATUS
    ldr     w2, [x1]
    tbnz    w2, #1, 1f
    tbnz    w2, #0, 2f
    mov     w0, #CAL_WAIT
    b       3f
1:
    mov     w0, #CAL_FAIL
    b       3f
2:
    mov     w0, #CAL_OK
3:
    ldr     x1, =cal_state
    str     w0, [x1]
    ret

// Bounded startup sampler.  A failure wins over success if both status bits
// are observed, matching the sticky-fail platform gate semantics.
.type refresh_cal_state_wait, %function
refresh_cal_state_wait:
    ldr     x1, =PLAT_STATUS
    mov     w3, #CAL_WAIT_LIMIT
1:
    ldr     w2, [x1]
    tbnz    w2, #1, 3f
    tbnz    w2, #0, 4f
    subs    w3, w3, #1
    b.ne    1b
    mov     w0, #CAL_WAIT
    b       5f
3:
    mov     w0, #CAL_FAIL
    b       5f
4:
    mov     w0, #CAL_OK
5:
    ldr     x1, =cal_state
    str     w0, [x1]
    ret

// Emit CAL-OK/CAL-FAIL/CAL-WAIT without a trailing newline.
.type emit_cal_state, %function
emit_cal_state:
    sub     sp, sp, #16
    str     x30, [sp]
    ldr     x1, =cal_state
    ldr     w1, [x1]
    cmp     w1, #CAL_OK
    b.eq    1f
    cmp     w1, #CAL_FAIL
    b.eq    2f
    ldr     x0, =msg_cal_wait
    bl      uart_puts
    b       3f
1:
    ldr     x0, =msg_cal_ok
    bl      uart_puts
    b       3f
2:
    ldr     x0, =msg_cal_fail
    bl      uart_puts
3:
    ldr     x30, [sp]
    add     sp, sp, #16
    ret

// Emit DDR-OK/DDR-FAIL without a trailing newline.
.type emit_ddr_state, %function
emit_ddr_state:
    sub     sp, sp, #16
    str     x30, [sp]
    ldr     x1, =ddr_state
    ldr     w1, [x1]
    cbnz    w1, 1f
    ldr     x0, =msg_ddr_fail
    bl      uart_puts
    b       2f
1:
    ldr     x0, =msg_ddr_ok
    bl      uart_puts
2:
    ldr     x30, [sp]
    add     sp, sp, #16
    ret

// ? output: CLOCK25 CAL-* DDR-*\r\n.
.type status_report, %function
status_report:
    sub     sp, sp, #16
    str     x30, [sp]
    ldr     x0, =msg_clock
    bl      uart_puts
    bl      emit_cal_state
    ldr     x0, =msg_space
    bl      uart_puts
    bl      emit_ddr_state
    ldr     x0, =msg_crlf
    bl      uart_puts
    ldr     x30, [sp]
    add     sp, sp, #16
    ret

// -------------------------------------------------------------------------
// DDR magic test.
// -------------------------------------------------------------------------

// The Catapult SoC marks direct/MMU-off DDR as uncached during bring-up, so
// this store/load pair reaches the EMIF adapter without depending on cache
// replacement behavior.  DSB orders the write before the read.  The SoC TB
// independently requires adapter read/write counters and external-model data.
.type ddr_test, %function
ddr_test:
    ldr     x0, =DDR_TEST_A
    ldr     w1, =DDR_MAGIC_A
    str     w1, [x0]
    dsb     sy
    ldr     w1, [x0]
    ldr     w2, =DDR_MAGIC_A
    cmp     w1, w2
    b.ne    1f
    mov     w0, #DDR_OK
    ret
1:
    mov     w0, #DDR_FAIL
    ret

.section .rodata, "a"
msg_boot:
    .asciz  "LCVEX25 BOOT\r\n"
msg_cal_ok:
    .asciz  "CAL-OK"
msg_cal_fail:
    .asciz  "CAL-FAIL"
msg_cal_wait:
    .asciz  "CAL-WAIT"
msg_ddr_ok:
    .asciz  "DDR-OK"
msg_ddr_fail:
    .asciz  "DDR-FAIL"
msg_ready:
    .asciz  "READY\r\n"
msg_rxdbg:
    .asciz  "RXDBG "
msg_rxpath:
    .asciz  "RXPATH "
msg_rxcpu:
    .asciz  "RXCPU "
msg_pong:
    .asciz  "PONG\r\n"
msg_clock:
    .asciz  "CLOCK25 "
msg_space:
    .asciz  " "
msg_crlf:
    .asciz  "\r\n"

.section .bss, "aw", %nobits
.align 2
cal_state:
    .word   CAL_WAIT
ddr_state:
    .word   DDR_FAIL
obs_page:
    .word   0
obs_getc_valid_count:
    .word   0
obs_getc_last_raw:
    .word   0
obs_dispatch_count:
    .word   0
obs_dispatch_class_byte:
    .word   0
obs_putc_success_count:
    .word   0
obs_putc_drop_count:
    .word   0
