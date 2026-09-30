// baremetal/perf/t_neon_vect.c
//
// P-FP NEON/Advanced SIMD 128-bit vector performance workload.
//
// It provides run_test_neon_vect() only.  The program enables FP access and
// runs throughput loops for:
//   - 128-bit integer ADD (Q form, 4S lanes)
//   - FP32 2S and 4S ADD/MUL/FMLA
//   - FP64 2D ADD/MUL/FMLA
//   - Q-register LDR/STR load/store throughput
//
// All vector constants are kept in memory and loaded with LDR Q/D so the
// generated code avoids vector-immediate/movi, GPR<->FP and FP compare
// instructions that are not currently available in the microbenchmark target.
// No SVE is used.  No performance threshold is asserted here.

#ifndef NEON_TP_ITERS
#define NEON_TP_ITERS 1024
#endif

#ifndef NEON_LDST_ITERS
#define NEON_LDST_ITERS 512
#endif

typedef unsigned int u32x4 __attribute__((vector_size(16)));
typedef float f32x2 __attribute__((vector_size(8)));
typedef float f32x4 __attribute__((vector_size(16)));
typedef double f64x2 __attribute__((vector_size(16)));

static volatile u32x4 neon_int_sink;
static volatile f32x2 neon_f32_2s_sink;
static volatile f32x4 neon_f32_4s_sink;
static volatile f64x2 neon_f64_2d_sink;

/* Memory-backed vector constants.  volatile keeps them in .data/.rodata so
 * every access is an explicit Q/D load rather than an immediate/movi. */
static const volatile u32x4 neon_i0 = {1, 2, 3, 4};
static const volatile u32x4 neon_i1 = {5, 6, 7, 8};
static const volatile u32x4 neon_i2 = {9, 10, 11, 12};
static const volatile u32x4 neon_i3 = {13, 14, 15, 16};
static const volatile u32x4 neon_iinc = {1, 2, 3, 4};

static const volatile f32x2 neon_f32_2s_a0 = {1.0f, 2.0f};
static const volatile f32x2 neon_f32_2s_a1 = {3.0f, 4.0f};
static const volatile f32x2 neon_f32_2s_a2 = {5.0f, 6.0f};
static const volatile f32x2 neon_f32_2s_a3 = {7.0f, 8.0f};
static const volatile f32x2 neon_f32_2s_inc = {0.5f, 0.25f};
static const volatile f32x2 neon_f32_2s_mul = {1.0001f, 1.0002f};
static const volatile f32x2 neon_f32_2s_m = {1.0001f, 1.0002f};
static const volatile f32x2 neon_f32_2s_c = {0.001f, 0.002f};

static const volatile f32x4 neon_f32_4s_a0 = {1.0f, 2.0f, 3.0f, 4.0f};
static const volatile f32x4 neon_f32_4s_a1 = {5.0f, 6.0f, 7.0f, 8.0f};
static const volatile f32x4 neon_f32_4s_a2 = {9.0f, 10.0f, 11.0f, 12.0f};
static const volatile f32x4 neon_f32_4s_a3 = {13.0f, 14.0f, 15.0f, 16.0f};
static const volatile f32x4 neon_f32_4s_inc = {0.5f, 0.25f, 0.125f, 0.0625f};
static const volatile f32x4 neon_f32_4s_mul = {1.0001f, 1.0002f, 1.0003f, 1.0004f};
static const volatile f32x4 neon_f32_4s_m = {1.0001f, 1.0002f, 1.0003f, 1.0004f};
static const volatile f32x4 neon_f32_4s_c = {0.001f, 0.002f, 0.003f, 0.004f};

static const volatile f64x2 neon_f64_2d_a0 = {1.0, 2.0};
static const volatile f64x2 neon_f64_2d_a1 = {3.0, 4.0};
static const volatile f64x2 neon_f64_2d_a2 = {5.0, 6.0};
static const volatile f64x2 neon_f64_2d_a3 = {7.0, 8.0};
static const volatile f64x2 neon_f64_2d_inc = {0.5, 0.25};
static const volatile f64x2 neon_f64_2d_mul = {1.0001, 1.0002};
static const volatile f64x2 neon_f64_2d_m = {1.0001, 1.0002};
static const volatile f64x2 neon_f64_2d_c = {0.001, 0.002};

static void perf_enable_fp(void)
{
    unsigned long cpacr = 3UL << 20; /* CPACR_EL1.FPEN = 11: no FP trap */
    __asm__ volatile("msr cpacr_el1, %0" : : "r"(cpacr) : "memory");
}

#define IADD4(acc, x) \
    __asm__ volatile("add %0.4s, %0.4s, %1.4s" : "+w"(acc) : "w"(x))

