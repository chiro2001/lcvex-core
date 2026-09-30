/* Catapult A10 PID 1: integer-only AArch64 syscalls, no libc or FP/SIMD. */
.arch armv8-a
.text
.align 2

#ifndef LCVEX_PARSER_ONLY
.global _start
.type _start, %function
_start:
        mov     x19, #0
        bl      setup_console

        adr     x0, banner
        mov     x1, #(banner_end - banner)
        bl      write_all

.Lprompt:
        adr     x0, prompt
        mov     x1, #(prompt_end - prompt)
        bl      write_all

.Lread_byte:
        mov     x0, #0                  /* stdin is /dev/console */
        adr     x1, input_byte
        mov     x2, #1
        mov     x8, #63                 /* read */
        svc     #0
        cmp     x0, #1
        b.ne    .Lread_byte

        adr     x0, input_byte
        ldrb    w0, [x0]
        adr     x1, skip_lf_state
        bl      lcvex_line_event
        cmp     w0, #2                  /* swallow LF after a CR */
        b.eq    .Lread_byte
        cmp     w0, #1
        b.eq    .Lline_ready

        adr     x9, overflow_state
        ldr     w9, [x9]
        cbnz    w9, .Lread_byte          /* discard until the line terminator */
        adr     x9, input_byte
        ldrb    w0, [x9]
        cmp     x19, #127
        b.hs    .Lmark_overflow
        adr     x9, input_line
        strb    w0, [x9, x19]
        add     x19, x19, #1
        b       .Lread_byte

.Lmark_overflow:
        mov     w9, #1
        adr     x10, overflow_state
        str     w9, [x10]
        b       .Lread_byte

.Lline_ready:
        adr     x9, input_line
        strb    wzr, [x9, x19]
        adr     x10, overflow_state
        ldr     w9, [x10]
        cbnz    w9, .Lline_too_long

        adr     x0, input_line
        mov     x1, x19
        adr     x2, command_payload
        adr     x3, command_payload_len
        bl      lcvex_parse_command
        adr     x9, command_kind
        str     w0, [x9]

        cmp     w0, #1                  /* help */
        b.eq    .Lcommand_help
        cmp     w0, #2                  /* echo */
        b.eq    .Lcommand_echo
        cmp     w0, #3                  /* sleep */
        b.eq    .Lcommand_sleep
        cmp     w0, #4                  /* about */
        b.eq    .Lcommand_about
        cmp     w0, #5                  /* unknown */
        b.eq    .Lcommand_unknown
        b       .Lline_done             /* empty input */

.Lcommand_help:
        adr     x0, help_message
        mov     x1, #(help_message_end - help_message)
        bl      write_all
        b       .Lline_done

.Lcommand_echo:
        adr     x9, command_payload_len
        ldr     x1, [x9]
        adr     x0, command_payload
        ldr     x0, [x0]
        bl      write_all
        adr     x0, newline
        mov     x1, #(newline_end - newline)
        bl      write_all
        b       .Lline_done

.Lcommand_sleep:
        adr     x0, one_second
        mov     x1, #0
        mov     x8, #101                /* nanosleep */
        svc     #0
        cbnz    x0, .Lsleep_interrupted
        adr     x0, sleep_done
        mov     x1, #(sleep_done_end - sleep_done)
        bl      write_all
        b       .Lline_done

.Lsleep_interrupted:
        adr     x0, sleep_interrupted
        mov     x1, #(sleep_interrupted_end - sleep_interrupted)
        bl      write_all
        b       .Lline_done

.Lcommand_about:
        adr     x0, about_message
        mov     x1, #(about_message_end - about_message)
        bl      write_all
        b       .Lline_done

.Lcommand_unknown:
        adr     x0, unknown_prefix
        mov     x1, #(unknown_prefix_end - unknown_prefix)
        bl      write_all
        adr     x0, input_line
        mov     x1, x19
        bl      write_all
        adr     x0, newline
        mov     x1, #(newline_end - newline)
        bl      write_all
        b       .Lline_done

.Lline_too_long:
        adr     x0, line_too_long
        mov     x1, #(line_too_long_end - line_too_long)
        bl      write_all

.Lline_done:
        mov     x19, #0
        adr     x9, overflow_state
        str     wzr, [x9]
        b       .Lprompt

