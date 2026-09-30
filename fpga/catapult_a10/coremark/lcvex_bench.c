// LCVEX B25 BRAM-resident correctness microbench and CoreMark command glue.
//
// This file is intentionally freestanding: it uses no libc, heap, floating
// point, architectural timer, or DDR.  The monitor calls the three exported
// entry points for its t/v/c commands.

#include "coremark.h"

typedef unsigned char lcvex_u8;
typedef signed char lcvex_s8;
typedef unsigned short lcvex_u16;
typedef signed short lcvex_s16;
typedef unsigned int lcvex_u32;
typedef signed int lcvex_s32;
typedef unsigned long lcvex_u64;
typedef signed long lcvex_s64;

#define LCVEX_CLOCK_HZ 25000000UL
#define LCVEX_COREMARK_MIN_CYCLES 250000000UL
#define LCVEX_MB_TEST_COUNT 24U

#define COREMARK_SEED_CRC 0xe9f5U
#define COREMARK_LIST_CRC 0xe714U
#define COREMARK_MATRIX_CRC 0x1fd7U
#define COREMARK_STATE_CRC 0x8e3aU

extern int coremark_main(void);
extern void lcvex_uart_putc(unsigned int ch);
extern void lcvex_uart_puts(const char *text);

extern volatile ee_u32 lcvex_coremark_quiet;

static volatile lcvex_u64 bench_a = 0x0123456789abcdefUL;
static volatile lcvex_u64 bench_b = 0x1111111111111111UL;
static volatile lcvex_u64 bench_c = 0xfedcba9876543210UL;
static volatile lcvex_u32 bench_u32_a = 0xfffffff0U;
static volatile lcvex_u32 bench_u32_b = 0x00000031U;
static volatile lcvex_u32 bench_u32_mul_a = 0xfedcba98U;
static volatile lcvex_u32 bench_u32_mul_b = 0x00010203U;
static volatile lcvex_s64 bench_s64_a = -123456789L;
static volatile lcvex_s64 bench_s64_b = 12345L;
static volatile lcvex_s64 bench_shift_signed = (lcvex_s64)0xf000000000000123UL;
static volatile lcvex_u64 bench_u64_divisor = 1234567UL;
static volatile lcvex_u32 bench_loop_seed = 0x5aU;
static volatile lcvex_u64 bench_results[LCVEX_MB_TEST_COUNT];

struct bench_unsigned_widths {
    lcvex_u8 byte_value;
    lcvex_u8 padding;
    lcvex_u16 half_value;
    lcvex_u32 word_value;
};

struct bench_signed_widths {
    lcvex_s8 byte_value;
    lcvex_u8 padding;
    lcvex_s16 half_value;
    lcvex_s32 word_value;
    lcvex_u64 double_value;
};

static volatile struct bench_unsigned_widths bench_unsigned_mem
    __attribute__((aligned(8)));
static volatile struct bench_signed_widths bench_signed_mem
    __attribute__((aligned(8)));

typedef lcvex_u64 (*bench_fn_t)(lcvex_u64);

static __attribute__((noinline)) lcvex_u64 bench_direct_fn(lcvex_u64 value)
{
    return (value ^ 0xa5a5a5a5a5a5a5a5UL) + 0x1234UL;
}

static __attribute__((noinline)) lcvex_u64 bench_indirect_fn(lcvex_u64 value)
{
    return (value + 0x1020304050607080UL) ^ 0x55aa55aa55aa55aaUL;
}

static bench_fn_t volatile bench_indirect_ptr = bench_indirect_fn;

static __attribute__((noinline)) lcvex_u64 run_test(lcvex_u32 id)
{
    lcvex_u64 a = bench_a;
    lcvex_u64 b = bench_b;
    lcvex_u64 c = bench_c;

    switch (id) {
    case 1:
        return a + b;
    case 2:
        return a - b;
    case 3:
        return (lcvex_u64)(bench_u32_a + bench_u32_b);
    case 4:
        return a & b;
    case 5:
        return a | b;
    case 6:
        return a ^ b;
    case 7:
        return a << 7;
    case 8:
        return c >> 11;
    case 9:
        return (lcvex_u64)(bench_shift_signed >> 12);
    case 10:
        return (a >> 13) | (a << (64 - 13));
    case 11:
        return bench_s64_a < bench_s64_b ? 0xaaaaaaaa55555555UL
                                         : 0x55555555aaaaaaaaUL;
    case 12:
        return c > a ? c : a;
    case 13:
        return (a & 1UL) != 0 ? a + 9UL : a - 9UL;
    case 14: {
        lcvex_u64 sum = 0;
        lcvex_u32 i;
        for (i = 0; i < 16; ++i)
            sum += (lcvex_u64)((i * 7U) ^ bench_loop_seed);
        return sum;
    }
    case 15:
        return bench_direct_fn(a);
    case 16:
        return bench_indirect_ptr(b);
    case 17: {
        volatile lcvex_u64 stack_words[4];
        stack_words[0] = a;
        stack_words[1] = b;
        stack_words[2] = c;
        stack_words[3] = stack_words[0] + stack_words[1];
        return stack_words[3] ^ stack_words[2];
    }
    case 18:
        return (lcvex_u64)(lcvex_u32)(bench_u32_mul_a * bench_u32_mul_b);
    case 19:
        return a * b;
    case 20:
        return (lcvex_u64)(((unsigned __int128)a *
                            (unsigned __int128)c) >> 64);
    case 21:
        return (lcvex_u64)(bench_s64_a / bench_s64_b);
    case 22:
        return c / bench_u64_divisor;
    case 23:
        bench_unsigned_mem.byte_value = 0x81U;
        bench_unsigned_mem.half_value = 0x8001U;
        bench_unsigned_mem.word_value = 0x80000001U;
        return ((lcvex_u64)bench_unsigned_mem.byte_value << 48) |
               ((lcvex_u64)bench_unsigned_mem.half_value << 32) |
               (lcvex_u64)bench_unsigned_mem.word_value;
    case 24: {
        lcvex_s64 extended;
        bench_signed_mem.byte_value = (lcvex_s8)0x80U;
        bench_signed_mem.half_value = (lcvex_s16)0xff00U;
        bench_signed_mem.word_value = (lcvex_s32)0x80000000U;
        bench_signed_mem.double_value = 0x1020304050607080UL;
        extended = (lcvex_s64)bench_signed_mem.byte_value;
        extended ^= (lcvex_s64)bench_signed_mem.half_value;
        extended ^= (lcvex_s64)bench_signed_mem.word_value;
        return (lcvex_u64)extended ^ bench_signed_mem.double_value;
    }
    default:
        return 0;
    }
}

static const lcvex_u64 bench_expected[LCVEX_MB_TEST_COUNT] = {
    0x123456789abcdf00UL,
    0xf0123456789abcdeUL,
    0x0000000000000021UL,
    0x0101010101010101UL,
    0x1133557799bbddffUL,
    0x1032547698badcfeUL,
    0x91a2b3c4d5e6f780UL,
    0x001fdb97530eca86UL,
    0xffff000000000000UL,
    0x6f78091a2b3c4d5eUL,
    0xaaaaaaaa55555555UL,
    0xfedcba9876543210UL,
    0x0123456789abcdf8UL,
    0x0000000000000468UL,
    0xa486e0c22c0e7a7eUL,
    0x749b14fb34dbd43bUL,
    0xece8ece0ece8ed10UL,
    0x0000000070a35fc8UL,
    0xffec94f918f48bdfUL,
    0x0121fa00ad77d742UL,
    0xffffffffffffd8f0UL,
    0x00000d8776d2ea81UL,
    0x0081800180000001UL,
    0xefdfcfbfd0607000UL
};

static void put_hex_nibble(lcvex_u32 value)
{
    lcvex_uart_putc(value < 10U ? (unsigned int)('0' + value)
                                : (unsigned int)('A' + value - 10U));
}

static void put_hex32(lcvex_u32 value)
{
    lcvex_u32 shift;
    for (shift = 28; ; shift -= 4) {
        put_hex_nibble((value >> shift) & 0xfU);
        if (shift == 0)
            break;
    }
}

static void put_hex64(lcvex_u64 value)
{
    put_hex32((lcvex_u32)(value >> 32));
    put_hex32((lcvex_u32)value);
}

static void put_dec64(lcvex_u64 value)
{
    char digits[24];
    lcvex_u32 count = 0;
    do {
        digits[count++] = (char)('0' + value % 10UL);
        value /= 10UL;
    } while (value != 0);
    while (count != 0)
        lcvex_uart_putc((unsigned int)digits[--count]);
}

// Return floor(numerator * 1000 / denominator) without constructing the
// potentially overflowing product.  In valid full runs denominator is
// nonzero and at least 250,000,000; the small remainder loop is outside the
// measured interval.
static lcvex_u64 ratio_x1000(lcvex_u64 numerator, lcvex_u64 denominator)
{
    lcvex_u64 result = (numerator / denominator) * 1000UL;
    lcvex_u64 remainder = numerator % denominator;
    lcvex_u64 accumulator = 0;
    lcvex_u32 index;

    for (index = 0; index < 1000U; ++index) {
        if (accumulator >= denominator - remainder) {
            accumulator -= denominator - remainder;
            result++;
        } else {
            accumulator += remainder;
        }
    }
    return result;
}

static lcvex_u32 signature_byte(lcvex_u32 signature, lcvex_u8 value)
{
    signature ^= value;
    return signature * 16777619U;
}

static lcvex_u32 signature_result(lcvex_u32 signature, lcvex_u32 id,
                                  lcvex_u64 value)
{
    lcvex_u32 index;
    signature = signature_byte(signature, (lcvex_u8)id);
    for (index = 0; index < 8; ++index) {
        signature = signature_byte(signature, (lcvex_u8)value);
        value >>= 8;
    }
    return signature;
}

