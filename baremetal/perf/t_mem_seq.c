// P-MEM workload: sequential read / write / copy across multiple buffer sizes.
//
// This file is intentionally self-contained (perf_common.h is not yet merged).
// It provides only int run_test_mem_seq(void); no performance pass/fail
// assertion is made.  The microbench/PERF runner records the cycle count for
// the whole phase; P-INFRA may later add JSON/reporting.
//
// Buffers are placed in the 128 MiB physical RAM window (0x40000000..0x48000000)
// at fixed scratch addresses, outside the 1 MiB bare-metal link image.  The
// default table keeps the total memory traffic inside the 5M-cycle budget;
// the largest default buffer is 256 KiB.

#define PERF_NOINLINE __attribute__((noinline))

#define SEQ_SRC_BASE 0x45000000UL          /* 8 MiB scratch source region */
#define SEQ_DST_BASE 0x45800000UL          /* 8 MiB scratch destination region */

#ifndef SEQ_SIZE_COUNT
#define SEQ_SIZE_COUNT 4UL
#endif

#ifndef SEQ_SIZE_0
#define SEQ_SIZE_0 (4UL * 1024)
#endif
#ifndef SEQ_SIZE_1
#define SEQ_SIZE_1 (16UL * 1024)
#endif
#ifndef SEQ_SIZE_2
#define SEQ_SIZE_2 (64UL * 1024)
#endif
#ifndef SEQ_SIZE_3
#define SEQ_SIZE_3 (256UL * 1024)
#endif

#ifndef SEQ_REP_0
#define SEQ_REP_0 16UL
#endif
#ifndef SEQ_REP_1
#define SEQ_REP_1 4UL
#endif
#ifndef SEQ_REP_2
#define SEQ_REP_2 1UL
#endif
#ifndef SEQ_REP_3
#define SEQ_REP_3 1UL
#endif

static volatile unsigned long *const seq_src =
    (volatile unsigned long *)SEQ_SRC_BASE;
static volatile unsigned long *const seq_dst =
    (volatile unsigned long *)SEQ_DST_BASE;

/* Sink prevents a benchmark from being optimized away entirely. */
static volatile unsigned long perf_sink;

static PERF_NOINLINE void seq_write(volatile unsigned long *buf,
                                    unsigned long words,
                                    unsigned long seed)
{
    unsigned long i;
    for (i = 0; i < words; i++) {
        buf[i] = seed ^ (i * 0x9E3779B97F4A7C15UL);
    }
}

static PERF_NOINLINE unsigned long seq_read(volatile unsigned long *buf,
                                           unsigned long words)
{
    unsigned long s = 0;
    unsigned long i;
    for (i = 0; i < words; i++) {
        s += buf[i];
    }
    return s;
}

static PERF_NOINLINE void seq_copy(volatile unsigned long *dst,
                                   volatile unsigned long *src,
                                   unsigned long words)
{
    unsigned long i;
    for (i = 0; i < words; i++) {
        dst[i] = src[i];
    }
}

/*
 * Repeat counts are chosen so total work is bounded and fits the default
 * 5M-cycle perf budget.  Runtime can be scaled by editing these tables or by
 * using PERF_CFLAGS=-DSEQ_SIZE_*=... / -DSEQ_REP_*=... overrides.
 */
static const unsigned long seq_sizes[] = {
    SEQ_SIZE_0,
    SEQ_SIZE_1,
    SEQ_SIZE_2,
    SEQ_SIZE_3,
};

static const unsigned long seq_reps[] = {
    SEQ_REP_0,
    SEQ_REP_1,
    SEQ_REP_2,
    SEQ_REP_3,
};

int run_test_mem_seq(void)
{
    unsigned long i, rep, words;

    for (i = 0; i < SEQ_SIZE_COUNT; i++) {
        words = seq_sizes[i] / (unsigned long)sizeof(unsigned long);
        for (rep = 0; rep < seq_reps[i]; rep++) {
            seq_write(seq_src, words, i + rep * 0x1000UL);
            perf_sink += seq_read(seq_src, words);
            seq_copy(seq_dst, seq_src, words);
        }
    }

    /* Keep a single observable use of all three workloads. */
    perf_sink += seq_src[0] + seq_dst[0];
    return 0;
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_mem_seq();
}
#endif


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_mem_seq(void)
{
    return run_test_mem_seq();
}
