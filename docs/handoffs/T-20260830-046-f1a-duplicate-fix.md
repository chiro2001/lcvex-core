# T-046 PE-F1A-FIX handoff

```text
task=T-20260830-046 state=review
base=c7081f4ba790ba9bf81d48d7acbc083828529055
head=c86329e46da5d2adec261ec4c235a214866b1075
content_sha=c86329e46da5d2adec261ec4c235a214866b1075
branch=feature/T-20260830-046-f1a-duplicate-fix
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-046
owner=luna-f1a-duplicate-fix
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-08-30T23:03:19+08:00 received_at=2026-08-30T23:04:06+08:00 reported_at=2026-08-31T02:15:20+08:00
files=rtl/lcvex_core.sv; tb/sv/lcvex_fetch_fifo_tb.sv; sim/cocotb/test_fetch_fifo.py;
      sim/difftest/test_program.py; sim/difftest/run_f1a.sh;
      docs/F1A_DUPLICATE_RETIREMENT_FIX.md; docs/handoffs/T-20260830-046-f1a-duplicate-fix.md;
      docs/tasks/evidence/T-20260830-046.json
tests=metadata-only correction; no build/sim/QEMU/generator rerun
resources=post-fix wait services MemoryMax=15G CPUQuota=50% MemorySwapMax=default infinity; historical scopes MemoryMax=15G MemorySwapMax=0 CPUQuota=unspecified; direct replays unbounded/unknown
blockers=none
next=integrator verifies correction metadata and reruns only if separately scheduled; final correction tip is reported outside self-referential evidence
```

## 实现摘要

T-044 的 `mem_seq` first-trace 已证明 F1a 是真实 duplicate retirement。T-046 逐拍
token probe 进一步证明 FIFO head 和 IFID→IDEX→EXMEM→MEMWB 均只转移一次；坏点是
younger dmem stall 下 MEM/WB `memwb_committed_r` 漏记 `dmem_pending`。修复将该条件
限定在 FIFO-on 路径，并加入 commit/流水 token SVA。

新增最小 `hard_fetch_duplicate` 镜像覆盖 `ldr; ALU; ldr`；SV、Cocotb 和 F1a
strict-lockstep 入口均纳入该场景。公共 commit packet、内存协议和 feature-off 路径
未改动。

## 验证摘要

- Verilator 5.050、`--assert` F1a dedicated SV smoke：通过，3 commits。
- post-fix 1000-cycle token probe：通过；触发窗口 commit 后 marker 保持，下一拍无
  duplicate commit。
- F1a Cocotb：通过；occupancy 范围、token 唯一/transfer 一次、dmem hold、reset
  清理均通过。
- feature-off `sim-sv-backpressure`：通过；普通和 system MSR backpressure 均通过。
- post-fix f0/f1a microbench runner、T-044 workloads 和 F1a base/cache/delay2 矩阵
  的精确结果、命令、日志/hash 见 evidence，不在 handoff 重复复制。

## 边界与风险

写集严格限于上述文件；没有修改 Makefile、perf runner/comparator、pkg、I-L1、MMU、
arbiter、SoC TB、baremetal 或 QEMU。未宣称修复 H-03/H-04/F1b；FIFO fault-head 和
更广的多 outstanding memory 协议仍是独立边界。

## Evidence

详见 [`docs/tasks/evidence/T-20260830-046.json`](../tasks/evidence/T-20260830-046.json)。

## Metadata correction

本 follow-up 只修正 metadata/resource provenance，未重跑任何测试。初始派发来自 active
task JSON：`sent_at=2026-08-30T23:03:19+08:00`，owner 为
`luna-f1a-duplicate-fix`，模型为 `gpt-5.6-luna(max)`。本 agent harness 的
`task_started` 接收事件为 `2026-08-30T23:04:06+08:00`，首条确认消息在
`23:04:14+08:00`；旧的 `23:40` 不是本任务接收时间。

旧值（owner=`codex-f1a-duplicate-fix`、model=`gpt-5`、sent/received=`23:40`、
reported=`2026-08-31T01:47`）保留为 correction 事实，不再作为权威 metadata。
`head/content_sha` 保持首次交付技术内容提交 `c86329e`；本次 correction commit
会改变 branch tip，最终 SHA 由 FINAL 报告给出，避免 evidence 自引用。

资源口径以 evidence 的 `resources` 与各 `tests[*].resource_wrapper` 为准：实际 post-fix
`--wait` 服务使用 `MemoryMax=15G`、`CPUQuota=50%`，但命令没有设置
`MemorySwapMax`，因此不能声称无 swap；历史 `--scope` 命令明确设置了
`MemorySwapMax=0`，但 scope/invocation 未被现有日志保留；直接 binary replay/lint
命令没有 wrapper，标为 unbounded/unknown。

可核验的 post-fix service 包括：f0 runner
`run-p2144803-i27305779.service/e188350026514d14a790f395fa038f64`、f1a runner
`run-p2181755-i27361559.service/2affbf70acc145c49d0c7475ce050fbc`、F1a 三个
coordinator `run-p2246501-i27393558.service/e29fb2543a9f494ba092dfe47681c3d0`、
`run-p2294024-i27472715.service/c62403cbeccd493baf1c73c734b97a10`、
`run-p2336582-i27513326.service/5437470b78564d45a8553f7eee40dcef`，以及矩阵
`run-p2372032-i27524021.service/5e33676aa3b346fab7eb2753853ffc1e`；完整覆盖和
观察峰值见 evidence，未把缺失限制写成实际限制。

本次 follow-up dispatch 为 `2026-08-31T01:49:49+08:00`；本报告时间为
`2026-08-31T02:15:20+08:00`。correction commit SHA 不写入自身可变 evidence，见
最终 FINAL 回报。
