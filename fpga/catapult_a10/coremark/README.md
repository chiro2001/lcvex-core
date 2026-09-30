# LCVEX B25 CoreMark 移植

`upstream/` 下的文件逐字节来自 EEMBC CoreMark `v1.01` tag、commit
`cfa9ab377835911f23d9b0831c7be302ed1f58de`。文件 hash 固定在
`upstream-manifest.json`；不得直接修改上游文件。`upstream/LICENSE.md` 是完整的
CoreMark Acceptable Use Agreement，使用或报告 benchmark 时必须遵守。

LCVEX 专用移植均位于 `upstream/` 之外：

- `core_portme.h`：LP64、单 context、静态内存、无 libc/FP 的 port 定义；
- `core_portme.c`：从 `0x09003040` 读取只读 25 MHz 平台 cycle counter；
- `ee_printf.c`：提供最小 UART formatter，并在不修改上游算法的前提下采集
  seed、CRC、iteration 和有效性字段；
- `lcvex_bench.c`：实现 monitor 的 `t`、`v`、`c` 命令。

## 命令和结果合同

- `t`：执行 24 项 correctness microbench，成功输出
  `MBPASS 24 8679CF21`；失败只输出首个 `MBFAIL id got expected`。
- `v`：以 2 KiB performance seed 运行一次 CoreMark，核对官方 list/matrix/state
  CRC，输出 `CMSELF PASS ... score=INVALID`。它只证明正确性，绝不是分数。
- `c`：由上游自动标定 iteration；正式区间必须不少于 250,000,000 个目标 cycle
  （25 MHz 下 10 秒），并同时满足官方 seed/CRC 与上游 validation，才输出
  `CMRESULT VALID`。

`CMRESULT` 使用整数定点字段 `cms_x1000` 和 `cmmhz_x1000`。host parser 从
`iterations/cycles/hz` 重新计算这两个值，并把 compact record 与上游原始的 size、
ticks、seconds、iterations、seed/CRC、编译器 flags、BRAM location 和 validation
成功行逐项交叉核对；不能只相信固件打印的 `VALID` 字样。

Windows `nios2-terminal` 的 120 列 ConHost 在 compact `CMRESULT` 恰好占满右边界时，
可能以 CSI 光标定位重新绘制末字符，再继续输出 `hz=...`。strict parser 仅在定位列、
重复字符和 `cycles` 字段边界全部精确吻合时折叠这一显示伪影；其他 ANSI、缺字段或
不匹配内容仍然拒绝，不改写原始 transcript，也不放宽上游字段/分数交叉核验。

correctness suite 的 ID 覆盖如下：

| ID | 覆盖 |
| --- | --- |
| 1–3 | 64 位加减、32 位回绕与零扩展 |
| 4–6 | AND/OR/XOR |
| 7–10 | 左移、逻辑/算术右移、旋转 |
| 11–14 | 有符号/无符号条件、分支和循环 |
| 15–17 | 直接/间接函数控制流与栈读写 |
| 18–22 | 32/64 位乘法、UMULH、有符号/无符号除法 |
| 23–24 | 8/16/32/64 位 Load/Store、符号/零扩展 |

## 构建与审计

正常构建完全离线：

```sh
make b25-microbench-test
```

该入口检查固定上游 hash/许可证、两次 clean artifact 一致性、ELF/BSS/栈范围、
BIN/HEX/MIF 等价、目标反汇编指令覆盖、host correctness oracle、parser 正负例及
build manifest。GCC 16 对未修改的 `core_list_join.c` 有一个已知
`maybe-uninitialized` 误报，因此只按名称关闭该告警；其余告警仍按错误处理，准确
flags 记录在生成的 `microbench-build-manifest.json`。

保存真板 transcript 后使用：

```sh
python3 fpga/catapult_a10/tools/parse_microbench.py --mode full --input transcript.log
```

更新 CoreMark 版本必须另开任务，重新核对官方 tag、许可证和全部上游文件 hash。
