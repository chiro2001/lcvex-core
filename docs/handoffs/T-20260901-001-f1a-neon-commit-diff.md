# T-20260901-001 F1a `neon_vect` commit-only 诊断 handoff

```text
task=T-20260901-001 state=review
base=ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37
measurement_source=ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37
head=ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37（本 handoff/evidence 待提交）
branch=verify/T-20260901-001-f1a-neon-commit-diff
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-001
owner=luna-f1a-neon-commit-diagnosis
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-09-01T00:23:53+08:00
received_at=2026-09-01T00:23:53+08:00
reported_at=2026-09-01T01:35:27+08:00
files=docs/F1A_NEON_COMMIT_DIVERGENCE_DIAGNOSIS.md;
      docs/evidence/artifacts/T-20260901-001/first_commit_diff.json;
      docs/handoffs/T-20260901-001-f1a-neon-commit-diff.md;
      docs/tasks/evidence/T-20260901-001.json
tests=comparator self-test PASS；两组配置 JSONL/header/footer/active-record 独立审计 PASS
blockers=正式 commit_digest 仍为 footer-only mismatch；inactive raw payload 未暴露
next=登记 runner digest inactive-payload canonicalization 后继任务，再重跑 NEON 定向/成对摘要
```

## 结论摘要

在冻结 source/image 上，`nocache_d0` 与 `fullcache_d1` 的 F0/F1a 各自均退休
`66721` 条、状态均为 `pass`、memory digest 均为
`3ba6dea5f6c76128`。两侧逐条 active commit record 完全相同；比较器只在共同
提交前缀结束后发现 footer 的 `commit_digest`：

```text
F0  = 3caef22144f0b28a
F1a = 3ec03fbc5b7681d0
```

独立把 trace 中 inactive payload 归零后重算 canonical active digest，两配置均为
`5c1d4f0a0f31cfe7`/`5c1d4f0a0f31cfe7`。因此本任务没有捕获 RTL 的第一条架构提交
差异；证据指向 runner 正式摘要包含 trace 未暴露的 inactive payload。该结论不能
弱化正式比较，也不能作为 F1a 等价签核。

## 证据与边界

- 首个 pair 的紧凑比较结果：
  [`first_commit_diff.json`](../evidence/artifacts/T-20260901-001/first_commit_diff.json)，
  SHA256 `e8e7ec9c241fa7e781edd39652e8dbb258545956869ea78413ea1c2c608d364d`。
- `first_mismatch` 为 `off=null/on=null`、index `66721`，category
  `termination-boundary`；最后四条 commit 的 PC、指令、next PC 和 active effects
  完全相等。
- `fullcache_d1` 的完整比较 JSON 只保留在
  `build/agents/T-20260901-001/comparisons/fullcache_d1.json`，SHA256
  `89a7ec0828d7ad8f39b9d5a95c0e6881e1972ef619fdc4bfd5823e8ca530043d`；结果同为
  `termination-boundary`、`records_compared=66721`。
- 四份 JSONL 都是 `1 header + 66721 commit + 1 footer`，seq 连续，footer 后无数据；
  两侧 active effect 计数、memory side effect `4116` 项和逐条架构记录相等。
- F0/F1a 原始 trace SHA 不同是 cycle/fetch context 和 FIFO params 不同导致，比较器
  明确忽略这些字段。

任务 T-007 的五个 `neon_vect` mismatch 中，本任务新建并复核了
`nocache_d0` 和 `fullcache_d1` 两个代表；`l1i_d0`、`l1id_l2_d0`、`fullcache_d2`
未在 T-001 重跑。

## 实现审计结论

`sim/microbench/microbench_runner.cc:524-580` 显式哈希 seq/PC/next PC/insn、所有
标量和 FP/NEON commit 字段，采用 byte-wise FNV-1a，不含 cycle、FIFO 计数、wall
time、padding 或 host 顺序。trace writer 只写 active effect，所以正式 digest 的
差异无法从现有记录映射到具体 raw inactive 字段。

当前 runner/comparator/RTL 均未修改；完整 trace 和 build log 留在
`build/agents/T-20260901-001/`，不进 Git。F1a 默认开关保持 0。

## 后继最小任务建议

建议单独登记 runner-only canonicalization 任务：

- `sim/microbench/microbench_runner.cc`：对 disabled write-enable 和 vector count
  之外的 payload 归零后再哈希，完整保留所有架构字段和 active payload；
- `sim/microbench/commit_digest_test.cc`：fixture 验证 inactive raw payload 变化不改变
  digest，active 字段变化仍改变 digest；
- 新任务自己的 evidence/handoff/doc：记录 `nocache_d0`、`fullcache_d1` F0/F1a
  成对运行、active trace compare、memory digest 和 comparator self-test。

若需定位而非直接 canonicalize，备选是新增 opt-in raw-payload trace；两种方案都不
允许删除正式比较字段或修改参考结果。本 T-001 不实施任何修复。
