// LCVEX perf 基础设施自测：验证 PERF_ONLY 构建/运行/JSON 链路。
// 这不是 P-ALU/MEM/FP/NEON/MC/KERNEL 的真实性能 workload。

#include "perf_common.h"

#define SMOKE_ITERS 1000UL

PERF_NOINLINE
static unsigned long smoke_work(unsigned long n)
{
    unsigned long acc = 0;
    PERF_LOOP(i, n) {
        acc += (i ^ (i >> 1)) & 0xFFFFUL;
        perf_barrier();
    }
    return acc;
}

PERF_DECL(smoke)
{
    volatile unsigned long r = smoke_work(SMOKE_ITERS);
    perf_use(r);
    return 0;
}
