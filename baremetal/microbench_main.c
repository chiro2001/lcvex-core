// LCVEX microbench 主程序：按固定顺序运行全部测试，汇总失败数。
// main 返回值写入 MAGIC（startup_mb.s），runner 据此判定 PASS/FAIL。

#include "tests.h"

#ifdef PERF_ONLY
#define PERF_CONCAT_(a, b) a##b
#define PERF_CONCAT(a, b) PERF_CONCAT_(a, b)
#define PERF_DECL_(n) int run_perf_##n(void);
#define PERF_DECL(n) PERF_DECL_(n)
PERF_DECL(PERF_ONLY);
int main(void)
{
    return PERF_CONCAT(run_perf_, PERF_ONLY)();
}
#elif defined(MB_ONLY)
#define MB_CONCAT_(a, b) a##b
#define MB_CONCAT(a, b) MB_CONCAT_(a, b)
#define MB_DECL_(n) int run_test_##n(void);
#define MB_DECL(n) MB_DECL_(n)
MB_DECL(MB_ONLY);
int main(void)
{
    return MB_CONCAT(run_test_, MB_ONLY)();
}
#else

TEST_DECL(arith);
TEST_DECL(madd);
TEST_DECL(bfm);
TEST_DECL(csel);
TEST_DECL(ldst);
TEST_DECL(excl);
TEST_DECL(sys);

int main(void)
{
    unsigned long total = 0;

    total += run_test_arith();
    total += run_test_madd();
    total += run_test_bfm();
    total += run_test_csel();
    total += run_test_ldst();
    total += run_test_excl();
    total += run_test_sys();

    return (int)total;
}
#endif
