// LCVEX microbench 断言与测试声明。
//
// 每个测试文件：static unsigned long fails; 用 CHECK 累计失败，
// 导出 int run_test_<name>(void) 返回 fails（0 = 通过）。

#ifndef LCVEX_TESTS_H
#define LCVEX_TESTS_H

#define CHECK(cond) \
    do { if (!(cond)) { fails++; } } while (0)

#define CHECK_EQ(a, b) CHECK((a) == (b))

#define TEST_DECL(name) int run_test_##name(void)

#endif
