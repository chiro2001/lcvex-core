// LCVEX 最小裸机 C：无 libc、无启动文件。
// 覆盖编译器常用指令形式：逻辑位掩码立即数、UBFM/SBFM（LSR/LSL/ASR
// 立即数）、移位寄存器逻辑、MOV wide、unsigned-immediate LDR/STR。

volatile unsigned long g_counter;
volatile unsigned long g_arr[16];
typedef struct { unsigned long a, b; } pair_t;

__attribute__((noinline)) static unsigned long idx_sum(unsigned long n)
{
    unsigned long s = 0, i;
    for (i = 0; i < n; i++) {
        s += g_arr[i];   /* ldr [xn, xm, lsl 3]：寄存器偏移寻址 */
    }
    return s;
}

__attribute__((noinline)) static unsigned long madd(unsigned long a,
                                                    unsigned long b,
                                                    unsigned long c)
{
    return a * b + c;   /* MADD */
}

__attribute__((noinline)) static unsigned long mul32(unsigned int a,
                                                     unsigned int b)
{
    return (unsigned long)a * (unsigned long)b;   /* UMULL */
}

__attribute__((noinline)) static unsigned long csel_fn(unsigned long a,
                                                       unsigned long b,
                                                       unsigned long c)
{
    return (a > b) ? c : a;   /* CMP + CSEL */
}

__attribute__((noinline)) static unsigned long pair_sum(pair_t *p)
{
    /* LDP：一次读两个字段 */
    return p->a + p->b;
}

__attribute__((noinline)) static void pair_set(pair_t *p,
                                               unsigned long a,
                                               unsigned long b)
{
    /* STP：一次写两个字段 */
    p->a = a;
    p->b = b;
}

static void delay(unsigned long n)
{
    while (n--) {
        g_counter += n;
    }
}

unsigned long compute(unsigned long a, unsigned long b)
{
    unsigned long x = a + b * 3;
    unsigned long y = (a << 4) | (b >> 2);
    unsigned long z = (a > b) ? x : y;
    unsigned long w = (a & 0xF0F0F0F0UL) ^ (b | 0x0F0F0F0FUL);
    return z ^ w;
}

int main(void)
{
    volatile unsigned long r;
    unsigned long i;
    pair_t p = { 0, 0 };

    delay(4);   /* 锁步窗口内尽快进入结构体/数组代码 */
    for (i = 0; i < 8; i++) {
        g_arr[i] = i * 3;
    }
    r = idx_sum(8);
    /* volatile 读取防止常数折叠，确保真实发出 MADD / UMULL 指令 */
    r += madd(g_arr[0], g_arr[1], g_arr[2]);
    r += mul32((unsigned int)g_arr[3], (unsigned int)g_arr[4]);
    r += csel_fn(g_arr[5], g_arr[6], g_arr[7]);
    pair_set(&p, 0x1122, 0x3344);
    r = pair_sum(&p);
    r = compute(0x1234, 0x5678);
    g_counter = r;
    for (;;) {
        g_counter++;
    }
}
