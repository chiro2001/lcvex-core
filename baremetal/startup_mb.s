// LCVEX microbench 启动代码：设栈后进入 main；main 返回后把返回码
// 写入 MAGIC=0x4400FE00（运行器轮询提交包识别），随后自旋。
// 与 startup.s 分开，避免改变 bm_c.bin 的锁步窗口。

.section .text.startup
.globl _start
.type _start, %function
_start:
    movz x0, #0x4408, lsl #16     // 栈顶 0x44080000（SRAM 内）
    mov sp, x0
    bl main
    movz x1, #0x4400, lsl #16
    movk x1, #0xfe00              // x1 = 0x4400FE00（MAGIC）
    str x0, [x1]                  // 返回码写 MAGIC
1:  b 1b
