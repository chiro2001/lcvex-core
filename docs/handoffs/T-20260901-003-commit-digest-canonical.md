# T-20260901-003 commit digest canonicalization handoff

```text
task=T-20260901-003 state=review
base=e65005c2beab3e2b1fc25e8bc0f49a868b3c16ff
head=5254184fb09bb02cec9b2f404ec48a55b609bfcf（实现/测试 tip；docs/evidence 待本任务提交）
measurement_source=5254184fb09bb02cec9b2f404ec48a55b609bfcf
branch=infra/T-20260901-003-commit-digest-canonical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-003
owner=luna-commit-digest-canonicalization
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-09-01T01:44:32+08:00
received_at=2026-09-01T01:44:32+08:00
reported_at=2026-09-01T02:56:41+08:00
files=sim/microbench/commit_digest.h;
      sim/microbench/commit_digest_test.cc;
      sim/microbench/microbench_runner.cc;
      sim/microbench/perf_runner.py;
      scripts/run_perf_matrix.py;
      scripts/test_registry.json;
      Makefile;
      docs/F1A_COMMIT_DIGEST_CANONICALIZATION.md;
      docs/handoffs/T-20260901-003-commit-digest-canonical.md;
      docs/tasks/evidence/T-20260901-003.json
tests=make commit-digest-test PASS；registry/py_compile PASS；schema guard PASS；两组 F0/F1a trace comparator equal
blockers=未运行完整 196-row、Gate D、Linux、Quartus；本任务只修摘要语义，不构成 RTL 阶段门
next=集成者复核两个逻辑提交并在合并 SHA 上复跑任务要求子集
```

## 实现摘要

生产 `lcvex_commit_digest::Accumulator` 已从 runner loop 提取到
`sim/microbench/commit_digest.h`。它保持原有字段顺序、字段宽度、退休序号、PC、
insn、next PC 和所有 enable/count；enable 无效时只将 payload 归零。vector 原始
count 始终哈希，最多四槽有效，`count>4` 返回 invalid；monitor 由 `mon_we` 决定
payload 是否有效。FNV-1a 为逐字节 little-endian，不含 cycle、FIFO counters、padding
或 host 顺序。

`commit_digest_test.cc` 直接调用该生产 helper，覆盖每类 inactive payload 相等、每类
active payload/enable/count 敏感性、四个 vector slot、count overflow、golden 和
determinism；每个 active 子字段都从独立的已启用基准 packet 复制变异，且额外验证
`vec_write_count=1` 时 slots 1/2/3 的 inactive payload 不影响摘要；golden=`8b782b3f31381149`。

runner JSON/trace footer/header、`perf_runner.py` 和 `run_perf_matrix.py` 均传播
`lcvex-commit-digest-v2-active-payload`。旧 schema 不会静默进入 matrix aggregate；
历史 v1 artifact 不改写。正式 `scripts/compare_commit_traces.py` 未修改。

## 动态结论

固定 image SHA256 为
`6ebbd4c33bce14151a78f318bb2a352f496f9def93b6cdd417b91d057db1f7bf`，measurement
source 为 `5254184fb09bb02cec9b2f404ec48a55b609bfcf`，source bundle SHA256 为
`be1d5d1c6c988d84b80d03821822568eec115302445c4500b0e2b3e4a9f6f5d3`。结果：

```text
nocache_d0  f0 : pass, retired=66721, commit=5c1d4f0a0f31cfe7,
               memory=3ba6dea5f6c76128, effects=4116
nocache_d0  f1a: pass, retired=66721, commit=5c1d4f0a0f31cfe7,
               memory=3ba6dea5f6c76128, effects=4116
fullcache_d1 f0 : pass, retired=66721, commit=5c1d4f0a0f31cfe7,
               memory=3ba6dea5f6c76128, effects=4116
fullcache_d1 f1a: pass, retired=66721, commit=5c1d4f0a0f31cfe7,
               memory=3ba6dea5f6c76128, effects=4116
```

两组 active trace 均 `equal`、`records_compared=66721`。最终 trace/comparison/matrix
路径、SHA256、runner build 资源和精确命令见
[`docs/tasks/evidence/T-20260901-003.json`](../tasks/evidence/T-20260901-003.json)。

## 风险与限制

这次修复只消除 inactive payload 造成的验证摘要假阳性；它没有改变 RTL 提交行为，
也不能证明所有 F1a 历史 mismatch 已闭合。完整 196-row、Gate D、Linux、Quartus 和
其余 timeout/commit-only pair 留给后续任务。集成前请在合并 SHA 上复跑 helper fixture、
schema guard、两个代表性 pair 和 active trace comparator。
