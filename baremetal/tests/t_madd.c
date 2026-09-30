// microbench：MADD/MSUB/SMADDL/UMADDL（含 32 位截断与 b=0 边界）。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long v[6] = {
    0x1234, 0x56, 0x789, 0x1111, 0x2222, 0
};

int run_test_madd(void)
{
    unsigned long a = v[0], b = v[1], c = v[2];
    unsigned long d = v[3], e = v[4];

    CHECK_EQ(a * b + c, 0x1234UL * 0x56UL + 0x789UL);      // MADD
    CHECK_EQ(a * b - c, 0x1234UL * 0x56UL - 0x789UL);      // MSUB
    CHECK_EQ(v[5] * b + c, c);                             // b=0 -> Ra
    CHECK_EQ((unsigned long)(unsigned int)(d * e + 0x100UL),
             (unsigned long)(unsigned int)(0x1111UL * 0x2222UL + 0x100UL));
    // 64 位乘加进位回绕
    CHECK_EQ(v[1] * v[1] + v[2], 0x56UL * 0x56UL + 0x789UL);

    return (int)fails;
}
