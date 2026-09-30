// microbench：CSEL/CSINC/CSINV/CSNEG 条件两分支（编译器生成 csel）。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long v[4] = { 1, 3, 0x1111, 0x2222 };

__attribute__((noinline))
static unsigned long pick_gt(unsigned long a, unsigned long b,
                             unsigned long x, unsigned long y)
{
    return (a > b) ? x : y;   // CMP + CSEL
}

__attribute__((noinline))
static unsigned long pick_inc(unsigned long a, unsigned long b,
                              unsigned long x, unsigned long y)
{
    return (a == b) ? x : (y + 1);   // CMP + CSINC
}

__attribute__((noinline))
static unsigned long pick_inv(unsigned long a, unsigned long b,
                              unsigned long x, unsigned long y)
{
    return (a < b) ? x : ~y;   // CMP + CSINV
}

__attribute__((noinline))
static unsigned long pick_neg(unsigned long a, unsigned long b,
                              unsigned long x, unsigned long y)
{
    return (a <= b) ? x : (0UL - y);   // CMP + CSNEG
}

int run_test_csel(void)
{
    unsigned long x = v[2], y = v[3];

    CHECK_EQ(pick_gt(v[1], v[0], x, y), x);    // 3>1 真 -> x
    CHECK_EQ(pick_gt(v[0], v[1], x, y), y);    // 1>3 假 -> y
    CHECK_EQ(pick_inc(v[0], v[0], x, y), x);   // eq 真 -> x
    CHECK_EQ(pick_inc(v[0], v[1], x, y), y + 1);
    CHECK_EQ(pick_inv(v[0], v[1], x, y), x);   // 1<3 真 -> x
    CHECK_EQ(pick_inv(v[1], v[0], x, y), ~y);
    CHECK_EQ(pick_neg(v[0], v[1], x, y), x);   // 1<=3 真 -> x
    CHECK_EQ(pick_neg(v[1], v[0], x, y), 0UL - y);

    return (int)fails;
}
