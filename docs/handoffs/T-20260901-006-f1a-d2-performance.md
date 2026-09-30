# T-20260901-006：F1a `nocache_d2` 性能回退只读诊断 handoff

```text
task=T-20260901-006
label=PE-F1G-D2-PERF-AUDIT
state=review
base=aa60cfec24ca880841257ccc80e96f8138caf023
measurement_source=3816c95a92692e336b2c2063d9d7ef7f998d6b0f
report_tip=见最终报告（承载文档的 Git tip 不在 evidence 自引用）
branch=review/T-20260901-006-f1a-d2-performance
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-006
owner=luna-f1a-d2-performance-audit
model=gpt-5.6-luna
reasoning_effort=max
sent_at=2026-09-01T07:14:38+08:00
received_at=2026-09-01T07:14:38+08:00
reported_at=2026-09-01T07:21:34+08:00
files=docs/F1A_D2_PERFORMANCE_REGRESSION_DIAGNOSIS.md;
      docs/handoffs/T-20260901-006-f1a-d2-performance.md;
      docs/tasks/evidence/T-20260901-006.json
tests=只读 JSON/CSV hash/schema/pair audit；三项完整 counter delta；同 workload d0/d1/d2；nocache_d2 全 workload 横向审阅
non_actions=no Verilator/QEMU/Quartus/Gate/Linux；no RTL/runner/workload/comparator/threshold/reference changes
blockers=cycle guard 95/98；仅 nocache_d2/alu_latency、ctrl_branch、mem_seq 失败；F1a 默认启用继续阻塞
next=后继任务只跑上述 3 workload 的 F0/F1a 共 6 rows，增加有界 per-cycle probe 后再登记修复
```

## 结果摘要

T-004 v2 artifact 为 196 rows/98 pairs，196/196 `pass`、98/98 strict 架构等价，
cycle guard 为 95/98。三个失败 pair 原样为：

```text
nocache_d2/alu_latency  5795747 -> 6219933  (+7.319%)
nocache_d2/ctrl_branch  5172730 -> 5749229  (+11.145%)
nocache_d2/mem_seq      7273882 -> 7456315  (+2.508%)
```

独立 counter delta 的共同点是 F1a 新增 imem 重取以及 arb/L2/delay/RAM 路由请求，
而 dmem、PTW、nocache cache event 没有新增；三项均出现合法的 epoch bump/flush、
stale drop/drain，FIFO occupancy/peak≤2、overflow=0、push≥pop。`alu_latency` 和
`ctrl_branch` 的 d2 `stall_if`/`fetch_wait` 同向大幅增加；`mem_seq` 的
`fetch_wait`、`mem_stall` 下降，不能未经动态 trace 宣称三项完全同源。

最合理的后继工作假设是 F1a FIFO stale quarantine 与 mode-2 单 outstanding 延迟
的 backpressure/管线相位交互。证据仍是“aggregate counters + 静态审阅的相关性”，
不是因果证明。

## 交付和证据

- 诊断报告：[`docs/F1A_D2_PERFORMANCE_REGRESSION_DIAGNOSIS.md`](../F1A_D2_PERFORMANCE_REGRESSION_DIAGNOSIS.md)。
- 机器可读证据：[`docs/tasks/evidence/T-20260901-006.json`](../tasks/evidence/T-20260901-006.json)。
- T-004 JSON SHA256：`7a166c9e2104dc0c060ee2f3aaa9d2cc09fecc8ac757b8ff69f84948c0937e2a`。
- T-004 CSV SHA256：`f71d0b4e05758d389101cce689cdd97c4e6adde316ff57f6248670a9064d74af`。

T-004 artifact 已在本 worktree 只读解析：JSON/CSV 各 196 行且 pair key 一致，
schema 196/196，strict 98/98；三项目标 pair 的 measurement source、source hash、
image hash 均成对一致。全部 delta 与 14 项 `nocache_d2` 横向数据已写入报告和
evidence，F0/F1a 的 target nested counters 没有省略。

## 后继 probe 边界

后继动态任务只允许改动 probe 观测层：`tb/sv/lcvex_soc_tb.sv` 暴露 delay block
只读握手/状态，`sim/microbench/microbench_runner.cc` 增加有界事件输出和早停；可
复用 `perf_runner.py --trace`，不改 RTL 功能、workload、比较器或阈值。需要采集
commit packet、stall、fetch/FIFO、epoch/stale、imem/dmem/arb/L2/delay/RAM 握手、
以及 delay `req_pending/rsp_pending/delay_cnt/LFSR`。首条 commit 字段差异、FIFO
overflow 或 occupancy>2、单 outstanding 违规、timeout/error 或资源超限时立即停止
并保存最近现场。

规划资源是独立 sibling worktree、两个 runner 变体串行重建、六行串行运行，CPU 1、
内存 2 GiB、构建和有界事件 artifact 约 512 MiB，预计 wall≤30 min；不得复用
T-004 的 build/trace/失败现场。当前任务未运行任何动态工具。
