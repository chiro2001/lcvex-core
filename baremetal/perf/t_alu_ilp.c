// LCVEX P-ALU workload: multiple independent integer operations (ILP).
//
// The 2/4/8 chain variants update separate accumulators inside one loop body.
// A superscalar or OoO implementation can overlap the independent ADD chains;
// a single-issue in-order core will serialize them.  This workload intentionally
// does not assert performance; it only checks final values for sanity.

#ifndef PERF_ALU_ILP_ITERATIONS
#define PERF_ALU_ILP_ITERATIONS 40000UL
#endif

#define PERF_NOINLINE __attribute__((noinline))

static volatile unsigned long perf_alu_ilp_sink;

PERF_NOINLINE
static unsigned long perf_alu_ilp_add2(unsigned long n, unsigned long seed)
{
    unsigned long a = seed;
    unsigned long b = seed ^ 0x5a5a5a5a5a5a5a5aUL;

    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("add %0, %0, #1" : "+r"(a));
        __asm__ volatile("add %0, %0, #1" : "+r"(b));
    }
    return a ^ b;
}

PERF_NOINLINE
static unsigned long perf_alu_ilp_add4(unsigned long n, unsigned long seed)
{
    unsigned long a = seed;
    unsigned long b = seed ^ 0x1111111111111111UL;
    unsigned long c = seed ^ 0x2222222222222222UL;
    unsigned long d = seed ^ 0x3333333333333333UL;

    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("add %0, %0, #1" : "+r"(a));
        __asm__ volatile("add %0, %0, #1" : "+r"(b));
        __asm__ volatile("add %0, %0, #1" : "+r"(c));
        __asm__ volatile("add %0, %0, #1" : "+r"(d));
    }
    return a ^ b ^ c ^ d;
}

PERF_NOINLINE
static unsigned long perf_alu_ilp_add8(unsigned long n, unsigned long seed)
{
    unsigned long a = seed;
    unsigned long b = seed ^ 0x1111111111111111UL;
    unsigned long c = seed ^ 0x2222222222222222UL;
    unsigned long d = seed ^ 0x3333333333333333UL;
    unsigned long e = seed ^ 0x4444444444444444UL;
    unsigned long f = seed ^ 0x5555555555555555UL;
    unsigned long g = seed ^ 0x6666666666666666UL;
    unsigned long h = seed ^ 0x7777777777777777UL;

    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("add %0, %0, #1" : "+r"(a));
        __asm__ volatile("add %0, %0, #1" : "+r"(b));
        __asm__ volatile("add %0, %0, #1" : "+r"(c));
        __asm__ volatile("add %0, %0, #1" : "+r"(d));
        __asm__ volatile("add %0, %0, #1" : "+r"(e));
        __asm__ volatile("add %0, %0, #1" : "+r"(f));
        __asm__ volatile("add %0, %0, #1" : "+r"(g));
        __asm__ volatile("add %0, %0, #1" : "+r"(h));
    }
    return a ^ b ^ c ^ d ^ e ^ f ^ g ^ h;
}

int run_test_alu_ilp(void)
{
    unsigned long n = PERF_ALU_ILP_ITERATIONS;
    unsigned long seed = 0x1234UL;
    unsigned long r;

    r = perf_alu_ilp_add2(n, seed);
    if (r != ((seed + n) ^ ((seed ^ 0x5a5a5a5a5a5a5a5aUL) + n)))
        return 1;

    r = perf_alu_ilp_add4(n, seed);
    if (r != ((seed + n) ^
              ((seed ^ 0x1111111111111111UL) + n) ^
              ((seed ^ 0x2222222222222222UL) + n) ^
              ((seed ^ 0x3333333333333333UL) + n)))
        return 1;

    r = perf_alu_ilp_add8(n, seed);
    if (r != ((seed + n) ^
              ((seed ^ 0x1111111111111111UL) + n) ^
              ((seed ^ 0x2222222222222222UL) + n) ^
              ((seed ^ 0x3333333333333333UL) + n) ^
              ((seed ^ 0x4444444444444444UL) + n) ^
              ((seed ^ 0x5555555555555555UL) + n) ^
              ((seed ^ 0x6666666666666666UL) + n) ^
              ((seed ^ 0x7777777777777777UL) + n)))
        return 1;

    perf_alu_ilp_sink = r;
    return 0;
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_alu_ilp(void)
{
    return run_test_alu_ilp();
}
