/* Linux lite initramfs /init：无 libc 的静态 AArch64 ELF。 */
.section .text
.align  2
.global _start
.type   _start, %function
_start:
        /* write(1, message, length) */
        mov     x0, #1
        adr     x1, message
        mov     x2, #(message_end - message)
        mov     x8, #64
        svc     #0

1:      /* pause()，保持 PID 1 存活，等待后续中断/调试。 */
        mov     x8, #29
        svc     #0
        b       1b
.size _start, .-_start

.section .rodata
message:
        .ascii   "LCVEX linux-lite /init ready\n"
message_end:
