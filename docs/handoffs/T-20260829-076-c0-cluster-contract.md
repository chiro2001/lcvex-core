# T-20260829-076 C0 多核 cluster/一致性契约设计（owner handoff）

状态：**owner review candidate**，等待 I0 批准。

```text
task=T-20260829-076 state=review base=3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2 head=039e4aaa6a9eaf6f0afb299b3fe85d80d6479db6 branch=feature/T-20260829-076-c0-cluster-contract worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-076 sent_at=2026-08-29T01:47:44+0800 received_at=2026-08-29T01:52:30+0800 reported_at=2026-08-29T01:53:00+0800 files=docs/MULTICORE_CLUSTER_CONTRACT.md,docs/handoffs/T-20260829-076-c0-cluster-contract.md,docs/tasks/evidence/T-20260829-076.json tests=git diff --check pass; JSON tool pass; git diff --stat rtl/pkg/commit/QEMU empty pass; allowed-write-scope check pass blockers=none next=等待 I0 批准后进入 C1/D0
```

## 交付摘要

- 新增 `docs/MULTICORE_CLUSTER_CONTRACT.md`，作为 C1/C2/C3 实现依据。
- 文档覆盖：
  1. core wrapper：`CORE_COUNT/CORE_ID/MPIDR`、start/stop/quiesce/kill、
     每核 IRQ/timer/event、MC commit envelope、聚合内存请求和 per-core
     probe/drain 接口。
  2. 共享 L2 上游目录式 MSI：L1 `I/S/M`、目录 `I/S/M` + sharer/owner/
     dirty/pending、ReadShared/ReadUnique/Upgrade/WriteBack/Clean/
     Invalidate、dirty owner 下刷、probe hold/abort、错误回滚。
  3. `CORE_COUNT=1` 兼容模式、兼容检查点；AXI4 下游不变，不引入 ACE/CHI。
  4. reset 值、backpressure、kill、SVA 草案、常见序列草案。
  5. C1（双核壳层，无 coherence）、C2（双核 MSI）、C3（四核系统）边界，
     以及 12 项待 I0 批准问题。

## 边界

- 只写 `docs/MULTICORE_CLUSTER_CONTRACT.md`、handoff、evidence。
- 未修改 RTL、`lcvex_pkg`、commit/memory/QEMU，未新增 ACE/CHI。
- 所有多核接口都是设计草案；本任务不实现功能 RTL。

## 验证

- `git diff --check`：无 whitespace 错误。
- `python3 -m json.tool docs/tasks/evidence/T-20260829-076.json`：合法 JSON。
- `git diff --stat HEAD~1 -- rtl` 与共用内存/QEMU 路径：无改动。
- 人工回读：端口表、状态机、时序图、CORE_COUNT=1 兼容、C1/C2/C3 边界均写入。

## 风险 / 注意

- 一致性方案为 MSI；E/O 仅是扩展点，不被 C2 当作已实现。
- 完整 ARM memory model 不在本任务；litmus 子集和 linearization point
  仍需 D0/独立 memory-model 任务定义。
- 文档中 Signal 名称/SV struct 是契约草案，实际 RTL 接线由 C1/C2 按 I0
  批准后冻结。
