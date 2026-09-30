// baremetal/perf/t_fp_scalar.c
//
// P-FP scalar FP32/FP64 performance workload.
//
// It provides run_test_fp_scalar() only: the function enables FP access,
// runs dependency-chain and multi-way throughput loops for FADD/FSUB/FMUL/
// FMADD (FMA) and a finite FDIV latency loop, then returns 0.
//
// This file intentionally contains no performance pass/fail thresholds.
// The cycle count is provided by the external microbench/perf runner.
//
// Self-contained: no dependency on perf_common.h.  Do not compile this file
// with -mgeneral-regs-only because it uses FP/SIMD registers.

#ifndef FP_SCALAR_LAT_ITERS
#define FP_SCALAR_LAT_ITERS 1024
#endif

#ifndef FP_SCALAR_TP_ITERS
#define FP_SCALAR_TP_ITERS 512
#endif

#ifndef FP_SCALAR_FDIV_ITERS
#define FP_SCALAR_FDIV_ITERS 32
#endif

static volatile float fp32_sink;
static volatile double fp64_sink;

static void perf_enable_fp(void)
{
    unsigned long cpacr = 3UL << 20; /* CPACR_EL1.FPEN = 11: no FP trap */
    __asm__ volatile("msr cpacr_el1, %0" : : "r"(cpacr) : "memory");
}

#define FP32_ADD(acc, x) \
    __asm__ volatile("fadd %s0, %s0, %s1" : "+w"(acc) : "w"(x))
#define FP32_SUB(acc, x) \
    __asm__ volatile("fsub %s0, %s0, %s1" : "+w"(acc) : "w"(x))
#define FP32_MUL(acc, x) \
    __asm__ volatile("fmul %s0, %s0, %s1" : "+w"(acc) : "w"(x))
#define FP32_FMA(acc, a, b) \
    __asm__ volatile("fmadd %s0, %s0, %s1, %s2" : "+w"(acc) : "w"(a), "w"(b))
#define FP32_DIV(acc, d) \
    __asm__ volatile("fdiv %s0, %s0, %s1" : "+w"(acc) : "w"(d))

#define FP64_ADD(acc, x) \
    __asm__ volatile("fadd %d0, %d0, %d1" : "+w"(acc) : "w"(x))
#define FP64_SUB(acc, x) \
    __asm__ volatile("fsub %d0, %d0, %d1" : "+w"(acc) : "w"(x))
#define FP64_MUL(acc, x) \
    __asm__ volatile("fmul %d0, %d0, %d1" : "+w"(acc) : "w"(x))
#define FP64_FMA(acc, a, b) \
    __asm__ volatile("fmadd %d0, %d0, %d1, %d2" : "+w"(acc) : "w"(a), "w"(b))
#define FP64_DIV(acc, d) \
    __asm__ volatile("fdiv %d0, %d0, %d1" : "+w"(acc) : "w"(d))

static void fp32_add_latency(void)
{
    float acc = 1.0f;
    float inc = 0.5f;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP32_ADD(acc, inc);
    fp32_sink = acc;
}

static void fp32_sub_latency(void)
{
    float acc = 1.0f;
    float dec = 0.25f;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP32_SUB(acc, dec);
    fp32_sink = acc;
}

static void fp32_mul_latency(void)
{
    float acc = 1.0f;
    float factor = 1.5f;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP32_MUL(acc, factor);
    fp32_sink = acc;
}

static void fp32_fma_latency(void)
{
    float acc = 1.0f;
    float a = 1.5f;
    float b = 0.5f;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP32_FMA(acc, a, b);
    fp32_sink = acc;
}

static void fp32_add_throughput(void)
{
    float a0 = 1.0f, a1 = 0.5f, a2 = 2.0f, a3 = 0.5f;
    float a4 = 3.0f, a5 = 0.5f, a6 = 0.25f, a7 = 1.25f;
    float inc = 0.5f;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP32_ADD(a0, inc);
        FP32_ADD(a1, inc);
        FP32_ADD(a2, inc);
        FP32_ADD(a3, inc);
        FP32_ADD(a4, inc);
        FP32_ADD(a5, inc);
        FP32_ADD(a6, inc);
        FP32_ADD(a7, inc);
    }
    fp32_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp32_sub_throughput(void)
{
    float a0 = 2.0f, a1 = 1.5f, a2 = 2.0f, a3 = 0.5f;
    float a4 = 3.0f, a5 = 0.5f, a6 = 0.25f, a7 = 1.25f;
    float dec = 0.25f;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP32_SUB(a0, dec);
        FP32_SUB(a1, dec);
        FP32_SUB(a2, dec);
        FP32_SUB(a3, dec);
        FP32_SUB(a4, dec);
        FP32_SUB(a5, dec);
        FP32_SUB(a6, dec);
        FP32_SUB(a7, dec);
    }
    fp32_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp32_mul_throughput(void)
{
    float a0 = 1.0f, a1 = 0.5f, a2 = 2.0f, a3 = 0.5f;
    float a4 = 3.0f, a5 = 0.5f, a6 = 0.25f, a7 = 1.25f;
    float factor = 1.5f;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP32_MUL(a0, factor);
        FP32_MUL(a1, factor);
        FP32_MUL(a2, factor);
        FP32_MUL(a3, factor);
        FP32_MUL(a4, factor);
        FP32_MUL(a5, factor);
        FP32_MUL(a6, factor);
        FP32_MUL(a7, factor);
    }
    fp32_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp32_fma_throughput(void)
{
    float a0 = 1.0f, a1 = 0.5f, a2 = 2.0f, a3 = 0.5f;
    float a4 = 3.0f, a5 = 0.5f, a6 = 0.25f, a7 = 1.25f;
    float m = 1.5f;
    float c = 0.5f;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP32_FMA(a0, m, c);
        FP32_FMA(a1, m, c);
        FP32_FMA(a2, m, c);
        FP32_FMA(a3, m, c);
        FP32_FMA(a4, m, c);
        FP32_FMA(a5, m, c);
        FP32_FMA(a6, m, c);
        FP32_FMA(a7, m, c);
    }
    fp32_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp64_add_latency(void)
{
    double acc = 1.0;
    double inc = 0.5;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP64_ADD(acc, inc);
    fp64_sink = acc;
}

