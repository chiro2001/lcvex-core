#ifndef LCVEX_CORE_PORTME_H
#define LCVEX_CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define CORE_DEBUG 0
#define PERFORMANCE_RUN 1
#define VALIDATION_RUN 0
#define PROFILE_RUN 0
#define ITERATIONS 0

#define COMPILER_VERSION "aarch64-linux-gnu-gcc " __VERSION__
#define COMPILER_FLAGS "-std=c11 -O2 -march=armv8.2-a -mgeneral-regs-only -mstrict-align " \
                       "-ffreestanding -fno-builtin -fno-pie -fno-stack-protector " \
                       "-fno-unwind-tables -fno-asynchronous-unwind-tables " \
                       "-fno-tree-loop-distribute-patterns"
#define MEM_LOCATION "64KiB M20K BRAM"

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned int ee_u32;
typedef unsigned char ee_u8;
typedef signed int ee_f32;
typedef unsigned long ee_ptr_int;
typedef unsigned long ee_size_t;

#define align_mem(x) (void *)(4UL + ((((ee_ptr_int)(x)) - 1UL) & ~3UL))

typedef unsigned long CORETIMETYPE;
typedef unsigned long CORE_TICKS;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

extern ee_u32 default_num_contexts;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);

extern volatile ee_s32 seed1_volatile;
extern volatile ee_s32 seed2_volatile;
extern volatile ee_s32 seed3_volatile;
extern volatile ee_s32 seed4_volatile;
extern volatile ee_s32 seed5_volatile;

extern volatile CORE_TICKS lcvex_coremark_last_ticks;
extern volatile ee_u32 lcvex_coremark_reported_iterations;
extern volatile ee_u16 lcvex_coremark_seedcrc;
extern volatile ee_u16 lcvex_coremark_crclist;
extern volatile ee_u16 lcvex_coremark_crcmatrix;
extern volatile ee_u16 lcvex_coremark_crcstate;
extern volatile ee_u16 lcvex_coremark_crcfinal;
extern volatile ee_u32 lcvex_coremark_crc_errors;
extern volatile ee_u32 lcvex_coremark_duration_error;
extern volatile ee_u32 lcvex_coremark_validated;
extern volatile ee_u32 lcvex_coremark_quiet;

void lcvex_coremark_reset_observation(void);

#endif
