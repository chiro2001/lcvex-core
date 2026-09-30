// LCVEX P-MIXED: FNV-1a hash kernel and functional sanity.
// Self-contained; no perf_common.h dependency until P-INFRA merges.
//
// Entry: int run_test_hash(void)
//   - builds a fixed 256-byte input buffer,
//   - runs FNV-1a a fixed number of times,
//   - verifies against the precomputed multi-pass digest and the standard
//     FNV-1a "123456789" vector,
//   - returns 0 on success, 1 on sanity failure.
//
// This file deliberately reports no performance numbers.

#ifndef HASH_DATA_SIZE
#define HASH_DATA_SIZE 256u
#endif
#ifndef HASH_ITERATIONS
#define HASH_ITERATIONS 4u
#endif
#define FNV_OFFSET_BASIS 2166136261u
#define FNV_PRIME 16777619u

__attribute__((noinline))
static unsigned int fnv1a_update(unsigned int hash,
                                 const unsigned char *data,
                                 unsigned int len)
{
    while (len-- > 0u) {
        hash ^= *data;
        hash *= FNV_PRIME;
        data++;
    }
    return hash;
}

int run_test_hash(void)
{
    unsigned char data[HASH_DATA_SIZE];
    unsigned int i;
    unsigned int hash;

    for (i = 0; i < HASH_DATA_SIZE; i++) {
        data[i] = (unsigned char)(i * 31u + 7u);
    }

    hash = FNV_OFFSET_BASIS;
    for (i = 0; i < HASH_ITERATIONS; i++) {
        hash = fnv1a_update(hash, data, HASH_DATA_SIZE);
    }
    if (hash != 0x2c6d0dc5u) {
        return 1;
    }

    /* Standard FNV-1a 32-bit test vector: "123456789". */
    if (fnv1a_update(FNV_OFFSET_BASIS,
                     (const unsigned char *)"123456789", 9u) !=
        0xbb86b11cu) {
        return 1;
    }

    return 0;
}

/* Compatibility alias for P-INFRA's proposed PERF_ONLY build path. */
int run_perf_hash(void)
{
    return run_test_hash();
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_kernel_hash(void)
{
    return run_perf_hash();
}
