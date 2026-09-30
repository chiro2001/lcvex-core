// LCVEX P-ALU workload: integer ALU dependent-chain latency.
//
// Each function executes one architectural ALU operation per iteration through
// a single register dependency.  The inline asm is volatile so the compiler
// cannot fold, reassociate, or remove the operations; iterating N times yields
// a deterministic cycle count for the whole loop (including the loop branch).
//
// No performance assertion is made here; run_test_alu_latency only performs a
// small functional sanity check and returns 0 on success.

#ifndef PERF_ALU_ITERATIONS
#define PERF_ALU_ITERATIONS 50000UL
#endif

#define PERF_NOINLINE __attribute__((noinline))

static volatile unsigned long perf_alu_sink;

PERF_NOINLINE
static unsigned long perf_alu_add_chain(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("add %0, %0, #1" : "+r"(x));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_alu_sub_chain(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("sub %0, %0, #1" : "+r"(x));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_alu_and_chain(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("and %0, %0, #0x3f" : "+r"(x));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_alu_orr_chain(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("orr %0, %0, #1" : "+r"(x));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_alu_eor_chain(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("eor %0, %0, #1" : "+r"(x));
    }
    return x;
}

int run_test_alu_latency(void)
{
    unsigned long r;

    r = perf_alu_add_chain(PERF_ALU_ITERATIONS, 0x1234UL);
    if (r != 0x1234UL + PERF_ALU_ITERATIONS)
        return 1;

    r = perf_alu_sub_chain(PERF_ALU_ITERATIONS, 0x1234UL);
    if (r != 0x1234UL - PERF_ALU_ITERATIONS)
        return 1;

    if (PERF_ALU_ITERATIONS == 0UL) {
        r = perf_alu_and_chain(PERF_ALU_ITERATIONS, 0x1234UL);
        if (r != 0x1234UL)
            return 1;
        r = perf_alu_orr_chain(PERF_ALU_ITERATIONS, 0x1234UL);
        if (r != 0x1234UL)
            return 1;
    } else {
        r = perf_alu_and_chain(PERF_ALU_ITERATIONS, 0x1234UL);
        if (r != (0x1234UL & 0x3fUL))
            return 1;

        r = perf_alu_orr_chain(PERF_ALU_ITERATIONS, 0x1234UL);
        if (r != (0x1234UL | 1UL))
            return 1;
    }

    r = perf_alu_eor_chain(PERF_ALU_ITERATIONS, 0x1234UL);
    if (r != (0x1234UL ^ ((PERF_ALU_ITERATIONS & 1UL) ? 1UL : 0UL)))
        return 1;

    perf_alu_sink = r;
    return 0;
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_alu_latency(void)
{
    return run_test_alu_latency();
}