#define FADD2S(acc, x) \
    __asm__ volatile("fadd %0.2s, %0.2s, %1.2s" : "+w"(acc) : "w"(x))
#define FMUL2S(acc, x) \
    __asm__ volatile("fmul %0.2s, %0.2s, %1.2s" : "+w"(acc) : "w"(x))
#define FMLA2S(acc, a, b) \
    __asm__ volatile("fmla %0.2s, %1.2s, %2.2s" : "+w"(acc) : "w"(a), "w"(b))

#define FADD4S(acc, x) \
    __asm__ volatile("fadd %0.4s, %0.4s, %1.4s" : "+w"(acc) : "w"(x))
#define FMUL4S(acc, x) \
    __asm__ volatile("fmul %0.4s, %0.4s, %1.4s" : "+w"(acc) : "w"(x))
#define FMLA4S(acc, a, b) \
    __asm__ volatile("fmla %0.4s, %1.4s, %2.4s" : "+w"(acc) : "w"(a), "w"(b))

#define FADD2D(acc, x) \
    __asm__ volatile("fadd %0.2d, %0.2d, %1.2d" : "+w"(acc) : "w"(x))
#define FMUL2D(acc, x) \
    __asm__ volatile("fmul %0.2d, %0.2d, %1.2d" : "+w"(acc) : "w"(x))
#define FMLA2D(acc, a, b) \
    __asm__ volatile("fmla %0.2d, %1.2d, %2.2d" : "+w"(acc) : "w"(a), "w"(b))

static void neon_int_add_throughput(void)
{
    u32x4 a0 = neon_i0;
    u32x4 a1 = neon_i1;
    u32x4 a2 = neon_i2;
    u32x4 a3 = neon_i3;
    u32x4 inc = neon_iinc;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        IADD4(a0, inc);
        IADD4(a1, inc);
        IADD4(a2, inc);
        IADD4(a3, inc);
    }
    neon_int_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_2s_add_throughput(void)
{
    f32x2 a0 = neon_f32_2s_a0;
    f32x2 a1 = neon_f32_2s_a1;
    f32x2 a2 = neon_f32_2s_a2;
    f32x2 a3 = neon_f32_2s_a3;
    f32x2 inc = neon_f32_2s_inc;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FADD2S(a0, inc);
        FADD2S(a1, inc);
        FADD2S(a2, inc);
        FADD2S(a3, inc);
    }
    neon_f32_2s_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_2s_mul_throughput(void)
{
    f32x2 a0 = neon_f32_2s_a0;
    f32x2 a1 = neon_f32_2s_a1;
    f32x2 a2 = neon_f32_2s_a2;
    f32x2 a3 = neon_f32_2s_a3;
    f32x2 factor = neon_f32_2s_mul;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMUL2S(a0, factor);
        FMUL2S(a1, factor);
        FMUL2S(a2, factor);
        FMUL2S(a3, factor);
    }
    neon_f32_2s_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_2s_fma_throughput(void)
{
    f32x2 a0 = neon_f32_2s_a0;
    f32x2 a1 = neon_f32_2s_a1;
    f32x2 a2 = neon_f32_2s_a2;
    f32x2 a3 = neon_f32_2s_a3;
    f32x2 m = neon_f32_2s_m;
    f32x2 c = neon_f32_2s_c;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMLA2S(a0, m, c);
        FMLA2S(a1, m, c);
        FMLA2S(a2, m, c);
        FMLA2S(a3, m, c);
    }
    neon_f32_2s_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_4s_add_throughput(void)
{
    f32x4 a0 = neon_f32_4s_a0;
    f32x4 a1 = neon_f32_4s_a1;
    f32x4 a2 = neon_f32_4s_a2;
    f32x4 a3 = neon_f32_4s_a3;
    f32x4 inc = neon_f32_4s_inc;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FADD4S(a0, inc);
        FADD4S(a1, inc);
        FADD4S(a2, inc);
        FADD4S(a3, inc);
    }
    neon_f32_4s_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_4s_mul_throughput(void)
{
    f32x4 a0 = neon_f32_4s_a0;
    f32x4 a1 = neon_f32_4s_a1;
    f32x4 a2 = neon_f32_4s_a2;
    f32x4 a3 = neon_f32_4s_a3;
    f32x4 factor = neon_f32_4s_mul;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMUL4S(a0, factor);
        FMUL4S(a1, factor);
        FMUL4S(a2, factor);
        FMUL4S(a3, factor);
    }
    neon_f32_4s_sink = a0 + a1 + a2 + a3;
}

