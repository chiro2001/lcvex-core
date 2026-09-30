// microbench：BFM 位域插入（BFI/BFXIL），字段外位保留。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long v[4] = { 0xffffffffffffffffUL,
                                       0xab, 0xabcd, 0x1234 };

static unsigned long bfi_op(unsigned long dst, unsigned long src)
{
    __asm__ volatile("bfi %0, %1, #4, #8"
                     : "+r"(dst) : "r"(src));
    return dst;
}

static unsigned long bfxil_op(unsigned long dst, unsigned long src)
{
    __asm__ volatile("bfxil %0, %1, #4, #8"
                     : "+r"(dst) : "r"(src));
    return dst;
}

int run_test_bfm(void)
{
    unsigned long all = v[0];
    unsigned long src8 = v[1];
    unsigned long src16 = v[2];

    CHECK_EQ(bfi_op(all, src8), 0xfffffffffffffabfUL);   // 0xab<<4
    CHECK_EQ(bfxil_op(all, src16), 0xffffffffffffffbcUL); // 0xabcd[11:4]
    CHECK_EQ(bfi_op(0UL, src8), 0xab0UL);                // 旧值 0
    CHECK_EQ((unsigned long)(unsigned int)bfi_op(0xffffffffUL, v[3]),
             (unsigned long)(unsigned int)0xfffff34fUL);

    return (int)fails;
}
