# LCVEX 交接文档 048：RBIT 缺口关闭与 Linux 14M 锁步

日期：2026-08-24（Asia/Shanghai）

## 触发与定位

Linux 20M 锁步在 `seq=13,653,333` 首次分歧。运行时指令为
`RBIT X24, X24`（编码 `0xdac00318`），RTL 将其判为 UDEF；QEMU 执行后
`X24=0x8000000000000000`。结构化失败现场保存在
`build/difftest/failures/linux-rbit-seq13653333.txt`（完整协调器日志未保留，
避免生成约 1.1GB 的无索引日志）。

## 实现

- `lcvex_pkg.sv` 新增 `ALU_RBIT`；`lcvex_alu.sv` 实现 W/X 按位反转，W
  形式高 32 位零扩展且不更新 NZCV。
- `lcvex_decode.sv` 接受 Data-processing 1-source 的 `op2=000000`。
- `a64.py`、编码器自检和随机程序生成器加入 `rbit/rbit_w`。
- `hard_p6_isa` 增加 X/W 定向执行；`baremetal/tests/t_sys.c` 增加 X/W
  结果检查；`ISA_SCOPE.md` 将 RBIT 列入 P6 支持矩阵。
- 协调器增加 `--progress-every`，锁步脚本透传 `PROGRESS_EVERY`。默认值
  为 1 保持短测试行为；Linux 长跑可设为 100000，失败诊断仍写入
  `step_fail.txt`，避免进度日志膨胀。

## 验证

```text
make compile                                      PASS
make test                                         PASS（P0 全套，编码器 76 条）
make sim-cocotb                                   PASS（ALU 12/12，含 RBIT W/X）
make microbench                                   PASS: mb_all（2698 cycles）
taskset -c 0 make difftest-random SEED=11 LENGTH=5000
                                                   PASS: 5002 条
bash sim/difftest/run_m2_4b.sh --only hard_p6_isa
                                                   PASS: base/cache 各 75 条
Linux QEMU/RTL 锁步 MAX_INSNS=14,000,000          PASS: seq=0..13,999,999
```

14M 锁步使用 `taskset -c 0`，`PROGRESS_EVERY=100000`；协调器约 138MB RSS，
QEMU 峰值约 153MB RSS，`/tmp` 约 43%，未启用 checkpoint、未产生大文件。

## 当前状态与后续

RBIT 缺口已关闭，Linux 锁步窗口扩大到 14M；P6 仍未达到 Gate E，PSCI、
用户空间入口和长时间稳定运行尚未验收。差分 checkpoint 仍只有全量 gzip
基线；handoff 044 的 QEMU 脏页增量格式和恢复闭环待后续独立阶段实现。
