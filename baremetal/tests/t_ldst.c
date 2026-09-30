// microbench：LDR/STR（unsigned-imm / 寄存器偏移）、LDP/STP、
// LDR literal（跳转表）。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long buf[16];
static volatile unsigned char bytes[16];

__attribute__((noinline))
static unsigned long sum_buf(void)
{
    unsigned long s = 0;
    int i;
    for (i = 0; i < 8; i++) {
        s += buf[i];               // reg-offset ldr
    }
    return s;
}

__attribute__((noinline))
static unsigned long lit_table(int i)
{
    switch (i) {
    case 0: return 0x1111UL;
    case 1: return 0x2222UL;
    case 2: return 0x3333UL;
    default: return 0xdeadUL;
    }
}

int run_test_ldst(void)
{
    int i;
    for (i = 0; i < 8; i++) {
        buf[i] = (unsigned long)i * 3UL;   // reg-offset str
    }
    CHECK_EQ(sum_buf(), 0UL + 3 + 6 + 9 + 12 + 15 + 18 + 21);
    CHECK_EQ(lit_table(1), 0x2222UL);      // LDR literal 跳转表
    CHECK_EQ(lit_table(7), 0xdeadUL);
    bytes[0] = 0x80;
    CHECK_EQ((unsigned char)bytes[0], 0x80U);
    buf[8] = 0x1122334455667788UL;
    CHECK_EQ(buf[8], 0x1122334455667788UL);

    return (int)fails;
}
