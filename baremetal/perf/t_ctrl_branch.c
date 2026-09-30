// LCVEX P-ALU workload: control-flow / branch / call-return patterns.
//
// This file covers:
//   - a simple counted loop (backward branch / loop branch)
//   - a forced conditional branch pattern (taken/not-taken)
//   - CSEL-style conditional selection without a branch
//   - direct function call + return
//   - indirect call through a runtime function pointer (BLR)
//
// It only checks functional sanity; no pass/fail performance assertion.

#ifndef PERF_CTRL_ITERATIONS
#define PERF_CTRL_ITERATIONS 20000UL
#endif

#define PERF_NOINLINE __attribute__((noinline))

static volatile unsigned long perf_ctrl_sink;

PERF_NOINLINE
static unsigned long perf_ctrl_loop(unsigned long n, unsigned long seed)
{
    unsigned long acc = seed;
    for (unsigned long i = 0; i < n; i++) {
        // Volatile asm prevents the compiler from replacing the loop body
        // with a closed-form `acc += n`.
        __asm__ volatile("" : "+r"(acc));
        acc += 1;
    }
    return acc;
}

PERF_NOINLINE
static unsigned long perf_ctrl_branch_pattern(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        unsigned long t = (i & 1UL) ? 1UL : 0UL;
        __asm__ volatile(
            "cbz %1, 1f\n"
            "add %0, %0, #2\n"
            "b 2f\n"
            "1: add %0, %0, #1\n"
            "2:"
            : "+r"(x)
            : "r"(t)
            : "cc");
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_ctrl_csel_loop(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        x = (x > 0x1000UL) ? (x - 1UL) : (x + 1UL);
    }
    return x;
}

PERF_NOINLINE
static unsigned long perf_ctrl_callee(unsigned long x)
{
    return x + 1UL;
}

PERF_NOINLINE
static unsigned long perf_ctrl_direct_call_loop(unsigned long n, unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        x = perf_ctrl_callee(x);
    }
    return x;
}

typedef unsigned long (*perf_ctrl_fn_t)(unsigned long);

// Volatile keeps the indirect call from being devirtualized by the compiler,
// even under aggressive whole-program optimization/LTO.
static perf_ctrl_fn_t volatile perf_ctrl_indirect_fn;

PERF_NOINLINE
static unsigned long perf_ctrl_indirect_call_loop(unsigned long n,
                                                  unsigned long seed)
{
    unsigned long x = seed;
    for (unsigned long i = 0; i < n; i++) {
        x = perf_ctrl_indirect_fn(x);
    }
    return x;
}

int run_test_ctrl_branch(void)
{
    unsigned long n = PERF_CTRL_ITERATIONS;
    unsigned long seed = 0x1234UL;
    unsigned long r;

    r = perf_ctrl_loop(n, seed);
    if (r != seed + n)
        return 1;

    r = perf_ctrl_branch_pattern(n, seed);
    if (r != seed + ((n + 1UL) / 2UL) * 1UL + (n / 2UL) * 2UL)
        return 1;

    // Sanity for CSEL: the sequence is a simple saturating walk around the
    // threshold.  Re-run the same recurrence instead of deriving a closed form.
    r = perf_ctrl_csel_loop(n, seed);
    {
        unsigned long expected = seed;
        for (unsigned long i = 0; i < n; i++)
            expected = (expected > 0x1000UL) ? (expected - 1UL) : (expected + 1UL);
        if (r != expected)
            return 1;
    }

    r = perf_ctrl_direct_call_loop(n, seed);
    if (r != seed + n)
        return 1;

    perf_ctrl_indirect_fn = perf_ctrl_callee;
    r = perf_ctrl_indirect_call_loop(n, seed);
    if (r != seed + n)
        return 1;

    perf_ctrl_sink = r;
    return 0;
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_ctrl_branch(void)
{
    return run_test_ctrl_branch();
}
