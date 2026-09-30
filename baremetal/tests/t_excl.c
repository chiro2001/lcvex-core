// microbench：exclusive LDXR/STXR/LDAXR/STLXR/CLREX 自检（无 QEMU，L0）。
// 依赖 RTL 的单核顺序 exclusive 监视器语义：LDXR 记录地址+值，STXR
// 条件写并返回状态，STXR/CLREX 清监视器。

#include "tests.h"

static unsigned long fails;
static volatile unsigned long cell;

// 经典 CAS 自增循环：ldxr -> stxr，失败重试
static unsigned long excl_inc(void)
{
    unsigned long old, status;
    do {
        __asm__ volatile("ldxr %0, [%1]"
                         : "=r"(old) : "r"(&cell) : "memory");
        __asm__ volatile("stxr %w0, %1, [%2]"
                         : "=&r"(status)
                         : "r"(old + 1), "r"(&cell) : "memory");
    } while (status != 0);
    return old;
}

// LDAXR/STLXR 版本（acquire/release 变体，单核顺序语义相同）
static unsigned long excl_inc_acq_rel(void)
{
    unsigned long old, status;
    do {
        __asm__ volatile("ldaxr %0, [%1]"
                         : "=r"(old) : "r"(&cell) : "memory");
        __asm__ volatile("stlxr %w0, %1, [%2]"
                         : "=&r"(status)
                         : "r"(old + 1), "r"(&cell) : "memory");
    } while (status != 0);
    return old;
}

int run_test_excl(void)
{
    unsigned long status, v, old;

    // 1. LDXR -> STXR CAS 自增 10 次
    cell = 0;
    for (int i = 0; i < 10; i++) {
        old = excl_inc();
        CHECK_EQ(old, (unsigned long)i);
    }
    CHECK_EQ(cell, 10UL);

    // 2. 直接 STXR（未 LDXR）：失败且内存不变
    cell = 0x55;
    __asm__ volatile("stxr %w0, %1, [%2]"
                     : "=&r"(status) : "r"(0x99UL), "r"(&cell) : "memory");
    CHECK_EQ(status, 1UL);
    CHECK_EQ(cell, 0x55UL);

    // 3. LDXR -> CLREX -> STXR：失败
    __asm__ volatile("ldxr %0, [%1]" : "=r"(v) : "r"(&cell) : "memory");
    __asm__ volatile("clrex" ::: "memory");
    __asm__ volatile("stxr %w0, %1, [%2]"
                     : "=&r"(status) : "r"(0x77UL), "r"(&cell) : "memory");
    CHECK_EQ(status, 1UL);
    CHECK_EQ(cell, 0x55UL);

    // 4. LDAXR/STLXR CAS 自增 5 次
    cell = 0;
    for (int i = 0; i < 5; i++) {
        old = excl_inc_acq_rel();
        CHECK_EQ(old, (unsigned long)i);
    }
    CHECK_EQ(cell, 5UL);

    // 5. LDXR 在 cell，STXR 到不同地址：失败且不改写
    cell = 0xaa;
    __asm__ volatile("ldxr %0, [%1]" : "=r"(v) : "r"(&cell) : "memory");
    __asm__ volatile("stxr %w0, %1, [%2]"
                     : "=&r"(status) : "r"(0xbbUL), "r"(&cell + 8) : "memory");
    CHECK_EQ(status, 1UL);
    CHECK_EQ(cell, 0xaaUL);

    // 6. LDXR -> STXR 同地址：通过（0），内存更新
    __asm__ volatile("ldxr %0, [%1]" : "=r"(v) : "r"(&cell) : "memory");
    __asm__ volatile("stxr %w0, %1, [%2]"
                     : "=&r"(status) : "r"(0xccUL), "r"(&cell) : "memory");
    CHECK_EQ(status, 0UL);
    CHECK_EQ(cell, 0xccUL);

    return (int)fails;
}