void lcvex_run_correctness(void)
{
    lcvex_u32 id;
    // A fixed, domain-specific FNV-1a seed makes the 24-result ABI signature
    // 0x8679CF21.  The host checker independently recomputes the same stream.
    lcvex_u32 signature = 0x45f335e4U;

    for (id = 1; id <= LCVEX_MB_TEST_COUNT; ++id) {
        lcvex_u64 got = run_test(id);
        lcvex_u64 expected = bench_expected[id - 1U];
        bench_results[id - 1U] = got;
        signature = signature_result(signature, id, got);
        if (got != expected) {
            lcvex_uart_puts("MBFAIL ");
            put_dec64(id);
            lcvex_uart_puts(" ");
            put_hex64(got);
            lcvex_uart_puts(" ");
            put_hex64(expected);
            lcvex_uart_puts("\r\n");
            return;
        }
    }

    lcvex_uart_puts("MBPASS 24 ");
    put_hex32(signature);
    lcvex_uart_puts("\r\n");
}

static void configure_coremark(lcvex_u32 iterations, lcvex_u32 quiet)
{
    seed1_volatile = 0;
    seed2_volatile = 0;
    seed3_volatile = 0x66;
    seed4_volatile = (ee_s32)iterations;
    seed5_volatile = 0;
    lcvex_coremark_quiet = quiet;
    lcvex_coremark_reset_observation();
}

static lcvex_u32 coremark_common_valid(void)
{
    return lcvex_coremark_seedcrc == COREMARK_SEED_CRC &&
           lcvex_coremark_crclist == COREMARK_LIST_CRC &&
           lcvex_coremark_crcmatrix == COREMARK_MATRIX_CRC &&
           lcvex_coremark_crcstate == COREMARK_STATE_CRC &&
           lcvex_coremark_crc_errors == 0;
}

static void put_coremark_crc_fields(void)
{
    lcvex_uart_puts(" seed=");
    put_hex32((lcvex_u32)lcvex_coremark_seedcrc);
    lcvex_uart_puts(" list=");
    put_hex32((lcvex_u32)lcvex_coremark_crclist);
    lcvex_uart_puts(" matrix=");
    put_hex32((lcvex_u32)lcvex_coremark_crcmatrix);
    lcvex_uart_puts(" state=");
    put_hex32((lcvex_u32)lcvex_coremark_crcstate);
    lcvex_uart_puts(" final=");
    put_hex32((lcvex_u32)lcvex_coremark_crcfinal);
}

void lcvex_run_coremark_short(void)
{
    lcvex_uart_puts("CMSTART V\r\n");
    configure_coremark(1U, 1U);
    (void)coremark_main();
    lcvex_coremark_quiet = 0;

    if (coremark_common_valid() &&
        lcvex_coremark_reported_iterations == 1U &&
        lcvex_coremark_duration_error == 1U &&
        lcvex_coremark_validated == 0U) {
        lcvex_uart_puts("CMSELF PASS");
    } else {
        lcvex_uart_puts("CMSELF FAIL");
    }
    put_coremark_crc_fields();
    lcvex_uart_puts(" iterations=");
    put_dec64(lcvex_coremark_reported_iterations);
    lcvex_uart_puts(" cycles=");
    put_dec64(lcvex_coremark_last_ticks);
    lcvex_uart_puts(" score=INVALID\r\n");
}

void lcvex_run_coremark_full(void)
{
    lcvex_u32 reason = 0;
    lcvex_u64 cycles;
    lcvex_u64 iterations;
    lcvex_u64 cms_x1000 = 0;
    lcvex_u64 cmmhz_x1000 = 0;

    lcvex_uart_puts("CMSTART C\r\n");
    configure_coremark(0U, 0U);
    (void)coremark_main();
    cycles = lcvex_coremark_last_ticks;
    iterations = lcvex_coremark_reported_iterations;

    if (!coremark_common_valid())
        reason |= 1U;
    if (cycles < LCVEX_COREMARK_MIN_CYCLES ||
        lcvex_coremark_duration_error != 0U)
        reason |= 2U;
    if (lcvex_coremark_validated == 0U || iterations == 0U || cycles == 0UL)
        reason |= 4U;

    if (reason == 0U) {
        cms_x1000 = ratio_x1000(iterations * LCVEX_CLOCK_HZ, cycles);
        cmmhz_x1000 = ratio_x1000(iterations * 1000000UL, cycles);
        lcvex_uart_puts("CMRESULT VALID");
    } else {
        lcvex_uart_puts("CMRESULT INVALID reason=");
        put_hex32(reason);
    }
    put_coremark_crc_fields();
    lcvex_uart_puts(" iterations=");
    put_dec64(iterations);
    lcvex_uart_puts(" cycles=");
    put_dec64(cycles);
    lcvex_uart_puts(" hz=25000000 cms_x1000=");
    put_dec64(cms_x1000);
    lcvex_uart_puts(" cmmhz_x1000=");
    put_dec64(cmmhz_x1000);
    lcvex_uart_puts("\r\n");
}
