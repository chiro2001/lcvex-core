#include <stdarg.h>

#include "coremark.h"

extern void lcvex_uart_putc(unsigned int ch);

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

static int text_equal(const char *a, const char *b)
{
    while (*a != 0 && *b != 0 && *a == *b) {
        ++a;
        ++b;
    }
    return *a == *b;
}

static int text_prefix(const char *text, const char *prefix)
{
    while (*prefix != 0) {
        if (*text++ != *prefix++) {
            return 0;
        }
    }
    return 1;
}

static int put_char(char ch)
{
    lcvex_uart_putc((unsigned int)(unsigned char)ch);
    return 1;
}

static int put_unsigned(unsigned long value, unsigned int base,
                        unsigned int width, char pad, int upper)
{
    char digits[32];
    unsigned int count = 0;
    int written = 0;
    const char *alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do {
        digits[count++] = alphabet[value % base];
        value /= base;
    } while (value != 0 && count < sizeof(digits));
    while (count < width) {
        written += put_char(pad);
        --width;
    }
    while (count != 0) {
        written += put_char(digits[--count]);
    }
    return written;
}

static void observe_format(const char *fmt, va_list args)
{
    if (text_equal(fmt, "Iterations       : %lu\n")) {
        lcvex_coremark_reported_iterations = (ee_u32)va_arg(args, unsigned long);
    } else if (text_equal(fmt, "seedcrc          : 0x%04x\n")) {
        lcvex_coremark_seedcrc = (ee_u16)va_arg(args, unsigned int);
    } else if (text_equal(fmt, "[%d]crclist       : 0x%04x\n")) {
        (void)va_arg(args, int);
        lcvex_coremark_crclist = (ee_u16)va_arg(args, unsigned int);
    } else if (text_equal(fmt, "[%d]crcmatrix     : 0x%04x\n")) {
        (void)va_arg(args, int);
        lcvex_coremark_crcmatrix = (ee_u16)va_arg(args, unsigned int);
    } else if (text_equal(fmt, "[%d]crcstate      : 0x%04x\n")) {
        (void)va_arg(args, int);
        lcvex_coremark_crcstate = (ee_u16)va_arg(args, unsigned int);
    } else if (text_equal(fmt, "[%d]crcfinal      : 0x%04x\n")) {
        (void)va_arg(args, int);
        lcvex_coremark_crcfinal = (ee_u16)va_arg(args, unsigned int);
    }

    if (text_equal(fmt, "ERROR! Must execute for at least 10 secs for a valid result!\n")) {
        lcvex_coremark_duration_error = 1;
    } else if (text_prefix(fmt, "ERROR!") || text_prefix(fmt, "[%u]ERROR!")) {
        lcvex_coremark_crc_errors++;
    }
    if (text_equal(fmt, "Correct operation validated. See readme.txt for run and reporting rules.\n")) {
        lcvex_coremark_validated = 1;
    }
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

int ee_printf(const char *fmt, ...)
{
    va_list args;
    va_list observe;
    int written = 0;

    va_start(args, fmt);
    va_copy(observe, args);
    observe_format(fmt, observe);
    va_end(observe);

    // The short `v` command executes the unmodified algorithms and captures
    // every validation field, but suppresses the verbose upstream report so
    // Verilator and JTAG-UART receive one bounded machine-readable summary.
    if (lcvex_coremark_quiet != 0) {
        va_end(args);
        return 0;
    }

    while (*fmt != 0) {
        unsigned int width = 0;
        char pad = ' ';
        int long_value = 0;
        if (*fmt != '%') {
            if (*fmt == '\n')
                written += put_char('\r');
            written += put_char(*fmt++);
            continue;
        }
        ++fmt;
        if (*fmt == '%') {
            written += put_char(*fmt++);
            continue;
        }
        if (*fmt == '0') {
            pad = '0';
            ++fmt;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10U + (unsigned int)(*fmt++ - '0');
        }
        if (*fmt == 'l') {
            long_value = 1;
            ++fmt;
        }
        switch (*fmt++) {
        case 'c':
            written += put_char((char)va_arg(args, int));
            break;
        case 's': {
            const char *text = va_arg(args, const char *);
            if (text == (const char *)0) {
                text = "(null)";
            }
            while (*text != 0) {
                written += put_char(*text++);
            }
            break;
        }
        case 'd': {
            long value = long_value ? va_arg(args, long) : (long)va_arg(args, int);
            unsigned long magnitude;
            if (value < 0) {
                written += put_char('-');
                magnitude = (unsigned long)(-(value + 1)) + 1UL;
            } else {
                magnitude = (unsigned long)value;
            }
            written += put_unsigned(magnitude, 10, width, pad, 0);
            break;
        }
        case 'u': {
            unsigned long value = long_value ? va_arg(args, unsigned long)
                                             : (unsigned long)va_arg(args, unsigned int);
            written += put_unsigned(value, 10, width, pad, 0);
            break;
        }
        case 'x':
        case 'X': {
            int upper = fmt[-1] == 'X';
            unsigned long value = long_value ? va_arg(args, unsigned long)
                                             : (unsigned long)va_arg(args, unsigned int);
            written += put_unsigned(value, 16, width, pad, upper);
            break;
        }
        default:
            written += put_char('?');
            break;
        }
    }
    va_end(args);
    return written;
}
