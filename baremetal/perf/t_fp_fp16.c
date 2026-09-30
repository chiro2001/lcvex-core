// baremetal/perf/t_fp_fp16.c
//
// P-FP FP16 half-precision scalar performance workload.
//
// The toolchain supports _Float16 with -march=armv8.2-a+fp16.  This file uses
// direct scalar half FADD/FSUB/FMUL/FMADD (FMA) instructions through inline
// assembly.  The assembly keeps all live values in caller-saved SIMD register
// halves and avoids FP16 memory load/store, GPR<->FP moves and FP compare
// instructions that are not currently available in the microbenchmark target.
//
// No performance thresholds are asserted here; the external perf/microbench
// runner supplies the cycle measurement.

#pragma GCC target("arch=armv8.2-a+fp16")

#ifndef FP16_TP_ITERS
#define FP16_TP_ITERS 2048
#endif

static volatile float fp16_sink;

static void perf_enable_fp(void)
{
    unsigned long cpacr = 3UL << 20; /* CPACR_EL1.FPEN = 11: no FP trap */
    __asm__ volatile("msr cpacr_el1, %0" : : "r"(cpacr) : "memory");
}

/* All FP registers below are v0..v7 plus v16/v17: caller-saved on AArch64,
 * so no FP stack save/restore is emitted before CPACR is enabled. */

#define FP16_STORE_SINK() \
    "fcvt s0, h0\n" \
    "str s0, [%[sink]]\n"

static void fp16_add_throughput(void)
{
    __asm__ volatile(
        "fmov h0, #1.0\n"
        "fmov h1, #1.5\n"
        "fmov h2, #2.0\n"
        "fmov h3, #2.5\n"
        "fmov h4, #3.0\n"
        "fmov h5, #0.5\n"
        "fmov h6, #0.25\n"
        "fmov h7, #1.25\n"
        "fmov h16, #0.5\n"
        "mov x9, %[iters]\n"
        "1:\n"
        "fadd h0, h0, h16\n"
        "fadd h1, h1, h16\n"
        "fadd h2, h2, h16\n"
        "fadd h3, h3, h16\n"
        "fadd h4, h4, h16\n"
        "fadd h5, h5, h16\n"
        "fadd h6, h6, h16\n"
        "fadd h7, h7, h16\n"
        "subs x9, x9, #1\n"
        "b.ne 1b\n"
        "fadd h0, h0, h1\n"
        "fadd h0, h0, h2\n"
        "fadd h0, h0, h3\n"
        "fadd h0, h0, h4\n"
        "fadd h0, h0, h5\n"
        "fadd h0, h0, h6\n"
        "fadd h0, h0, h7\n"
        FP16_STORE_SINK()
        :
        : [sink] "r"(&fp16_sink), [iters] "r"((long)FP16_TP_ITERS)
        : "x9", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "memory", "cc");
}

static void fp16_sub_throughput(void)
{
    __asm__ volatile(
        "fmov h0, #2.0\n"
        "fmov h1, #1.5\n"
        "fmov h2, #2.0\n"
        "fmov h3, #0.5\n"
        "fmov h4, #3.0\n"
        "fmov h5, #0.5\n"
        "fmov h6, #0.25\n"
        "fmov h7, #1.25\n"
        "fmov h16, #0.25\n"
        "mov x9, %[iters]\n"
        "1:\n"
        "fsub h0, h0, h16\n"
        "fsub h1, h1, h16\n"
        "fsub h2, h2, h16\n"
        "fsub h3, h3, h16\n"
        "fsub h4, h4, h16\n"
        "fsub h5, h5, h16\n"
        "fsub h6, h6, h16\n"
        "fsub h7, h7, h16\n"
        "subs x9, x9, #1\n"
        "b.ne 1b\n"
        "fadd h0, h0, h1\n"
        "fadd h0, h0, h2\n"
        "fadd h0, h0, h3\n"
        "fadd h0, h0, h4\n"
        "fadd h0, h0, h5\n"
        "fadd h0, h0, h6\n"
        "fadd h0, h0, h7\n"
        FP16_STORE_SINK()
        :
        : [sink] "r"(&fp16_sink), [iters] "r"((long)FP16_TP_ITERS)
        : "x9", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "memory", "cc");
}

static void fp16_mul_throughput(void)
{
    __asm__ volatile(
        "fmov h0, #1.0\n"
        "fmov h1, #1.5\n"
        "fmov h2, #2.0\n"
        "fmov h3, #2.5\n"
        "fmov h4, #3.0\n"
        "fmov h5, #0.5\n"
        "fmov h6, #0.25\n"
        "fmov h7, #1.25\n"
        "fmov h16, #1.5\n"
        "mov x9, %[iters]\n"
        "1:\n"
        "fmul h0, h0, h16\n"
        "fmul h1, h1, h16\n"
        "fmul h2, h2, h16\n"
        "fmul h3, h3, h16\n"
        "fmul h4, h4, h16\n"
        "fmul h5, h5, h16\n"
        "fmul h6, h6, h16\n"
        "fmul h7, h7, h16\n"
        "subs x9, x9, #1\n"
        "b.ne 1b\n"
        "fadd h0, h0, h1\n"
        "fadd h0, h0, h2\n"
        "fadd h0, h0, h3\n"
        "fadd h0, h0, h4\n"
        "fadd h0, h0, h5\n"
        "fadd h0, h0, h6\n"
        "fadd h0, h0, h7\n"
        FP16_STORE_SINK()
        :
        : [sink] "r"(&fp16_sink), [iters] "r"((long)FP16_TP_ITERS)
        : "x9", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "memory", "cc");
}

static void fp16_fma_throughput(void)
{
    __asm__ volatile(
        "fmov h0, #1.0\n"
        "fmov h1, #1.5\n"
        "fmov h2, #2.0\n"
        "fmov h3, #2.5\n"
        "fmov h4, #3.0\n"
        "fmov h5, #0.5\n"
        "fmov h6, #0.25\n"
        "fmov h7, #1.25\n"
        "fmov h16, #1.5\n"
        "fmov h17, #0.5\n"
        "mov x9, %[iters]\n"
        "1:\n"
        "fmadd h0, h0, h16, h17\n"
        "fmadd h1, h1, h16, h17\n"
        "fmadd h2, h2, h16, h17\n"
        "fmadd h3, h3, h16, h17\n"
        "fmadd h4, h4, h16, h17\n"
        "fmadd h5, h5, h16, h17\n"
        "fmadd h6, h6, h16, h17\n"
        "fmadd h7, h7, h16, h17\n"
        "subs x9, x9, #1\n"
        "b.ne 1b\n"
        "fadd h0, h0, h1\n"
        "fadd h0, h0, h2\n"
        "fadd h0, h0, h3\n"
        "fadd h0, h0, h4\n"
        "fadd h0, h0, h5\n"
        "fadd h0, h0, h6\n"
        "fadd h0, h0, h7\n"
        FP16_STORE_SINK()
        :
        : [sink] "r"(&fp16_sink), [iters] "r"((long)FP16_TP_ITERS)
        : "x9", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "memory", "cc");
}

int run_test_fp_fp16(void)
{
    int fails = 0;

    perf_enable_fp();

    fp16_add_throughput();
    fp16_sub_throughput();
    fp16_mul_throughput();
    fp16_fma_throughput();

    /* Keep the sink observable. */
    (void)fp16_sink;
    return fails;
}

/* Compatibility alias for the planned P-INFRA PERF_ONLY path. */
int run_perf_fp_fp16(void)
{
    return run_test_fp_fp16();
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_fp_fp16();
}
#endif
