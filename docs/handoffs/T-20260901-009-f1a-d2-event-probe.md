# T-20260901-009：F1a `nocache_d2` 有界事件 probe handoff

```text
task=T-20260901-009
label=PE-F1H-D2-EVENT-PROBE
state=review
base=b8a7294204de06b3c00f3abc02e181f6d035ac23
head=b8a7294204de06b3c00f3abc02e181f6d035ac23 (source frozen; owner report tip below)
report_tip=见最终报告（承载文档的 Git tip 不在 evidence 自引用）
branch=verify/T-20260901-009-f1a-d2-event-probe
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-009
owner=luna-f1a-d2-event-probe
model=gpt-5.6-luna
reasoning_effort=max
sent_at=2026-09-01T11:08:01+08:00
received_at=2026-09-01T11:08:01+08:00
reported_at=2026-09-01T12:20:08+08:00
files=rtl/lcvex_mem_delay.sv; tb/sv/lcvex_soc_tb.sv;
      sim/microbench/microbench_runner.cc; sim/microbench/perf_runner.py;
      Makefile; scripts/test_registry.json;
      docs/F1A_D2_EVENT_PROBE_RESULTS.md;
      docs/evidence/artifacts/T-20260901-009/f1a_d2_event_summary.json;
      docs/handoffs/T-20260901-009-f1a-d2-event-probe.md;
      docs/tasks/evidence/T-20260901-009.json
tests=L0 probe selftest/registry；L1 own-worktree 2 runner+3 image+6 rows；L2 event/cycle accounting
non_actions=no cache/fetch/memory functional changes；no workload/threshold/schema/QEMU/reference changes；no full matrix/Gate/Linux/Quartus
blockers=三项 guard 仍失败但架构 digest/commit prefix/FIFO protocol 全闭合；F1a 默认启用继续阻塞
next=登记共享 stale-quarantine/delay2 fetch recovery 修复任务，保留三 workload 定向 guard
```

## 实现摘要

- `lcvex_mem_delay` 新增四个纯组合 read-only probe 输出；mode 0 为零，mode 1/2
  仅镜像既有 pending/delay/LFSR 状态。
- `lcvex_soc_tb` 显式暴露 frontend、FIFO、imem/dmem/PTW、arb/L2、delay、RAM
  握手和 delay 状态；不使用不稳定的 delay C++ 层次名。
- runner 新增 opt-in `--probe`，输出 `lcvex-f1a-d2-event-v1` 紧凑 JSON：完整
  aggregate、8-bin 延迟/饥饿直方图、每类最多 8 条且全局 128 条首事件窗口、
  前 32 条 canonical commit key。顶层 `truncated=false`；commit prefix 的
  固定窗口边界显式记录，完整 digest 未截断。
- `perf_runner.py --probe` 转发可选路径，`--probe-self-test` 覆盖默认关闭、schema
  和 record limit；Makefile/registry 已登记 smoke。

## 结果和因果结论

6/6 rows `pass`，且与 T-004 最终值逐行一致：

```text
alu_latency  5795747 -> 6219933  +7.319%  FAIL
ctrl_branch  5172730 -> 5749229  +11.145% FAIL
mem_seq      7273882 -> 7456315  +2.508%  FAIL
```

每个 F1a pair 都观察到 `frontend_kill -> epoch bump -> stale_drain -> delayed
response drop -> issue unblock -> imem reissue`；`fetch_issue_blocked` 恰好等于
stale drain，raw valid&&!ready 为 0。stale drain 与 delay response pending 交集
为 74.595–76.300%，与 delay request pending 和 data `mem_stall` 交集均为 0。
FIFO occupancy/peak≤2、overflow=0、push=pop；没有功能/架构差异。

因此 `alu_latency`/`ctrl_branch` 共享前端等待放大链，`mem_seq` 共享同一触发链但
具有 data-memory/delay overlap 的吞吐子类；不需要拆成两个触发根因任务。没有
证据证明某一条 RTL 赋值单独错误，修复任务必须保留三项 guard 和架构门槛。

## Evidence、资源和限制

紧凑 artifact：
[`f1a_d2_event_summary.json`](../evidence/artifacts/T-20260901-009/f1a_d2_event_summary.json)。
机器可读任务证据：[`T-20260901-009.json`](../tasks/evidence/T-20260901-009.json)。
完整 run report/probe/stdout/stderr 仅保留在
`build/agents/T-20260901-009/`，不进 Git。

最终运行 scope 为 `run-p1246479-i34801077.scope`，12:02:43–12:10:35 +08:00，
wall 472.285 s、CPU 236.161 s、peak 142M；限制 MemoryMax=15G、SwapMax=0、
CPUQuota=50%、MAKEFLAGS=-j1、VERILATOR_JOBS=1。两个 runner 首次构建 wall
566.744/569.202 s、Verilator 分配 1043.883/1044.695 MB。

限制：commit prefix 只保存首 32 条，完整 digest 覆盖全量；最后 2/5/23 个 kill
窗口在 MAGIC 完成边界前无对应 stale response，作为 unresolved 显式保留；
aggregate predicates 可重叠，事件 union 不等同于 cycle delta；mode2 LFSR
可复现但 F0/F1a 调度可能采样不同 phase。
