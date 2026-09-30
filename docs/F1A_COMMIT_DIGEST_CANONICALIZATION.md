# 性能 runner commit digest v2 规范化

> 任务：`T-20260901-003`（PE-F1E-DIGEST-CANON）
> 状态：review；实现只作用于验证摘要和 provenance，不构成 F1a RTL 修复。
>
> dispatch.sent_at / received_at：`2026-09-01T01:44:32+08:00`；
> reported_at（correction）：`2026-09-01T02:56:41+08:00`。

## 结论

生产 runner 已将提交摘要提取到 `sim/microbench/commit_digest.h`，并采用明确的
`lcvex-commit-digest-v2-active-payload` 契约：退休序号、PC、指令、next PC 以及
所有 enable/count 始终参与 FNV-1a；只有无效 payload 按原宽度喂零。vector
`write_count > 4` 标记 digest invalid，不静默截断为 4；monitor 的 payload 以
`mon_we` 为顶层有效边界。

在同一 `neon_vect` image 上串行重建并运行 `nocache_d0`、`fullcache_d1` 两组 F0/F1a：

| pair | F0 / F1a status | retired | v2 commit digest | memory digest / effects | active trace compare |
| --- | --- | ---: | --- | --- | --- |
| `nocache_d0/neon_vect` | pass / pass | 66721 / 66721 | `5c1d4f0a0f31cfe7` / `5c1d4f0a0f31cfe7` | `3ba6dea5f6c76128` / `3ba6dea5f6c76128`，4116 / 4116 | `equal`，66721 |
| `fullcache_d1/neon_vect` | pass / pass | 66721 / 66721 | `5c1d4f0a0f31cfe7` / `5c1d4f0a0f31cfe7` | `3ba6dea5f6c76128` / `3ba6dea5f6c76128`，4116 / 4116 | `equal`，66721 |

T-001 中的旧 v1 footer `3caef22144f0b28a`/`3ec03fbc5b7681d0` 在相同 active 提交
序列上归一化为相同的 v2 digest；这只修复摘要边界，不能单独作为 F1a RTL 等价
签核。正式 comparator 未修改。

本 correction 只加强 fixture 的逐字段独立性，并修正任务时间戳；生产 helper、runner、
四个已验证 runner binary 和动态 v2 结果均未改变或重建。

## 1. v2 digest 契约

生产 helper 为 header-only `lcvex_commit_digest::Accumulator`，输入
`CommitPacket` 使用固定字段顺序和宽度：

| 区域 | 始终喂入 | 无效 payload 规则 |
| --- | --- | --- |
| 基本提交 | `seq`、`pc`、`next_pc`、`insn` | 无 |
| GPR1/2/3 | 各自 `we` | `we=0` 时 rd/data 按 8-bit/64-bit 喂零 |
| SP/NZCV | 各自 `we` | enable=0 时按 64-bit/8-bit 喂零 |
| memory 1/2 | 各自 `we` | enable=0 时 addr/data/strobe 按 64/64/8-bit 喂零 |
| exception | `exc_valid` | invalid 时 code/ESR/FAR 按 32/32/64-bit 喂零 |
| monitor | `mon_we` | `mon_we=0` 时 valid/addr/data/data2 全部喂零 |
| vector | 原始 `vec_write_count` | 仅 `index < count` 且 index<4 的 rd/lo/hi 有效，其余槽按 8/64/64-bit 喂零 |
| FPCR/FPSR | 各自 `we` | enable=0 时 32-bit data 喂零 |

FNV-1a 使用 offset `1469598103934665603`、prime `1099511628211`，逐字段按
little-endian byte feed；不使用 struct padding 或 host 字节序。`count > 4` 会令
`Accumulator::update()` 返回 false 且 `valid()` 永久为 false，同时仍哈希原始 count，
因此不会把非法 packet 当作合法四槽 packet。

## 2. 传播和 provenance

- runner JSON 增加顶层 `commit_digest_schema`、`commit_digest_valid`，并在
  `stable_digest.schema` 中重复记录 schema；invalid digest 输出 `status=error`、
  return code 2。
- JSONL 保留历史 record-format `schema=lcvex-commit-trace-v1`，新增 header/footer
  `digest_schema=lcvex-commit-digest-v2-active-payload` 和 footer
  `digest_valid`。旧 v1 artifact 不改写。
- `perf_runner.py` 对缺失、错误 schema 或 `valid != true` 的 runner 输出拒绝为
  comparable 结果；不会把旧人类输出或 v1 摘要静默当成 v2。
- `run_perf_matrix.py` 在每个 row、matrix JSON 顶层/provenance 和 CSV 列传播
  `commit_digest_schema`；aggregate-only 和最终 aggregate 在 schema 不等于 v2 时
  直接报告 provenance mismatch。这样 pair schema 不同不能进入严格比较。
