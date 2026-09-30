# T-20260901-002：F1a timeout pair 架构等价口径审计 handoff

```text
task=T-20260901-002
label=PE-F1D-TIMEOUT-AUDIT
state=review
base=ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37
measurement_source=291018d9a63efe549be589d1127e424e1118ed8a
report_tip=见最终报告（承载文档的 Git tip 不在 evidence 自引用）
branch=review/T-20260901-002-f1a-timeout-equivalence
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-002
owner=luna-f1a-timeout-equivalence-audit
model=gpt-5.6-luna
reasoning_effort=max
sent_at=2026-09-01T00:23:53+08:00
received_at=2026-09-01T00:23:53+08:00
reported_at=2026-09-01T00:43:46+08:00
files=docs/F1A_TIMEOUT_EQUIVALENCE_AUDIT.md;
      docs/handoffs/T-20260901-002-f1a-timeout-equivalence.md;
      docs/tasks/evidence/T-20260901-002.json
tests=read-only T-007 JSON/CSV parse；98 pair/196 row regroup；10 timeout-related mismatch independent recalc；runner/workload/digest source audit
non_actions=no Verilator/QEMU/Quartus/Gate/Linux；no RTL/runner/workload/comparator/reference changes
blockers=无动态完成/共同前缀证据；F1a 仍不能按 98/98 签核
next=集成者登记 20-row dynamic closure；优先 5-pair trace triage；neon 5 commit-only pair 独立诊断
```

## 结论摘要

T-007 的 196 行/98 对输入完整，独立重算得到 10 个含
`timeout/status/retired_insn` 差异的 pair。10 对全部至少有一侧在固定
`5,000,000` 周期上限终止；它们可以是不同退休进度造成的前缀差异，但现有摘要
不足以证明架构等价。必须保持 F1a 默认关闭，后继任务用完成运行或共同退休前缀
逐提交比较确认。

当前总体 strict 结果为 83/98；另有 5 对 pass/pass `neon_vect` 只有
`commit_digest` 不同，本审计不诊断也不排除它们。98/98 门槛不变。

## 关键口径

- `startup_mb.s` 在 `main` 返回后向 `0x4400FE00` 写 MAGIC 并自旋；runner 只认
  该已提交 store。没有 marker 时，`status=timeout`、runner `returncode=1`，
  不是 workload 的功能返回值。
- runner 在每次 `commit_valid && commit_ready` 时先累计退休数和完整
  `commit_digest`，再累计 mem/mem2 `memory_digest`/effect count；MAGIC 检查位于
  同一循环后部。因此 pass 侧的结束 MAGIC 也进入摘要，timeout 侧只代表已观察的
  前缀。
- `commit_digest` 包含退休序号、PC、insn、next PC、写回、NZCV、内存、异常、
  monitor、vector/FP effect，但不包含 cycle；`memory_digest` 不是最终 RAM 快照。

## 复测建议

完整闭合 10 对的最小集合是 20 行（每对 f0/f1a 各一次），使用相同 image、runner、
参数和 source provenance，直到双方都提交 MAGIC。无法完成的一侧仍保持 unresolved。

优先 trace 子集为 5 对/10 行：

```text
nocache_d1/mem_random
nocache_d1/mem_seq
l1id_l2_d0/mem_random
nocache_d2/alu_latency
nocache_d2/ctrl_branch
```

`--trace` JSONL 必须逐提交比较 seq、PC、insn、next PC、GPR/SP/NZCV、mem/mem2、
异常、monitor 和 vector/FP effect。共同前缀不一致立即停止并保存现场；共同前缀
一致但未见 MAGIC 仍需提高上限完成最终状态比较。

T-007 既有 14 个 per-config `microbench_runner` 及其 manifest 只能作为
provenance/hash 对照；不得访问或复用 `/home/chiro/projects/mycpu/lcvex-wt-T-20260831-007`
的 build/失败现场。后继动态任务必须在自己的 sibling worktree、冻结 source 上
重建本次 20-row closure 所需的 10 个 unique config runner 和 5 个 workload image，
再执行 `--trace` 或 completion 运行。T-20260830-001 的 FPGA-A Quartus runner、
T-20260826-001 registry 任务均不是兼容的 F1C runner。

精确 pair 数据、独立重算 artifact、workload/digest 源码口径和资源计划见
[`docs/F1A_TIMEOUT_EQUIVALENCE_AUDIT.md`](../F1A_TIMEOUT_EQUIVALENCE_AUDIT.md)；
机器可读结果见 [`docs/tasks/evidence/T-20260901-002.json`](../tasks/evidence/T-20260901-002.json)。
