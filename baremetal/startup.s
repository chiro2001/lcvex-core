// LCVEX 裸机启动代码：设栈指针后进入 main；main 返回后自旋。
// 交叉工具链：aarch64-linux-gnu-gcc（-ffreestanding -nostdlib）。

.section .text.startup
.globl _start
.type _start, %function
_start:
    movz x0, #0x4408, lsl #16     // 栈顶 0x44080000（SRAM 内）
    mov sp, x0
    bl main
1:  b 1b