static void fp64_sub_latency(void)
{
    double acc = 1.0;
    double dec = 0.25;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP64_SUB(acc, dec);
    fp64_sink = acc;
}

static void fp64_mul_latency(void)
{
    double acc = 1.0;
    double factor = 1.5;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP64_MUL(acc, factor);
    fp64_sink = acc;
}

static void fp64_fma_latency(void)
{
    double acc = 1.0;
    double a = 1.5;
    double b = 0.5;
    for (int i = 0; i < FP_SCALAR_LAT_ITERS; i++)
        FP64_FMA(acc, a, b);
    fp64_sink = acc;
}

static void fp64_add_throughput(void)
{
    double a0 = 1.0, a1 = 0.5, a2 = 2.0, a3 = 0.5;
    double a4 = 3.0, a5 = 0.5, a6 = 0.25, a7 = 1.25;
    double inc = 0.5;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP64_ADD(a0, inc);
        FP64_ADD(a1, inc);
        FP64_ADD(a2, inc);
        FP64_ADD(a3, inc);
        FP64_ADD(a4, inc);
        FP64_ADD(a5, inc);
        FP64_ADD(a6, inc);
        FP64_ADD(a7, inc);
    }
    fp64_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp64_sub_throughput(void)
{
    double a0 = 2.0, a1 = 1.5, a2 = 2.0, a3 = 0.5;
    double a4 = 3.0, a5 = 0.5, a6 = 0.25, a7 = 1.25;
    double dec = 0.25;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP64_SUB(a0, dec);
        FP64_SUB(a1, dec);
        FP64_SUB(a2, dec);
        FP64_SUB(a3, dec);
        FP64_SUB(a4, dec);
        FP64_SUB(a5, dec);
        FP64_SUB(a6, dec);
        FP64_SUB(a7, dec);
    }
    fp64_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp64_mul_throughput(void)
{
    double a0 = 1.0, a1 = 0.5, a2 = 2.0, a3 = 0.5;
    double a4 = 3.0, a5 = 0.5, a6 = 0.25, a7 = 1.25;
    double factor = 1.5;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP64_MUL(a0, factor);
        FP64_MUL(a1, factor);
        FP64_MUL(a2, factor);
        FP64_MUL(a3, factor);
        FP64_MUL(a4, factor);
        FP64_MUL(a5, factor);
        FP64_MUL(a6, factor);
        FP64_MUL(a7, factor);
    }
    fp64_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp64_fma_throughput(void)
{
    double a0 = 1.0, a1 = 0.5, a2 = 2.0, a3 = 0.5;
    double a4 = 3.0, a5 = 0.5, a6 = 0.25, a7 = 1.25;
    double m = 1.5;
    double c = 0.5;
    for (int i = 0; i < FP_SCALAR_TP_ITERS; i++) {
        FP64_FMA(a0, m, c);
        FP64_FMA(a1, m, c);
        FP64_FMA(a2, m, c);
        FP64_FMA(a3, m, c);
        FP64_FMA(a4, m, c);
        FP64_FMA(a5, m, c);
        FP64_FMA(a6, m, c);
        FP64_FMA(a7, m, c);
    }
    fp64_sink = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

static void fp32_div_latency(void)
{
    float acc = 1.0f;
    float divisor = 0.5f;
    for (int i = 0; i < FP_SCALAR_FDIV_ITERS; i++)
        FP32_DIV(acc, divisor);
    fp32_sink = acc;
}

static void fp64_div_latency(void)
{
    double acc = 1.0;
    double divisor = 0.5;
    for (int i = 0; i < FP_SCALAR_FDIV_ITERS; i++)
        FP64_DIV(acc, divisor);
    fp64_sink = acc;
}

int run_test_fp_scalar(void)
{
    int fails = 0;

    perf_enable_fp();

    fp32_add_latency();
    fp32_sub_latency();
    fp32_mul_latency();
    fp32_fma_latency();

    fp32_add_throughput();
    fp32_sub_throughput();
    fp32_mul_throughput();
    fp32_fma_throughput();

    fp64_add_latency();
    fp64_sub_latency();
    fp64_mul_latency();
    fp64_fma_latency();

    fp64_add_throughput();
    fp64_sub_throughput();
    fp64_mul_throughput();
    fp64_fma_throughput();

    fp32_div_latency();
    fp64_div_latency();

    /* Keep the volatile sinks observable without using FP compare instructions,
     * which are not currently available on this microbenchmark target. */
    (void)fp32_sink;
    (void)fp64_sink;

    return fails;
}

/* Compatibility alias for the planned P-INFRA PERF_ONLY path. */
int run_perf_fp_scalar(void)
{
    return run_test_fp_scalar();
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_fp_scalar();
}
#endif
