# T-20260901-010：F1a control-flow fetch fence handoff

```text
task=T-20260901-010
label=PE-F1I-CONTROL-FLOW-FETCH-FENCE
state=review (provenance correction)
base=c44a4bce153904631574141a8b0c7d2c71e6ef88
implementation_source_sha=d69f5bd08a6d87452ce96617520e5c4d7fe82ff0
measurement_source_sha=d69f5bd08a6d87452ce96617520e5c4d7fe82ff0
head=见最终报告（provenance delivery commit 不在 evidence 自引用）
report_tip=见最终报告（承载文档的 Git tip 不在 evidence 自引用）
branch=feature/T-20260901-010-f1a-control-flow-fetch-fence
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-010
owner=luna-f1a-control-flow-fetch-fence
model=gpt-5.6-luna
reasoning_effort=max
sent_at=2026-09-01T12:41:40+08:00
provenance_correction_sent_at=2026-09-01T16:05:59+08:00
received_at=2026-09-01T16:05:59+08:00
reported_at=2026-09-01T16:25:47+08:00
files=rtl/lcvex_core.sv; tb/sv/lcvex_fetch_fifo_tb.sv; sim/cocotb/test_fetch_fifo.py;
      tb/sv/lcvex_soc_tb.sv; Makefile; sim/microbench/microbench_runner.cc;
      sim/microbench/perf_runner.py; scripts/test_registry.json;
      docs/F1A_CONTROL_FLOW_FETCH_FENCE_RESULTS.md;
      docs/evidence/artifacts/T-20260901-010/f1a_control_flow_fence_summary.json;
      docs/handoffs/T-20260901-010-f1a-control-flow-fetch-fence.md;
      docs/tasks/evidence/T-20260901-010.json
tests=SV cache-off/cache-on delay2 + T010_IABT negative control；Cocotb 3/3；T-009 v2 probe 6 rows/10M；provenance rerun 6/6；registry/whitespace
reference_probe_schema=lcvex-f1a-d2-event-v1
current_probe_schema=lcvex-f1a-d2-event-v2-stale-context
non_actions=no lcvex_mem_delay/workload/threshold/digest/QEMU/reference changes；no full matrix/Gate/Linux/Quartus
blockers=无；三项 guard 全部通过，但 F1a 默认开关仍待完整矩阵验收
next=集成者在新 SHA 复跑三项及完整 196-row/98-pair matrix；当前 F1a 默认仍关闭
raw_artifact_root=build/agents/T-20260901-010-correction-provenance
excluded_raw_artifact_root=build/agents/T-20260901-010-correction
```

## 实现摘要

`rtl/lcvex_core.sv` 增加纯组合 `raw_control_flow` 和 `fetch_control_fence`。编码
与现有 decoder 对齐：B/BL、B.cond（bit4=0，cond E/F 不排除）、CBZ/CBNZ、
TBZ/TBNZ，以及 BR/BLR/RET（op2 `[24:21]` 仅 0000/0001/0010）。FIFO entry 必须
`valid && !fault && epoch==fetch_epoch`；IF/ID 必须 valid、`d.valid` 且 token epoch
current。reserved BR、reserved B.cond、UDEF/SVC/ERET/maintenance 等不触发 fence。
IF/ID fence qualification 保留 `!d.exc`，branch-target IABT 因此仍可进入 decode/commit。

fence 只门控 `fetch_req_valid` 和 `fetch_imem_req_valid`，不门控 FIFO pop/space、
`stall_if` 或 data MMU；不改 d.next_pc、taken/not-taken、redirect、epoch 或
quarantine，也不引入预测器/BTB/RAS/新状态。新增 SVA 证明 feature-off fence 恒 0
和 fence active 时无普通 fetch accept。

## 验证结果

`make test-f1a`、`make cocotb-f1a`（3/3）和
`make f1a-control-flow-fence-smoke`（cache-off/cache-on、delay2，含 `+T010_IABT`）均
PASS。IABT 负控确认 `d.valid && d.exc && exc_code=0x21` 时 fence=0，commit
PC=`BASE+4`、FAR=`0x5000` 且 epoch 发生既有 flush 变化。Cocotb
新增 B、B.cond taken/not-taken、CBZ/CBNZ、TBZ/TBNZ、BR register target 及
commit_ready hold cases；SV fixture 覆盖 supported/reserved/negative encodings。

T-009 reference tuple 在 `d69f5bd08a6d87452ce96617520e5c4d7fe82ff0` 功能提交对应
代码上复用已构建的两个 runner/三个 image；本轮不重编译，当前 6 行均使用
`lcvex-f1a-d2-event-v2-stale-context`，6/6 pass，且与 T-004 cycles、retired、v2
commit digest、memory digest 严格相同。六行 report 的 `sha/git_sha/measurement_source_sha`
均为 d69 全 SHA；reference schema 仍明确记录为 `lcvex-f1a-d2-event-v1`：

```text
alu_latency  5795747 -> 4904275  (-15.381%) PASS
ctrl_branch  5172730 -> 4599259  (-11.086%) PASS
mem_seq      7273882 -> 6664445  (-8.378%)  PASS
```

F1a 三项 `imem_requests` 与 F0 完全相等，v2 的 `stale_context_drop=0`、
`stale_context_drain_windows=0`、`imem_reissue_after_stale_kill=0`、
`unresolved_stale_context_windows=0`、FIFO overflow=0、push=pop；taken branch 的
正常 `frontend_kill/flush` 保留，但全部为 `kill_without_stale_context`。stale candidate
严格使用 `fetch_pending || fetch_trans_busy || fetch_stale_imem || fetch_stale_mmu`，
排除 `fetch_translated`。guard 上限及余量、完整 stall/request/FIFO/probe 数据见
summary artifact/evidence。

## 资源、边界和风险

本 provenance rerun 使用 MemoryMax=15G、MemorySwapMax=0、CPUQuota=50%、MAKEFLAGS=-j1、
VERILATOR_JOBS=1 的单一 systemd scope：
`run-p1951293-i35479004.scope`，16:08:02–16:15:07 +08:00，wall 425.095 s、
CPU 212.595 s、peak 141.9M。两个 runner 和三个 image 均复用已由 d69 功能提交
构建且已验证 hash 的 artifact，未重编译。

上一轮 accepted 六行结果/evidence 之后、correction dispatch 之前，一次误启动的非
cgroup plain `make -j6 f1a-control-flow-fence-smoke` 在约 20 秒内终止，未产出或采用
结果；有效重型作业均为上述受限 scope。

完整结果：[`docs/F1A_CONTROL_FLOW_FETCH_FENCE_RESULTS.md`](../F1A_CONTROL_FLOW_FETCH_FENCE_RESULTS.md)。机器证据：
[`docs/tasks/evidence/T-20260901-010.json`](../tasks/evidence/T-20260901-010.json)。完整
build/report/probe/log 留在 `build/agents/T-20260901-010-correction-provenance/`，未进
Git；旧 `build/agents/T-20260901-010-correction/` c44-labeled raw artifacts 保留但
明确 excluded，未覆盖伪装。

风险是 raw predecode 需随 decoder 新增控制流编码同步；当前 F1a 仍默认关闭，不能
仅凭三项通过立即签核。集成后必须重跑完整 196-row/98-pair matrix，若其它控制流
出现语义/性能回归立即停止并拆分诊断，不降低 `2%+64`。
