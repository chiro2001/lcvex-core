// LCVEX P-MIXED: fixed-array insertion sort kernel and functional sanity.
// Self-contained; no perf_common.h dependency until P-INFRA merges.
//
// Entry: int run_test_sort(void)
//   - fills a fixed 64-element array in reverse order,
//   - runs insertion sort a fixed number of times,
//   - verifies that the sorted result is exactly 0..63,
//   - returns 0 on success, 1 on sanity failure.
//
// This file deliberately reports no performance numbers.

#ifndef SORT_SIZE
#define SORT_SIZE 64u
#endif
#ifndef SORT_ITERATIONS
#define SORT_ITERATIONS 4u
#endif

__attribute__((noinline))
static void insertion_sort(unsigned int *arr, unsigned int n)
{
    unsigned int i, j, key;

    for (i = 1u; i < n; i++) {
        key = arr[i];
        j = i;
        while (j > 0u && arr[j - 1u] > key) {
            arr[j] = arr[j - 1u];
            j--;
        }
        arr[j] = key;
    }
}

int run_test_sort(void)
{
    unsigned int data[SORT_SIZE];
    unsigned int i, iter;

    for (iter = 0; iter < SORT_ITERATIONS; iter++) {
        for (i = 0; i < SORT_SIZE; i++) {
            data[i] = SORT_SIZE - 1u - i;
        }

        insertion_sort(data, SORT_SIZE);

        for (i = 0; i < SORT_SIZE; i++) {
            if (data[i] != i) {
                return 1;
            }
        }
    }

    return 0;
}

/* Compatibility alias for P-INFRA's proposed PERF_ONLY build path. */
int run_perf_sort(void)
{
    return run_test_sort();
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_kernel_sort(void)
{
    return run_perf_sort();
}
