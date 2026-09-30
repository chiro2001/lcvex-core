// LCVEX P-ALU workload: multiply/divide throughput and latency probes.
//
// Operations covered (AArch64 scalar):
//   MADD  (multiply-add, no rounding)
//   UMULH (unsigned multiply high)
//   UDIV  (unsigned divide)
//   SDIV  (signed divide)
//
// Each instruction has a serial dependent-chain version and a two-way
// independent version.  No performance assertion is made; run_test_muldiv
// only checks functional sanity.

#ifndef PERF_MULDIV_ITERATIONS
#define PERF_MULDIV_ITERATIONS 1000UL
#endif

#define PERF_NOINLINE __attribute__((noinline))

static volatile unsigned long perf_muldiv_sink;

// ---------- MADD ----------

PERF_NOINLINE
static unsigned long perf_mul_madd_chain(unsigned long n,
                                         unsigned long seed,
                                         unsigned long a,
                                         unsigned long b)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("madd %0, %1, %2, %0" : "+r"(x) : "r"(a), "r"(b));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_mul_madd_ilp2(unsigned long n,
                                        unsigned long seed,
                                        unsigned long a,
                                        unsigned long b)
{
    unsigned long x = seed;
    unsigned long y = seed ^ 0x5555555555555555UL;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("madd %0, %1, %2, %0" : "+r"(x) : "r"(a), "r"(b));
        __asm__ volatile("madd %0, %1, %2, %0" : "+r"(y) : "r"(a), "r"(b));
    }
    return x ^ y;
}

// ---------- UMULH ----------

PERF_NOINLINE
static unsigned long perf_mul_umulh_chain(unsigned long n,
                                          unsigned long seed,
                                          unsigned long a)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("umulh %0, %0, %1" : "+r"(x) : "r"(a));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_mul_umulh_ilp2(unsigned long n,
                                         unsigned long seed,
                                         unsigned long a)
{
    unsigned long x = seed;
    unsigned long y = seed ^ 0xaaaaaaaaaaaaaaaaUL;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("umulh %0, %0, %1" : "+r"(x) : "r"(a));
        __asm__ volatile("umulh %0, %0, %1" : "+r"(y) : "r"(a));
    }
    return x ^ y;
}

// ---------- UDIV ----------

PERF_NOINLINE
static unsigned long perf_div_udiv_chain(unsigned long n,
                                         unsigned long seed,
                                         unsigned long d)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("udiv %0, %0, %1" : "+r"(x) : "r"(d));
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_div_udiv_ilp2(unsigned long n,
                                        unsigned long seed,
                                        unsigned long d)
{
    unsigned long x = seed;
    unsigned long y = seed ^ 0x7777777777777777UL;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("udiv %0, %0, %1" : "+r"(x) : "r"(d));
        __asm__ volatile("udiv %0, %0, %1" : "+r"(y) : "r"(d));
    }
    return x ^ y;
}

// ---------- SDIV ----------

PERF_NOINLINE
static unsigned long perf_div_sdiv_chain(unsigned long n,
                                         unsigned long seed,
                                         long d)
{
    long x = (long)seed;
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("sdiv %0, %0, %1" : "+r"(x) : "r"(d));
    }
    return (unsigned long)x;
}

PERF_NOINLINE
static unsigned long perf_div_sdiv_ilp2(unsigned long n,
                                        unsigned long seed,
                                        long d)
{
    long x = (long)seed;
    long y = (long)(seed ^ 0x7777777777777777UL);
    for (unsigned long i = 0; i < n; i++) {
        __asm__ volatile("sdiv %0, %0, %1" : "+r"(x) : "r"(d));
        __asm__ volatile("sdiv %0, %0, %1" : "+r"(y) : "r"(d));
    }
    return (unsigned long)(x ^ y);
}

int run_test_muldiv(void)
{
    unsigned long n = PERF_MULDIV_ITERATIONS;
    unsigned long seed = 0x123456789abcdef0UL;
    unsigned long a = 3UL;
    unsigned long b = 5UL;
    unsigned long r;

    // MADD: x += a*b each iteration.
    r = perf_mul_madd_chain(n, seed, a, b);
    if (r != seed + n * (a * b))
        return 1;

    r = perf_mul_madd_ilp2(n, seed, a, b);
    if (r != ((seed + n * (a * b)) ^
              ((seed ^ 0x5555555555555555UL) + n * (a * b))))
        return 1;

    // UMULH with a = 2^32: high half becomes seed >> 32 after one step and
    // then 0 after the next.
    {
        unsigned long exp_x = (n == 0UL) ? seed : (n == 1UL) ? (seed >> 32) : 0UL;
        unsigned long exp_y = (n == 0UL) ? (seed ^ 0xaaaaaaaaaaaaaaaaUL)
                                         : (n == 1UL) ? ((seed ^ 0xaaaaaaaaaaaaaaaaUL) >> 32) : 0UL;
        r = perf_mul_umulh_chain(n, seed, 0x100000000UL);
        if (r != exp_x)
            return 1;
        r = perf_mul_umulh_ilp2(n, seed, 0x100000000UL);
        if (r != (exp_x ^ exp_y))
            return 1;
    }

    // UDIV by 2 repeatedly is the same as an unsigned logical shift right;
    // it reaches 0 after at most 64 iterations.
    {
        unsigned long exp_x = (n >= 64UL) ? 0UL : (seed >> n);
        unsigned long exp_y = (n >= 64UL) ? 0UL : ((seed ^ 0x7777777777777777UL) >> n);
        r = perf_div_udiv_chain(n, seed, 2UL);
        if (r != exp_x)
            return 1;
        r = perf_div_udiv_ilp2(n, seed, 2UL);
        if (r != (exp_x ^ exp_y))
            return 1;
    }

    // SDIV by 2 with a positive seed behaves like the unsigned case.
    {
        unsigned long exp_x = (n >= 64UL) ? 0UL : (seed >> n);
        unsigned long exp_y = (n >= 64UL) ? 0UL : ((seed ^ 0x7777777777777777UL) >> n);
        r = perf_div_sdiv_chain(n, seed, 2L);
        if (r != exp_x)
            return 1;
        r = perf_div_sdiv_ilp2(n, seed, 2L);
        if (r != (exp_x ^ exp_y))
            return 1;
    }

    perf_muldiv_sink = r;
    return 0;
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_muldiv(void)
{
    return run_test_muldiv();
}
