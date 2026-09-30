// LCVEX 性能 workload 公共头文件。
//
// 性能 workload 约定：
//   - 每个文件位于 baremetal/perf/t_<name>.c，导出 int run_perf_<name>(void)；
//   - 通过 PERF_ONLY=<name> 单独构建（见 scripts/build-microbench.sh）；
//   - 运行器以 MAGIC store 的返回码判定 status；性能数据只记录，不设通过/失败门限；
//   - 允许使用 CHECK/PERF_CHECK 做功能自检，但不要依赖它传递性能结论。
//
// 本头文件只提供防止优化、易失访问和循环辅助宏，不引入 libc 或时序计数：
// cycle 数由 sim/microbench 运行器从提交包统一采集。

#ifndef LCVEX_PERF_COMMON_H
#define LCVEX_PERF_COMMON_H

#define PERF_NOINLINE __attribute__((noinline))
#define PERF_INLINE static inline
#define PERF_VOLATILE volatile

// 所有 perf TU 共用的“假使用”汇点，防止编译器删除计算结果。
static PERF_VOLATILE unsigned long perf_sink __attribute__((unused));
static unsigned long perf_check_fails __attribute__((unused));

static inline void perf_use(unsigned long v)
{
    perf_sink = v;
}

#define PERF_USE(x) perf_use((unsigned long)(x))

// 编译器屏障：防止重排/删除周围的纯计算。
static inline void perf_barrier(void)
{
    __asm__ __volatile__("" ::: "memory");
}

#define PERF_BARRIER() perf_barrier()

// 循环辅助：var 由调用方命名，避免宏内固定名造成嵌套冲突。
#define PERF_LOOP(var, n) \
    for (unsigned long var = 0; var < (unsigned long)(n); ++var)

// 功能自检失败计数宏。性能 workload 返回 0 即可；CHECK 仅供正确性辅助。
#define PERF_CHECK(cond) \
    do { if (!(cond)) { perf_check_fails++; } } while (0)
#define PERF_CHECK_FAILS() (perf_check_fails)

// 导出入口声明：PERF_DECL(name) 展开为 int run_perf_##name(void)
#define PERF_DECL(name) int run_perf_##name(void)

#endif
