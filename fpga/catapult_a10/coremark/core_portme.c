#include "coremark.h"

#define LCVEX_CYCLE_COUNTER_ADDR 0x09003040UL
#define LCVEX_CLOCK_HZ 25000000UL

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 0;
volatile ee_s32 seed5_volatile = 0;

volatile CORE_TICKS lcvex_coremark_last_ticks;
ee_u32 default_num_contexts = 1;

static CORETIMETYPE start_time_val;
static CORETIMETYPE stop_time_val;

static CORETIMETYPE lcvex_cycle_count(void)
{
    return *(volatile unsigned long *)LCVEX_CYCLE_COUNTER_ADDR;
}

void start_time(void)
{
    start_time_val = lcvex_cycle_count();
}

void stop_time(void)
{
    stop_time_val = lcvex_cycle_count();
}

CORE_TICKS get_time(void)
{
    lcvex_coremark_last_ticks = stop_time_val - start_time_val;
    return lcvex_coremark_last_ticks;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / LCVEX_CLOCK_HZ);
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(void *) || sizeof(ee_u32) != 4) {
        ee_printf("ERROR! LCVEX CoreMark port datatype mismatch\n");
    }
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

void *portable_malloc(ee_size_t size)
{
    (void)size;
    return (void *)0;
}

void portable_free(void *p)
{
    (void)p;
}
