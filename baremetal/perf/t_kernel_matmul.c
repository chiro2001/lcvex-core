// LCVEX P-MIXED: small integer matrix multiply kernel and functional sanity.
// Self-contained; no perf_common.h dependency until P-INFRA merges.
//
// Entry: int run_test_matmul(void)
//   - fills fixed 16x16 integer matrices a[i][j] = i+j+1,
//   - runs the O(N^3) multiply a fixed number of times,
//   - verifies the product against the closed-form reference
//     C[i][j] = sum_k (i+k+1)*(k+j+1),
//   - returns 0 on success, 1 on sanity failure.
//
// This file deliberately reports no performance numbers.

#ifndef MATRIX_N
#define MATRIX_N 16u
#endif
#ifndef MATMUL_ITERATIONS
#define MATMUL_ITERATIONS 2u
#endif

__attribute__((noinline))
static void matmul_kernel(const unsigned int a[MATRIX_N][MATRIX_N],
                          const unsigned int b[MATRIX_N][MATRIX_N],
                          unsigned int c[MATRIX_N][MATRIX_N])
{
    unsigned int i, j, k;
    unsigned int sum;

    for (i = 0; i < MATRIX_N; i++) {
        for (j = 0; j < MATRIX_N; j++) {
            sum = 0u;
            for (k = 0; k < MATRIX_N; k++) {
                sum += a[i][k] * b[k][j];
            }
            c[i][j] = sum;
        }
    }
}

static unsigned int matmul_reference(unsigned int i, unsigned int j)
{
    unsigned int n = MATRIX_N;
    unsigned int s1 = n * (n - 1u) / 2u;
    unsigned int s2 = n * (n - 1u) * (2u * n - 1u) / 6u;

    return n * (i + 1u) * (j + 1u) +
           (i + 1u) * s1 +
           (j + 1u) * s1 +
           s2;
}

int run_test_matmul(void)
{
    unsigned int a[MATRIX_N][MATRIX_N];
    unsigned int b[MATRIX_N][MATRIX_N];
    unsigned int c[MATRIX_N][MATRIX_N];
    unsigned int i, j, iter;

    for (i = 0; i < MATRIX_N; i++) {
        for (j = 0; j < MATRIX_N; j++) {
            a[i][j] = i + j + 1u;
            b[i][j] = i + j + 1u;
        }
    }

    for (iter = 0; iter < MATMUL_ITERATIONS; iter++) {
        matmul_kernel(a, b, c);

        for (i = 0; i < MATRIX_N; i++) {
            for (j = 0; j < MATRIX_N; j++) {
                if (c[i][j] != matmul_reference(i, j)) {
                    return 1;
                }
            }
        }
    }

    return 0;
}

/* Compatibility alias for P-INFRA's proposed PERF_ONLY build path. */
int run_perf_matmul(void)
{
    return run_test_matmul();
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_kernel_matmul(void)
{
    return run_perf_matmul();
}
