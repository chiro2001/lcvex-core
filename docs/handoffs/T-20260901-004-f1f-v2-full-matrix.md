# T-20260901-004 F1F v2 full matrix handoff

```text
task=T-20260901-004 state=review
base=3816c95a92692e336b2c2063d9d7ef7f998d6b0f
head=3816c95a92692e336b2c2063d9d7ef7f998d6b0f
measurement_source=3816c95a92692e336b2c2063d9d7ef7f998d6b0f
branch=verify/T-20260901-004-f1f-v2-full-matrix
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-004
owner=luna-f1f-v2-full-matrix
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-09-01T03:04:46+08:00
received_at=2026-09-01T03:04:46+08:00
reported_at=2026-09-01T07:09:16+08:00
files=docs/PERFORMANCE_F1F_V2_RESULTS.md;
      docs/evidence/artifacts/T-20260901-004/f1f_v2_matrix.json;
      docs/evidence/artifacts/T-20260901-004/f1f_v2_matrix.csv;
      docs/handoffs/T-20260901-004-f1f-v2-full-matrix.md;
      docs/tasks/evidence/T-20260901-004.json
tests=指定 196-row/98-pair 10M matrix；row/pair/schema/provenance/FIFO audit
blockers=98/98 strict/FIFO correctness PASS；cycle guard 95/98，仅阻塞 F1a 默认启用和性能签核
next=集成者合并后冻结候选运行用户授权的标准 Gate D，同时另立三个 nocache_d2 性能回退诊断
```

## 结果摘要

本任务在 own worktree 从冻结 source 重建 14 个 runner 和 14 个 workload image，
运行指定命令完成 196 rows。所有 row 均 `pass`、returncode=0、
`commit_digest_schema=lcvex-commit-digest-v2-active-payload`。

98/98 pairs 的 `status`、returncode、retired、schema、v2 commit digest、memory
digest 和 memory effect count 全部严格相等；T-007 原 5 个 neon commit-only 与
10 个 timeout-related pair 全部闭合。F1a FIFO bounds 全绿：occupancy/peak max=2、
overflow=0、push≥pop 全部满足。

性能护栏 `f1a <= f0*1.02+64` 只通过 95/98。失败 pair 为；它们阻塞 F1a 默认启用
和性能签核，但不阻塞已满足的标准 Gate D 正确性前置：

```text
nocache_d2/alu_latency  5795747 -> 6219933  (+7.319%)
nocache_d2/ctrl_branch  5172730 -> 5749229 (+11.145%)
nocache_d2/mem_seq      7273882 -> 7456315  (+2.508%)
```

必须把这 3 项视为性能 acceptance blocker，不能因 strict digest 全部相等而放行。

## Artifact、资源和限制

权威文件为 [`f1f_v2_matrix.json`](../evidence/artifacts/T-20260901-004/f1f_v2_matrix.json)
（SHA256 `7a166c9e2104dc0c060ee2f3aaa9d2cc09fecc8ac757b8ff69f84948c0937e2a`）和
[`f1f_v2_matrix.csv`](../evidence/artifacts/T-20260901-004/f1f_v2_matrix.csv)
（SHA256 `f71d0b4e05758d389101cce689cdd97c4e6adde316ff57f6248670a9064d74af`）。
14 个 runner/image/manifest hash、98 对明细、精确命令和 journal 资源记录见
[`docs/tasks/evidence/T-20260901-004.json`](../tasks/evidence/T-20260901-004.json)。

入口 scope 为 `run-p3356669-i32724486.scope`，wall `3h45min13.598s`、CPU
`1h52min36.709s`、memory peak `6.2G`；限制为 `MemoryMax=15G`、无 swap、CPU 50%、
`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1`。本任务未运行 Gate D、Linux、Quartus/FPGA；
集成者合并后可按用户授权冻结候选运行标准 Gate D。标准 Gate D 默认配置不等于
F1a-on Gate D；F1a-on 正确性证据为本次 98/98 v2 矩阵和既有定向锁步。没有修改
RTL、runner、workload、QEMU、comparator 或参考结果。
