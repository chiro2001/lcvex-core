// microbench：P6 系统指令定向测试（DAIF、AT/PAR_EL1、LDAR/STLR）。
// 运行环境为 MMU 关闭的裸机 SRAM；每个子项只检查架构可见结果。

#include "tests.h"

static unsigned long fails;
static volatile unsigned char byte_cell;
static volatile unsigned short half_cell;
static volatile unsigned int word_cell;

static unsigned long read_daif(void)
{
    unsigned long v;
    __asm__ volatile("mrs %0, daif" : "=r"(v));
    return v;
}

int run_test_sys(void)
{
    unsigned long v, va, par, hi;

    // DAIF 复位为全置位；立即数清除/置位及 MRS/MSR 往返。
    v = read_daif();
    CHECK_EQ(v & 0x3c0UL, 0x3c0UL);
    __asm__ volatile("msr daifclr, #0xf" ::: "memory");
    CHECK_EQ(read_daif() & 0x3c0UL, 0UL);
    __asm__ volatile("msr daifset, #0x5" ::: "memory");
    CHECK_EQ(read_daif() & 0x3c0UL, 0x140UL);
    v = 0x80UL;
    __asm__ volatile("msr daif, %0" :: "r"(v) : "memory");
    CHECK_EQ(read_daif() & 0x3c0UL, 0x80UL);

    // STLR/LDAR：顺序核无需额外排序状态，但宽度和内存副作用必须正确。
    byte_cell = 0;
    v = 0xa5UL;
    __asm__ volatile("stlrb %w1, [%0]" :: "r"(&byte_cell), "r"(v)
                     : "memory");
    v = 0;
    __asm__ volatile("ldarb %w0, [%1]" : "=r"(v) : "r"(&byte_cell)
                     : "memory");
    CHECK_EQ(v & 0xffUL, 0xa5UL);

    half_cell = 0;
    v = 0xbeefUL;
    __asm__ volatile("stlrh %w1, [%0]" :: "r"(&half_cell), "r"(v)
                     : "memory");
    v = 0;
    __asm__ volatile("ldarh %w0, [%1]" : "=r"(v) : "r"(&half_cell)
                     : "memory");
    CHECK_EQ(v & 0xffffUL, 0xbeefUL);

    word_cell = 0;
    v = 0x12345678UL;
    __asm__ volatile("stlr %w1, [%0]" :: "r"(&word_cell), "r"(v)
                     : "memory");
    v = 0;
    __asm__ volatile("ldar %w0, [%1]" : "=r"(v) : "r"(&word_cell)
                     : "memory");
    CHECK_EQ(v & 0xffffffffUL, 0x12345678UL);

    // MMU 关闭时 AT S1E1R 为直接映射，PAR 返回 LPAE 标志+物理页号。
    va = (unsigned long)&word_cell;
    __asm__ volatile("at s1e1r, %0" :: "r"(va) : "memory");
    __asm__ volatile("mrs %0, par_el1" : "=r"(par));
    CHECK_EQ(par, (va & ~0xfffUL) | 0xb00UL);

    // RBIT：验证 X/W 形式按位反转及 W 结果零扩展。
    __asm__ volatile("rbit %0, %1" : "=r"(hi) : "r"(1UL));
    CHECK_EQ(hi, 0x8000000000000000UL);
    __asm__ volatile("rbit %w0, %w1" : "=r"(hi) : "r"(1UL));
    CHECK_EQ(hi, 0x0000000080000000UL);

    // UMULH：验证 64x64 无符号乘积的高半部分，避免只覆盖 MUL 低 64 位。
    __asm__ volatile("umulh %0, %1, %2" : "=r"(hi)
                     : "r"(~0UL), "r"(2UL));
    CHECK_EQ(hi, 1UL);
    __asm__ volatile("umulh %0, %1, %2" : "=r"(hi)
                     : "r"(0x100000000UL), "r"(0x100000000UL));
    CHECK_EQ(hi, 1UL);

    return (int)fails;
}
