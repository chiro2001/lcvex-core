# T-20260901-011：F1a full-matrix handoff

```text
task=T-20260901-011
label=PE-F1J-FULL-MATRIX
state=review
base=f0edcd2528c01520eb4e4922266a7913c5c7539b
head=见最终交付 commit（evidence 不自引用）
measurement_source=f0edcd2528c01520eb4e4922266a7913c5c7539b
branch=verify/T-20260901-011-f1a-full-matrix
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-011
owner=luna-f1a-full-matrix
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-09-01T16:32:45+08:00
received_at=2026-09-01T16:32:45+08:00
reported_at=2026-09-01T20:14:46+08:00
tests=196-row/98-pair 10M matrix；196/196 pass；98/98 strict；98/98 cycle guard；FIFO/provenance/JSON/CSV audit pass
blockers=无；F1a 默认启用决策待集成者复核
next=集成者复核完整矩阵并进入 F1a 默认启用决策；本任务不运行 Gate D/Linux/QEMU/Quartus
```

## 结果摘要

在冻结 source SHA 的 own worktree 中，从空的本任务 build 目录按 canonical 顺序重建
14 个 workload image 和 14 个 F0/F1a runner，完成 196 rows、98 unique pairs。所有
row `status=pass`、returncode=0，commit digest schema 统一为
`lcvex-commit-digest-v2-active-payload`。98/98 pairs 的 status、returncode、retired、
commit digest、memory digest 和 committed memory effects 严格相等；所有 F1a FIFO
bounds 合法；98/98 `cycles_f1a <= cycles_f0*1.02+64`。

T-004 原先 95/98 的 cycle guard 已提升为 98/98，原失败的三项全部闭合：

```text
nocache_d2/alu_latency  5795747 -> 4904275  (-15.381%) PASS
nocache_d2/ctrl_branch  5172730 -> 4599259  (-11.086%) PASS
nocache_d2/mem_seq      7273882 -> 6664445  (-8.378%) PASS
```

F0 的 98 rows FIFO counters 全零；F1a occupancy/peak 最大值为 `2/2`，overflow
total=`0`，push/pop=`29,886,879/29,886,808`，没有 push<pop row。

## Provenance、资源和 artifact

196 rows 的 `sha`、`git_sha`、`measurement_source_sha` 均为
`f0edcd2528c01520eb4e4922266a7913c5c7539b`。每个 pair 使用相同 image/source/tool/
max_cycles 和除 FIFO 外参数；未访问或复用 T-004/T-009/T-010 runner、image 或结果。

唯一重型 scope：`run-p1986779-i35557415.scope`，16:35:58–20:01:28（Asia/Shanghai），
wall `12329.890s`、CPU `6164.976s`、MemoryPeak `5.6G`；限制为
`MemoryMax=15G`、`MemorySwapMax=0`、`CPUQuota=50%`、`MAKEFLAGS=-j1`、
`VERILATOR_JOBS=1`。工具版本为 Verilator `5.050 2026-07-01 rev conda-forge build 0`、
`aarch64-linux-gnu-gcc 16.1.0`、Python `3.12.10`。

权威 artifact：

- [`f1j_full_matrix.json`](../evidence/artifacts/T-20260901-011/f1j_full_matrix.json)，
  1,355,694 bytes，SHA256 `018dc721307ed286136e0f1365efff13ea8fc3a3ed94fb53b0b2b4f65b436d88`；
- [`f1j_full_matrix.csv`](../evidence/artifacts/T-20260901-011/f1j_full_matrix.csv)，
  80,723 bytes，SHA256 `796bbd4345bce19f411af65a992d5aa3cc69b9791ab2f0524d195b700e116b13`。

完整 per-row report、runner、image、manifest、日志和 raw copy 留在
`build/agents/T-20260901-011/`；详细 hash、98 对数据、失败列表和复现命令见
[`docs/tasks/evidence/T-20260901-011.json`](../tasks/evidence/T-20260901-011.json)。

本任务不运行 Gate D、Linux、QEMU lockstep、Quartus/FPGA 或板测；Verilator cycle
guard 不是 A10/Fmax 证据。
