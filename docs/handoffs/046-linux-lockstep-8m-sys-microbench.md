# LCVEX 交接文档 046：Linux 8M 锁步与系统指令 microbench

日期：2026-08-24（Asia/Shanghai）

## 本轮结果

- 使用 `MAX_INSNS=8000000`、QEMU `-icount shift=0`、单物理核绑定完成
  Linux 内核锁步。
- `seq=0..7,999,999` 共 8,000,000 条提交与 QEMU 完全一致，正常达到
  max-insns；未产生差分失败 dump。
- 协调器约 138MB RSS，QEMU 约 139–140MB RSS；`/tmp` 使用率约 43%。

## 新增 microbench

新增 `baremetal/tests/t_sys.c` 并纳入 `microbench_main.c`：

- `MRS/MSR DAIF` 与 `DAIFSet/DAIFClr` 位域 `[9:6]`；
- `AT S1E1R` 与 `MRS PAR_EL1`（MMU 关闭直接映射）；
- `STLR/LDAR` 的 byte/halfword/word 宽度访存。

验证命令及结果：

```text
make microbench
PASS: mb_all (2508 cycles)
MB_ONLY=sys ...
PASS: sys (224 cycles)
```

## 当前状态与后续

P6 已稳定通过 8M 指令窗口，但仍未达到 Gate E：PSCI、用户空间启动、
更完整 EL1 系统寄存器和 Linux 长时间运行尚未完成。下一步继续从更长
内核负载或用户空间入口定位缺口，并保持每个新增指令同时加入 microbench
与 QEMU 锁步覆盖。差分 checkpoint 目前仍按 044 保持全量基线方案，尚未
实现增量 RAM 格式。
