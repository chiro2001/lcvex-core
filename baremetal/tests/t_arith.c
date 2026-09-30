// microbench：ADD/ADDS/SUB/SUBS 与 NZCV（32/64 位）。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long v[6] = {
    1, 0xffffffffffffffffUL, 0x8000000000000000UL,
    0x7fffffffffffffffUL, 0xffffffffUL, 2
};

// adds x,y 后按 C 标志 cset：返回进位位
static unsigned long adds_carry(unsigned long x, unsigned long y)
{
    unsigned long c;
    __asm__ volatile("adds %0, %1, %2; cset %0, cs"
                     : "=r"(c) : "r"(x), "r"(y) : "cc");
    return c;
}

// subs x,y 后按 V 标志 cset：返回有符号溢出位
static unsigned long subs_overflow(unsigned long x, unsigned long y)
{
    unsigned long vof;
    __asm__ volatile("subs %0, %1, %2; cset %0, vs"
                     : "=r"(vof) : "r"(x), "r"(y) : "cc");
    return vof;
}

int run_test_arith(void)
{
    unsigned long a = v[0];
    unsigned long b = v[1];
    unsigned long lo = v[4];

    CHECK_EQ(a + b, 0UL);              // 64 位回绕
    CHECK_EQ(a - b, 2UL);              // 1 - (-1)
    CHECK_EQ((unsigned int)(lo + 1U), 0U);  // 32 位回绕（W 形式）
    CHECK_EQ(adds_carry(v[1], a), 1UL);  // (-1)+1 -> C=1
    CHECK_EQ(adds_carry(a, v[5]), 0UL);  // 1+2 -> C=0
    CHECK_EQ(subs_overflow(v[2], v[0]), 1UL);  // INT64_MIN - 1 溢出 -> V=1
    CHECK_EQ(subs_overflow(v[3], v[1]), 1UL);  // INT64_MAX - (-1) -> V=1

    return (int)fails;
}
