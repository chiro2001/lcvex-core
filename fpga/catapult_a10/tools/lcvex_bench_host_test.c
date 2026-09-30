#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "core_portme.h"

static char output[4096];
static size_t output_size;

volatile ee_s32 seed1_volatile;
volatile ee_s32 seed2_volatile;
volatile ee_s32 seed3_volatile;
volatile ee_s32 seed4_volatile;
volatile ee_s32 seed5_volatile;
volatile CORE_TICKS lcvex_coremark_last_ticks;
volatile ee_u32 lcvex_coremark_reported_iterations;
volatile ee_u16 lcvex_coremark_seedcrc;
volatile ee_u16 lcvex_coremark_crclist;
volatile ee_u16 lcvex_coremark_crcmatrix;
volatile ee_u16 lcvex_coremark_crcstate;
volatile ee_u16 lcvex_coremark_crcfinal;
volatile ee_u32 lcvex_coremark_crc_errors;
volatile ee_u32 lcvex_coremark_duration_error;
volatile ee_u32 lcvex_coremark_validated;
volatile ee_u32 lcvex_coremark_quiet;

void lcvex_uart_putc(unsigned int ch)
{
    if (output_size + 1 < sizeof(output))
        output[output_size++] = (char)ch;
}

void lcvex_uart_puts(const char *text)
{
    while (*text != '\0')
        lcvex_uart_putc((unsigned int)(unsigned char)*text++);
}

void lcvex_coremark_reset_observation(void)
{
    lcvex_coremark_last_ticks = 0;
    lcvex_coremark_reported_iterations = 0;
    lcvex_coremark_seedcrc = 0;
    lcvex_coremark_crclist = 0;
    lcvex_coremark_crcmatrix = 0;
    lcvex_coremark_crcstate = 0;
    lcvex_coremark_crcfinal = 0;
    lcvex_coremark_crc_errors = 0;
    lcvex_coremark_duration_error = 0;
    lcvex_coremark_validated = 0;
}

int coremark_main(void)
{
    lcvex_coremark_seedcrc = 0xe9f5;
    lcvex_coremark_crclist = 0xe714;
    lcvex_coremark_crcmatrix = 0x1fd7;
    lcvex_coremark_crcstate = 0x8e3a;
    lcvex_coremark_crcfinal = 0x65c5;
    if (seed4_volatile == 1) {
        lcvex_coremark_reported_iterations = 1;
        lcvex_coremark_last_ticks = 12345;
        lcvex_coremark_duration_error = 1;
    } else {
        lcvex_coremark_reported_iterations = 1001;
        lcvex_coremark_last_ticks = 250000001;
        lcvex_coremark_validated = 1;
    }
    return 0;
}

extern void lcvex_run_correctness(void);
extern void lcvex_run_coremark_short(void);
extern void lcvex_run_coremark_full(void);

static int expect_output(const char *label, const char *expected)
{
    output[output_size] = '\0';
    if (strcmp(output, expected) != 0) {
        fprintf(stderr, "LCVEX_BENCH_HOST_FAIL mode=%s got=%s", label, output);
        return 1;
    }
    output_size = 0;
    return 0;
}

int main(void)
{
    static const char correctness[] = "MBPASS 24 8679CF21\r\n";
    static const char selfcheck[] =
        "CMSTART V\r\n"
        "CMSELF PASS seed=0000E9F5 list=0000E714 matrix=00001FD7 "
        "state=00008E3A final=000065C5 iterations=1 cycles=12345 "
        "score=INVALID\r\n";
    static const char full[] =
        "CMSTART C\r\n"
        "CMRESULT VALID seed=0000E9F5 list=0000E714 matrix=00001FD7 "
        "state=00008E3A final=000065C5 iterations=1001 cycles=250000001 "
        "hz=25000000 cms_x1000=100099 cmmhz_x1000=4003\r\n";

    lcvex_run_correctness();
    if (expect_output("correctness", correctness) != 0)
        return 1;
    lcvex_run_coremark_short();
    if (expect_output("selfcheck", selfcheck) != 0)
        return 1;
    lcvex_run_coremark_full();
    if (expect_output("full", full) != 0)
        return 1;
    printf("LCVEX_BENCH_HOST_PASS correctness=8679CF21 selfcheck=PASS full_math=PASS\n");
    return 0;
}