static void neon_f32_4s_fma_throughput(void)
{
    f32x4 a0 = neon_f32_4s_a0;
    f32x4 a1 = neon_f32_4s_a1;
    f32x4 a2 = neon_f32_4s_a2;
    f32x4 a3 = neon_f32_4s_a3;
    f32x4 m = neon_f32_4s_m;
    f32x4 c = neon_f32_4s_c;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMLA4S(a0, m, c);
        FMLA4S(a1, m, c);
        FMLA4S(a2, m, c);
        FMLA4S(a3, m, c);
    }
    neon_f32_4s_sink = a0 + a1 + a2 + a3;
}

static void neon_f64_2d_add_throughput(void)
{
    f64x2 a0 = neon_f64_2d_a0;
    f64x2 a1 = neon_f64_2d_a1;
    f64x2 a2 = neon_f64_2d_a2;
    f64x2 a3 = neon_f64_2d_a3;
    f64x2 inc = neon_f64_2d_inc;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FADD2D(a0, inc);
        FADD2D(a1, inc);
        FADD2D(a2, inc);
        FADD2D(a3, inc);
    }
    neon_f64_2d_sink = a0 + a1 + a2 + a3;
}

static void neon_f64_2d_mul_throughput(void)
{
    f64x2 a0 = neon_f64_2d_a0;
    f64x2 a1 = neon_f64_2d_a1;
    f64x2 a2 = neon_f64_2d_a2;
    f64x2 a3 = neon_f64_2d_a3;
    f64x2 factor = neon_f64_2d_mul;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMUL2D(a0, factor);
        FMUL2D(a1, factor);
        FMUL2D(a2, factor);
        FMUL2D(a3, factor);
    }
    neon_f64_2d_sink = a0 + a1 + a2 + a3;
}

static void neon_f64_2d_fma_throughput(void)
{
    f64x2 a0 = neon_f64_2d_a0;
    f64x2 a1 = neon_f64_2d_a1;
    f64x2 a2 = neon_f64_2d_a2;
    f64x2 a3 = neon_f64_2d_a3;
    f64x2 m = neon_f64_2d_m;
    f64x2 c = neon_f64_2d_c;

    for (int i = 0; i < NEON_TP_ITERS; i++) {
        FMLA2D(a0, m, c);
        FMLA2D(a1, m, c);
        FMLA2D(a2, m, c);
        FMLA2D(a3, m, c);
    }
    neon_f64_2d_sink = a0 + a1 + a2 + a3;
}

static void neon_ldst_throughput(void)
{
    static u32x4 src[4] __attribute__((aligned(16)));
    static u32x4 dst[4] __attribute__((aligned(16)));
    u32x4 v0, v1, v2, v3;

    for (int i = 0; i < NEON_LDST_ITERS; i++) {
        __asm__ volatile("ldr %q0, [%1]"
                         : "=w"(v0) : "r"(&src[0]) : "memory");
        __asm__ volatile("ldr %q0, [%1]"
                         : "=w"(v1) : "r"(&src[1]) : "memory");
        __asm__ volatile("ldr %q0, [%1]"
                         : "=w"(v2) : "r"(&src[2]) : "memory");
        __asm__ volatile("ldr %q0, [%1]"
                         : "=w"(v3) : "r"(&src[3]) : "memory");
        __asm__ volatile("str %q0, [%1]"
                         : : "w"(v0), "r"(&dst[0]) : "memory");
        __asm__ volatile("str %q0, [%1]"
                         : : "w"(v1), "r"(&dst[1]) : "memory");
        __asm__ volatile("str %q0, [%1]"
                         : : "w"(v2), "r"(&dst[2]) : "memory");
        __asm__ volatile("str %q0, [%1]"
                         : : "w"(v3), "r"(&dst[3]) : "memory");
    }
    neon_int_sink = v0 + v1 + v2 + v3;
}

int run_test_neon_vect(void)
{
    int fails = 0;

    perf_enable_fp();

    neon_int_add_throughput();
    neon_f32_2s_add_throughput();
    neon_f32_2s_mul_throughput();
    neon_f32_2s_fma_throughput();
    neon_f32_4s_add_throughput();
    neon_f32_4s_mul_throughput();
    neon_f32_4s_fma_throughput();
    neon_f64_2d_add_throughput();
    neon_f64_2d_mul_throughput();
    neon_f64_2d_fma_throughput();
    neon_ldst_throughput();

    /* Keep the FP vector sinks observable without FP compare instructions. */
    (void)neon_f32_2s_sink;
    (void)neon_f32_4s_sink;
    (void)neon_f64_2d_sink;

    return fails;
}

/* Compatibility alias for the planned P-INFRA PERF_ONLY path. */
int run_perf_neon_vect(void)
{
    return run_test_neon_vect();
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_neon_vect();
}
#endif
