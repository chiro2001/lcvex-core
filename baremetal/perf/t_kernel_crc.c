// LCVEX P-MIXED: CRC32 kernel workload and functional sanity.
// Self-contained; no perf_common.h dependency until P-INFRA merges.
//
// Entry: int run_test_crc(void)
//   - builds a fixed 256-byte input buffer,
//   - runs the table-driven and bitwise CRC32 kernels a fixed number of times,
//   - checks table/bitwise agreement and two known vectors,
//   - returns 0 on success, 1 on sanity failure.
//
// This file deliberately reports no performance numbers.

#ifndef CRC_DATA_SIZE
#define CRC_DATA_SIZE 256u
#endif
#ifndef CRC_ITERATIONS
#define CRC_ITERATIONS 4u
#endif

static unsigned int crc32_table[256u];

static void crc32_init_table(void)
{
    unsigned int i, j, c;

    for (i = 0; i < 256u; i++) {
        c = i;
        for (j = 0; j < 8u; j++) {
            if (c & 1u) {
                c = 0xedb88320u ^ (c >> 1);
            } else {
                c >>= 1;
            }
        }
        crc32_table[i] = c;
    }
}

static unsigned int crc32_table_update(unsigned int crc,
                                       const unsigned char *data,
                                       unsigned int len)
{
    while (len-- > 0u) {
        crc = crc32_table[(crc ^ *data) & 0xffu] ^ (crc >> 8);
        data++;
    }
    return crc;
}

static unsigned int crc32_bitwise_update(unsigned int crc,
                                         const unsigned char *data,
                                         unsigned int len)
{
    unsigned int i;

    while (len-- > 0u) {
        crc ^= *data;
        data++;
        for (i = 0; i < 8u; i++) {
            if (crc & 1u) {
                crc = 0xedb88320u ^ (crc >> 1);
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

int run_test_crc(void)
{
    unsigned char data[CRC_DATA_SIZE];
    unsigned int i;
    unsigned int table_crc, bit_crc;
    unsigned int final_crc;

    for (i = 0; i < CRC_DATA_SIZE; i++) {
        data[i] = (unsigned char)(i * 31u + 7u);
    }

    crc32_init_table();

    table_crc = 0xffffffffu;
    bit_crc = 0xffffffffu;
    for (i = 0; i < CRC_ITERATIONS; i++) {
        table_crc = crc32_table_update(table_crc, data, CRC_DATA_SIZE);
        bit_crc = crc32_bitwise_update(bit_crc, data, CRC_DATA_SIZE);
    }

    final_crc = table_crc ^ 0xffffffffu;
    if (final_crc != 0x7c321b5du) {
        return 1;
    }
    if (final_crc != (bit_crc ^ 0xffffffffu)) {
        return 1;
    }

    /* Standard CRC-32/ISO-HDLC test vector: "123456789". */
    if ((crc32_table_update(0xffffffffu,
                            (const unsigned char *)"123456789", 9u) ^
         0xffffffffu) != 0xcbf43926u) {
        return 1;
    }

    return 0;
}

/* Compatibility alias for P-INFRA's proposed PERF_ONLY build path. */
int run_perf_crc(void)
{
    return run_test_crc();
}


/* P-INFRA PERF_ONLY integration alias. */
int run_perf_kernel_crc(void)
{
    return run_perf_crc();
}