- `Makefile` 增加 `commit-digest-test` 并纳入 `make test`；registry 新增
  `l1.commit-digest` 条目。

## 3. fixture 覆盖

`sim/microbench/commit_digest_test.cc` 直接调用生产 `Accumulator`，没有复制另一套
digest 实现，覆盖：

- GPR1/2/3、SP、NZCV、memory1/2、exception、monitor、vector、FPCR/FPSR 的所有
  inactive payload 变化均保持摘要相等；monitor 明确测试 `mon_we=0` 边界。
- `seq`、PC、next PC、insn、每个 enable、vector count、每个 active 标量 payload、
  四个 active vector slot 的 rd/lo/hi 和 FP payload 变化均使摘要不同。
- 每个 active 子字段都从同一类独立的已启用基准 packet 单独复制变异；当
  `vec_write_count=1` 时，slots 1/2/3 的 payload 单独变化均保持摘要相等。
- vector count=4 合法；count=5 返回 invalid 且摘要可检测；重复运行确定性和固定
  golden 均通过。

固定 golden 为 `0x8b782b3f31381149`。入口命令：

```sh
make commit-digest-test
python3 -m py_compile sim/microbench/perf_runner.py scripts/run_perf_matrix.py
python3 scripts/test_registry.py --check --check-consistency
python3 scripts/test_registry_test.py
```

结果分别为 helper fixture PASS、Python 编译 PASS、registry 64 项及一致性 PASS、
registry 单元测试 PASS。

## 4. 动态验证与资源

冻结 base 为 `e65005c2beab3e2b1fc25e8bc0f49a868b3c16ff`，实现/测试 tip 为
`5254184fb09bb02cec9b2f404ec48a55b609bfcf`。固定 image
`build/microbench/perf_neon_vect.bin`（1864 bytes，SHA256
`6ebbd4c33bce14151a78f318bb2a352f496f9def93b6cdd417b91d057db1f7bf`），四次运行的
source bundle SHA256 都为 `be1d5d1c6c988d84b80d03821822568eec115302445c4500b0e2b3e4a9f6f5d3`。

所有重型构建/运行使用：

```text
MemoryMax=15G  MemorySwapMax=0  CPUQuota=50%
MAKEFLAGS=-j1 VERILATOR_JOBS=1
```

构建 Verilator allocated / wall time：`nocache_d0_f0=1043.500 MB/601.894 s`、
`nocache_d0_f1a=1044.273 MB/615.574 s`、`fullcache_d1_f0=1045.488 MB/611.668 s`、
`fullcache_d1_f1a=1046.250 MB/640.498 s`。四次 runner 仿真 RSS 分别为
`140184/140156/140448/140716 KiB`。

最终 runner JSON 还记录了预期的周期差异：
`nocache_d0` F0/F1a 为 `227526/175716` cycles，`fullcache_d1` F0/F1a 为
`253416/200033` cycles；cycle/FIFO context 不进入 v2 commit digest。

## 5. matrix/schema 复核

使用四份最终 runner JSON 做 build-only aggregate，生成：

- `build/agents/T-20260901-003/matrix/matrix.json`：4 rows，顶层和 provenance
  均含 v2 digest schema，SHA256 `e52fb48d83df96a7da739bd7539a3bfd97f6fd3cf6a66e48618a4f1d9caaac0a`；
- `build/agents/T-20260901-003/matrix/matrix.csv`：包含 `commit_digest_schema` 列，
  四行均为 v2，SHA256 `a13688f3db4ea635c2a90a460075309c61af7867153093a4fa591d6ead3ae8a2`。

对伪造的旧 schema row 调用 matrix guard 得到预期
`digest schema provenance mismatch`；没有修改或重写历史 v1 matrix/artifact。

两组 trace 使用未修改的 `scripts/compare_commit_traces.py` 均返回：
`status=equal`、`category=equal`、`records_compared=66721`。比较 JSON SHA256 为
`nocache_d0=b9d6ced537255795fdfa755ac6d2fc221b2cf58ce83b34dc503d61a0fde435fa`、
`fullcache_d1=484fa030e42c60af50c8fcb5335407cd18e1b9d724923f69cbd5db31b9f0a1cf`。

## 6. 边界和限制

本任务只改变性能 runner 的摘要 helper、schema 传播、测试入口和文档证据；未修改
RTL、QEMU、workload、reference 或正式 comparator。未运行完整 196-row 矩阵、Gate D、
Linux、Quartus/FPGA。代表性两个 pair 已完成 v2 严格相等，但这不替代后续在新冻结
SHA 上对其余历史 mismatch 的闭合复测，也不打开 F1a 默认开关的阶段门。