/* Explicitly connect fd 0/1/2 to /dev/console when init inherited none. */
.type setup_console, %function
setup_console:
        stp     x19, x30, [sp, #-16]!
        mov     x0, #-100                /* AT_FDCWD */
        adr     x1, console_path
        mov     x2, #2                   /* O_RDWR */
        mov     x3, #0
        mov     x8, #56                  /* openat */
        svc     #0
        cmp     x0, #0
        b.lt    .Lconsole_open_done
        mov     x19, x0

        cmp     x19, #0
        b.eq    .Lconsole_dup_stdout
        mov     x0, x19
        mov     x1, #0
        mov     x2, #0
        mov     x8, #24                  /* dup3 */
        svc     #0

.Lconsole_dup_stdout:
        cmp     x19, #1
        b.eq    .Lconsole_dup_stderr
        mov     x0, x19
        mov     x1, #1
        mov     x2, #0
        mov     x8, #24
        svc     #0

.Lconsole_dup_stderr:
        cmp     x19, #2
        b.eq    .Lconsole_open_done
        mov     x0, x19
        mov     x1, #2
        mov     x2, #0
        mov     x8, #24
        svc     #0

.Lconsole_open_done:
        ldp     x19, x30, [sp], #16
        ret

/* write(1, buf, len), retrying partial writes and EINTR. */
.type write_all, %function
write_all:
        stp     x19, x20, [sp, #-16]!
        mov     x19, x0
        mov     x20, x1
.Lwrite_again:
        cbz     x20, .Lwrite_done
        mov     x0, #1
        mov     x1, x19
        mov     x2, x20
        mov     x8, #64                  /* write */
        svc     #0
        cmp     x0, #0
        b.gt    .Lwrite_advance
        cmn     x0, #4                   /* -EINTR */
        b.eq    .Lwrite_again
        b       .Lwrite_done
.Lwrite_advance:
        add     x19, x19, x0
        sub     x20, x20, x0
        b       .Lwrite_again
.Lwrite_done:
        ldp     x19, x20, [sp], #16
        ret
#endif

/*
 * Host-testable line-end state machine.
 * x0=byte, x1=&skip_lf (u32); return 0=ordinary, 1=process line end,
 * 2=swallowed LF immediately following CR.
 */
.global lcvex_line_event
.type lcvex_line_event, %function
lcvex_line_event:
        ldr     w9, [x1]
        str     wzr, [x1]
        cbz     w9, .Lline_event_check
        cmp     w0, #10
        b.eq    .Lline_event_swallow
.Lline_event_check:
        cmp     w0, #13
        b.eq    .Lline_event_cr
        cmp     w0, #10
        b.eq    .Lline_event_lf
        mov     w0, #0
        ret
.Lline_event_cr:
        mov     w9, #1
        str     w9, [x1]
        mov     w0, #1
        ret
.Lline_event_lf:
        mov     w0, #1
        ret
.Lline_event_swallow:
        mov     w0, #2
        ret

/* x0=bytes, x1=length, x2=&payload, x3=&payload_len; return command id. */
.global lcvex_parse_command
.type lcvex_parse_command, %function
lcvex_parse_command:
        stp     x19, x20, [sp, #-16]!
        stp     x21, x22, [sp, #-16]!
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x22, x3

.Lparse_trim_left:
        cbz     x20, .Lparse_empty
        ldrb    w11, [x19]
        cmp     w11, #32
        b.eq    .Lparse_skip_left
        cmp     w11, #9
        b.ne    .Lparse_trim_right
.Lparse_skip_left:
        add     x19, x19, #1
        sub     x20, x20, #1
        b       .Lparse_trim_left

.Lparse_trim_right:
        cbz     x20, .Lparse_empty
        add     x11, x19, x20
        sub     x11, x11, #1
        ldrb    w12, [x11]
        cmp     w12, #32
        b.eq    .Lparse_skip_right
        cmp     w12, #9
        b.eq    .Lparse_skip_right
        cmp     w12, #13
        b.eq    .Lparse_skip_right
        cmp     w12, #10
        b.ne    .Lparse_classify
.Lparse_skip_right:
        sub     x20, x20, #1
        b       .Lparse_trim_right

.Lparse_classify:
        str     x19, [x21]
        str     x20, [x22]

        cmp     x20, #4
        b.ne    .Lparse_try_echo
        ldrb    w11, [x19, #0]
        cmp     w11, #104                /* help */
        b.ne    .Lparse_try_echo
        ldrb    w11, [x19, #1]
        cmp     w11, #101
        b.ne    .Lparse_try_echo
        ldrb    w11, [x19, #2]
        cmp     w11, #108
        b.ne    .Lparse_try_echo
        ldrb    w11, [x19, #3]
        cmp     w11, #112
        b.ne    .Lparse_try_echo
        mov     w0, #1
        b       .Lparse_return

.Lparse_try_echo:
        cmp     x20, #4
        b.lo    .Lparse_try_sleep
        ldrb    w11, [x19, #0]
        cmp     w11, #101                /* echo */
        b.ne    .Lparse_try_sleep
        ldrb    w11, [x19, #1]
        cmp     w11, #99
        b.ne    .Lparse_try_sleep
        ldrb    w11, [x19, #2]
        cmp     w11, #104
        b.ne    .Lparse_try_sleep
        ldrb    w11, [x19, #3]
        cmp     w11, #111
        b.ne    .Lparse_try_sleep
        add     x13, x19, #4
        sub     x14, x20, #4
.Lparse_echo_delimiter:
        cbz     x14, .Lparse_echo
        ldrb    w15, [x13]
        cmp     w15, #32
        b.eq    .Lparse_echo_advance
        cmp     w15, #9
        b.ne    .Lparse_unknown
.Lparse_echo_advance:
        add     x13, x13, #1
        sub     x14, x14, #1
.Lparse_echo_skip_space:
        cbz     x14, .Lparse_echo
        ldrb    w15, [x13]
        cmp     w15, #32
        b.eq    .Lparse_echo_advance
        cmp     w15, #9
        b.ne    .Lparse_echo
        add     x13, x13, #1
        sub     x14, x14, #1
        b       .Lparse_echo_skip_space
.Lparse_echo:
        str     x13, [x21]
        str     x14, [x22]
        mov     w0, #2
        b       .Lparse_return

.Lparse_try_sleep:
        cmp     x20, #5
        b.ne    .Lparse_try_about
        ldrb    w11, [x19, #0]
        cmp     w11, #115                /* sleep */
        b.ne    .Lparse_try_about
        ldrb    w11, [x19, #1]
        cmp     w11, #108
        b.ne    .Lparse_try_about
        ldrb    w11, [x19, #2]
        cmp     w11, #101
        b.ne    .Lparse_try_about
        ldrb    w11, [x19, #3]
        cmp     w11, #101
        b.ne    .Lparse_try_about
        ldrb    w11, [x19, #4]
        cmp     w11, #112
        b.ne    .Lparse_try_about
        mov     w0, #3
        b       .Lparse_return

.Lparse_try_about:
        cmp     x20, #5
        b.ne    .Lparse_unknown
        ldrb    w11, [x19, #0]
        cmp     w11, #97                 /* about */
        b.ne    .Lparse_unknown
        ldrb    w11, [x19, #1]
        cmp     w11, #98
        b.ne    .Lparse_unknown
        ldrb    w11, [x19, #2]
        cmp     w11, #111
        b.ne    .Lparse_unknown
        ldrb    w11, [x19, #3]
        cmp     w11, #117
        b.ne    .Lparse_unknown
        ldrb    w11, [x19, #4]
        cmp     w11, #116
        b.ne    .Lparse_unknown
        mov     w0, #4
        b       .Lparse_return

.Lparse_unknown:
        mov     w0, #5
        b       .Lparse_return
.Lparse_empty:
        str     x19, [x21]
        str     xzr, [x22]
        mov     w0, #0
.Lparse_return:
        ldp     x21, x22, [sp], #16
        ldp     x19, x20, [sp], #16
        ret

#ifndef LCVEX_PARSER_ONLY
.section .rodata
console_path:
        .asciz  "/dev/console"
banner:
        .ascii  "LCVEX Catapult A10 /init ready\r\n"
banner_end:
prompt:
        .ascii  "lcvex> "
prompt_end:
newline:
        .ascii  "\r\n"
newline_end:
help_message:
        .ascii  "commands: help, echo [text], sleep, about\r\n"
help_message_end:
sleep_done:
        .ascii  "sleep: 1 second elapsed\r\n"
sleep_done_end:
sleep_interrupted:
        .ascii  "sleep: interrupted\r\n"
sleep_interrupted_end:
about_message:
        .ascii  "LCVEX Catapult A10 AArch64\r\n"
about_message_end:
unknown_prefix:
        .ascii  "unknown command: "
unknown_prefix_end:
line_too_long:
        .ascii  "error: input line too long\r\n"
line_too_long_end:

.section .data
.align 3
one_second:
        .quad   1                       /* tv_sec */
        .quad   0                       /* tv_nsec */

.section .bss
.align 3
input_line:
        .skip   128
input_byte:
        .skip   1
.align 2
skip_lf_state:
        .word   0
overflow_state:
        .word   0
.align 3
command_payload:
        .quad   0
command_payload_len:
        .quad   0
command_kind:
        .word   0
#endif

.section .note.GNU-stack,"",%progbits
