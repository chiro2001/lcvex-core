// P-MEM workload: fixed-seed pointer chasing and random access.
//
// Self-contained (perf_common.h not merged).  Provides
// int run_test_mem_random(void); no performance assertion.
//
// The array is a fixed 64K-entry pointer table (512 KiB) in the 128 MiB
// physical RAM scratch area.  The table is initialized as a full-period
// affine permutation mod 2^16:
//     next(i) = (RANDOM_MULT * i + RANDOM_INC) & RANDOM_MASK
// with RANDOM_MULT odd and == 1 mod 4 and RANDOM_INC odd (standard LCG
// full-period conditions), so pointer chasing traverses every entry before
// repeating.

#define PERF_NOINLINE __attribute__((noinline))

#ifndef RANDOM_ARRAY_SIZE
#define RANDOM_ARRAY_SIZE 8192UL
#endif
#define RANDOM_MASK       (RANDOM_ARRAY_SIZE - 1UL)
#define RANDOM_SEED       0x123456789ABCDEF0UL
#define RANDOM_MULT       6364136223846793005UL
#define RANDOM_INC        1442695040888963407UL

#ifndef RANDOM_CHASE_FACTOR
#define RANDOM_CHASE_FACTOR 8UL
#endif
#ifndef RANDOM_READ_FACTOR
#define RANDOM_READ_FACTOR 4UL
#endif
#define RANDOM_CHASE_ITERS (RANDOM_ARRAY_SIZE * RANDOM_CHASE_FACTOR)
#define RANDOM_READ_ITERS  (RANDOM_ARRAY_SIZE * RANDOM_READ_FACTOR)

#define RANDOM_BUF_BASE 0x45100000UL

static volatile unsigned long *const random_buf =
    (volatile unsigned long *)RANDOM_BUF_BASE;

static volatile unsigned long perf_sink;

static PERF_NOINLINE void random_init(void)
{
    unsigned long i;
    for (i = 0; i < RANDOM_ARRAY_SIZE; i++) {
        unsigned long nxt = (RANDOM_MULT * i + RANDOM_INC) & RANDOM_MASK;
        random_buf[i] = (unsigned long)(random_buf + nxt);
    }
}

/* Dependent pointer chase: each load supplies the address of the next load. */
static PERF_NOINLINE unsigned long random_chase(void)
{
    volatile unsigned long *cur = random_buf + (RANDOM_SEED & RANDOM_MASK);
    unsigned long i;

    for (i = 0; i < RANDOM_CHASE_ITERS; i++) {
        cur = (volatile unsigned long *)(*cur);
    }
    return (unsigned long)cur;
}

/* Independent random-index reads: cache/memory random-access throughput. */
static PERF_NOINLINE unsigned long random_reads(void)
{
    unsigned long rng = RANDOM_SEED & RANDOM_MASK;
    unsigned long s = 0;
    unsigned long i;

    for (i = 0; i < RANDOM_READ_ITERS; i++) {
        rng = (RANDOM_MULT * rng + RANDOM_INC) & RANDOM_MASK;
        s += random_buf[rng];
    }
    return s;
}

int run_test_mem_random(void)
{
    random_init();
    perf_sink += random_chase();
    perf_sink += random_reads();
    return 0;
}

#ifdef PERF_STANDALONE
int main(void)
{
    return run_test_mem_random();
}
#endif


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_mem_random(void)
{
    return run_test_mem_random();
}
