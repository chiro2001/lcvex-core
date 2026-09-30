// P-MEM workload: load-use, store-forward, LDR/STR addressing forms,
// and LDP/STP throughput.
//
// Self-contained (perf_common.h not merged).  Provides
// int run_test_mem_ldst(void); no performance assertion.
//
// All accesses use a fixed scratch buffer in the 128 MiB physical RAM
// window (0x45200000), outside the shared 1 MiB bare-metal link image.

#define PERF_NOINLINE __attribute__((noinline))

#define LDS_BASE   0x45200000UL

#ifndef LDS_SIZE
#define LDS_SIZE   16384UL
#endif
#define LDS_WORDS  (LDS_SIZE / sizeof(unsigned long))
#define LDS_MASK   (LDS_WORDS - 1UL)
#define LDS_CELL   (LDS_WORDS - 1UL)

#ifndef LDS_ITERS
#define LDS_ITERS      8192UL
#endif
#ifndef LDS_PAIR_ITERS
#define LDS_PAIR_ITERS 4096UL
#endif

static volatile unsigned long *const ld_buf =
    (volatile unsigned long *)LDS_BASE;

static volatile unsigned long perf_sink;

static PERF_NOINLINE void ldst_init(void)
{
    unsigned long i;
    for (i = 0; i < LDS_WORDS; i++) {
        ld_buf[i] = i;
    }
}

/* Load-use: loaded value is consumed before the next dependent load. */
static PERF_NOINLINE unsigned long ldst_load_use(void)
{
    unsigned long idx = 0;
    unsigned long s = 0;
    unsigned long i;

    for (i = 0; i < LDS_ITERS; i++) {
        idx = (ld_buf[idx & LDS_MASK] + 1UL) & LDS_MASK;
        s += idx;
    }
    return s;
}

/* Store forwarding: STR immediately followed by LDR to the same address. */
static PERF_NOINLINE unsigned long ldst_store_forward(void)
{
    unsigned long v = 0;
    unsigned long s = 0;
    unsigned long i;
    volatile unsigned long *cell = &ld_buf[LDS_CELL];

    for (i = 0; i < LDS_ITERS; i++) {
        v = (i * 0x9E3779B97F4A7C15UL) ^ 0xA5A5A5A5A5A5A5A5UL;
        __asm__ volatile("str %1, [%0]"
                         :
                         : "r"(cell), "r"(v)
                         : "memory");
        __asm__ volatile("ldr %0, [%1]"
                         : "=r"(v)
                         : "r"(cell)
                         : "memory");
        s += v;
    }
    return s;
}

/* LDR/STR with unsigned-immediate offset (compiler generated array index). */
static PERF_NOINLINE unsigned long ldst_offset_read_write(void)
{
    unsigned long s = 0;
    unsigned long i;
    unsigned long v;

    for (i = 0; i < LDS_ITERS; i++) {
        v = ld_buf[i & LDS_MASK];
        ld_buf[(i + 1UL) & LDS_MASK] = v ^ i;
        s += v;
    }
    return s;
}

/* Explicit LDR/STR with register offset [base, index, lsl #3]. */
static PERF_NOINLINE unsigned long ldst_reg_offset(void)
{
    unsigned long s = 0;
    unsigned long i;
    unsigned long off;
    unsigned long v;

    for (i = 0; i < LDS_ITERS; i++) {
        off = (i + 1UL) & LDS_MASK;
        __asm__ volatile("ldr %0, [%1, %2, lsl #3]"
                         : "=r"(v)
                         : "r"(ld_buf), "r"(off)
                         : "memory");
        __asm__ volatile("str %0, [%1, %2, lsl #3]"
                         :
                         : "r"(v ^ i), "r"(ld_buf), "r"(off)
                         : "memory");
        s += v;
    }
    return s;
}

/* LDP/STP pair throughput. */
static PERF_NOINLINE unsigned long ldst_ldp_stp(void)
{
    unsigned long a = 0;
    unsigned long b = 0;
    unsigned long s = 0;
    unsigned long i;
    unsigned long idx;

    for (i = 0; i < LDS_PAIR_ITERS; i++) {
        idx = (i * 2UL) & LDS_MASK;
        __asm__ volatile("ldp %0, %1, [%2]"
                         : "=r"(a), "=r"(b)
                         : "r"(ld_buf + idx)
                         : "memory");
        a ^= i;
        b += a;
        __asm__ volatile("stp %0, %1, [%2]"
                         :
                         : "r"(a), "r"(b), "r"(ld_buf + idx)
                         : "memory");
        s += a + b;
    }
    return s;
}

int run_test_mem_ldst(void)
{
    ldst_init();
    perf_sink += ldst_load_use();
    perf_sink += ldst_store_forward();
    perf_sink += ldst_offset_read_write();
    perf_sink += ldst_reg_offset();
    perf_sink += ldst_ldp_stp();
    return 0;
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_mem_ldst();
}
#endif


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_mem_ldst(void)
{
    return run_test_mem_ldst();
}
