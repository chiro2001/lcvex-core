# PE-F1F commit digest v2 完整 196-row 运行至完成矩阵

> 任务：`T-20260901-004`（PE-F1F-V2-FULL-MATRIX）
> 状态：review；数据完整，严格摘要与 FIFO 正确性前置通过；性能 cycle guard 未全通过，F1a 不能默认启用或进行性能签核。
>
> sent_at / received_at：`2026-09-01T03:04:46+08:00`；
> reported_at（correction）：`2026-09-01T07:09:16+08:00`。

## 结论

在冻结 source SHA `3816c95a92692e336b2c2063d9d7ef7f998d6b0f` 上，使用
`lcvex-commit-digest-v2-active-payload` 和 `max_cycles=10000000`，在本任务 own
worktree 新建 14 个 workload image 和 14 个 F0/F1a runner，完成 196 rows、98 pairs：

- 196/196 rows 为 `pass`、returncode=0、schema 统一为 v2；没有 timeout、fail 或 error。
- 98/98 pairs 的 `status`、returncode、retired、digest schema、v2 commit digest、
  memory digest 和 committed memory effects 全部相同。
- 所有 F1a row 的 FIFO occupancy/peak 均不超过 2、overflow=0、push≥pop。
- 98 个 pass/pass pair 中 95 个满足 `cycles_f1a <= cycles_f0*1.02+64`；以下 3 个
  `nocache_d2` pair 超出护栏，必须原样保留为 acceptance blocker：

| pair | F0 cycles | F1a cycles | F1a/F0 增幅 | guard 上限 | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| `nocache_d2/alu_latency` | 5,795,747 | 6,219,933 | +7.319% | 5,911,725.94 | FAIL |
| `nocache_d2/ctrl_branch` | 5,172,730 | 5,749,229 | +11.145% | 5,276,248.60 | FAIL |
| `nocache_d2/mem_seq` | 7,273,882 | 7,456,315 | +2.508% | 7,419,423.64 | FAIL |

因此 F1a 仍保持默认关闭；三项 cycle guard failure 只阻塞 F1a 默认启用和性能签核。
标准 F0 配置的完整本地 Gate D 已获用户授权，集成者可在合并后冻结主线候选运行；
标准 Gate D 不等于 F1a-on Gate D，F1a-on 正确性证据由本次 98/98 v2 矩阵和既有定向
锁步提供。本任务本身不运行 Gate D/Linux/Quartus。

## 1. 复现入口与 provenance

```sh
systemd-run --user --scope \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% -- \
  env MAKEFLAGS=-j1 VERILATOR_JOBS=1 \
  python3 scripts/run_perf_matrix.py \
    --configs all --workloads all --max-cycles 10000000 \
    --out-dir build/agents/T-20260901-004/f1f_v2_matrix \
    --artifact-dir docs/evidence/artifacts/T-20260901-004
```

worktree 为 `/home/chiro/projects/mycpu/lcvex-wt-T-20260901-004`，开始和结束均
clean；没有访问或复用旧任务 worktree/build。固定工具链为 Verilator
`5.050 2026-07-01 rev conda-forge build 0`、`aarch64-linux-gnu-gcc 16.1.0`、
Python `3.12.10`，所有 runner/image 均在本 worktree 从冻结 source 重建。

14 个 workload image 的 source/image provenance 在 evidence JSON 中逐项记录；
关键 `neon_vect` image 为 1864 bytes、SHA256
`6ebbd4c33bce14151a78f318bb2a352f496f9def93b6cdd417b91d057db1f7bf`。

## 2. Row/pair 汇总

| base | rows | pass/pass pairs | strict equal | cycle guard |
| --- | ---: | ---: | ---: | ---: |
| `nocache_d0` | 28 | 14 | 14 | 14/14 |
| `l1i_d0` | 28 | 14 | 14 | 14/14 |
| `l1id_l2_d0` | 28 | 14 | 14 | 14/14 |
| `nocache_d1` | 28 | 14 | 14 | 14/14 |
| `nocache_d2` | 28 | 14 | 14 | 11/14 |
| `fullcache_d1` | 28 | 14 | 14 | 14/14 |
| `fullcache_d2` | 28 | 14 | 14 | 14/14 |
| **合计** | **196** | **98** | **98** | **95/98** |

strict 字段为 `status`、`returncode`、`retired_insn`、
`commit_digest_schema`、`commit_digest`、`memory_digest` 和
`committed_memory_effects`。JSON row 中 effect count 位于
`stable_digest.committed_memory_effects`，CSV 同时提供平铺列；两种表示逐行一致。

所有 196 rows 的 schema 均为 `lcvex-commit-digest-v2-active-payload`，matrix JSON
顶层/provenance 和 matrix CSV 也带有该 schema。14 个 pair workload image/source
hash 在 F0/F1a 之间一致，无缺失或重复 key。

## 3. T-007 原 15 项闭合

T-007 的 5 个 pass/pass `neon_vect` commit-only pair 全部闭合：
`nocache_d0`、`l1i_d0`、`l1id_l2_d0`、`fullcache_d1`、`fullcache_d2`；均为
retired `66721/66721`、commit digest `5c1d4f0a0f31cfe7/5c1d4f0a0f31cfe7`、
memory digest `3ba6dea5f6c76128`、memory effects `4116/4116`。

原 10 个 timeout-related pair 在 10M 上限下也全部 `pass/pass`、strict equal：

| pair | retired F0/F1a | cycles F0/F1a | commit digest | memory digest / effects | guard |
| --- | ---: | ---: | --- | --- | --- |
| `l1id_l2_d0/mem_random` | 475192/475192 | 6217700/5808050 | `dbf7d5db29bb57c7`/同值 | `4e707e98e0c89190`/8197 | PASS |
| `nocache_d1/mem_seq` | 803657/803657 | 5108405/5050468 | `46e5ead18aa77a80`/同值 | `6b40dea7a6ade5c3`/114714 | PASS |
| `nocache_d1/mem_random` | 475192/475192 | 5005638/4759843 | `dbf7d5db29bb57c7`/同值 | `4e707e98e0c89190`/8197 | PASS |
| `nocache_d2/alu_latency` | 750049/750049 | 5795747/6219933 | `ab7d672bf0489762`/同值 | `0dd7f555d8ef95bf`/4 | FAIL |
| `nocache_d2/alu_ilp` | 800072/800072 | 5791747/5722497 | `aadc4a0cbd347f6f`/同值 | `fe4b1964ce21abdf`/4 | PASS |
| `nocache_d2/ctrl_branch` | 690074/690074 | 5172730/5749229 | `a555baec3f932af5`/同值 | `0617c8083a02b214`/13 | FAIL |
| `nocache_d2/mem_seq` | 803657/803657 | 7273882/7456315 | `46e5ead18aa77a80`/同值 | `6b40dea7a6ade5c3`/114714 | FAIL |
| `nocache_d2/mem_random` | 475192/475192 | 6131621/5965367 | `dbf7d5db29bb57c7`/同值 | `4e707e98e0c89190`/8197 | PASS |
| `fullcache_d1/mem_random` | 475192/475192 | 7028750/6619100 | `dbf7d5db29bb57c7`/同值 | `4e707e98e0c89190`/8197 | PASS |
| `fullcache_d2/mem_random` | 475192/475192 | 7823254/7431072 | `dbf7d5db29bb57c7`/同值 | `4e707e98e0c89190`/8197 | PASS |

因此原 15 项在摘要/架构字段上均已闭合；其中 3 项仍因性能护栏失败，不能作为
F1a 性能签核通过。

此前 T-007 的 19 个 timeout rows 在本次 10M 矩阵中全部完成，没有 timeout row
被过滤、挑选或改写。

## 4. FIFO/epoch 审计

F0 的 98 rows 所有 FIFO counters 均为 0。F1a 的 98 rows：

| 指标 | 结果 |
| --- | ---: |
| occupancy max | 2 |
| peak signal max | 2 |
| overflow total | 0 |
| push total | 30,470,441 |
| pop total | 29,886,808 |
| flush / epoch bump total | 6,778,128 / 6,778,128 |
| stale drop total | 5,750,187 |
| stale drain cycles total | 5,882,989 |
| push<pop rows | 0 |

## 5. Artifact 和资源

权威 artifact：

- [`f1f_v2_matrix.json`](evidence/artifacts/T-20260901-004/f1f_v2_matrix.json)：
  1,356,853 bytes，SHA256
  `7a166c9e2104dc0c060ee2f3aaa9d2cc09fecc8ac757b8ff69f84948c0937e2a`；
- [`f1f_v2_matrix.csv`](evidence/artifacts/T-20260901-004/f1f_v2_matrix.csv)：
  81,251 bytes，SHA256
  `f71d0b4e05758d389101cce689cdd97c4e6adde316ff57f6248670a9064d74af`。

矩阵 build-only JSON/CSV 与上述 artifact 内容字节一致。14 个 runner 的 binary 和
manifest SHA、14 个 workload image SHA 及 scope/journal 资源证据见
[`T-20260901-004.json`](tasks/evidence/T-20260901-004.json)。systemd journal 记录：

CSV 原始生成器使用 CRLF；为满足仓库 whitespace gate，build 与 Git artifact 的 CSV
统一转换为 LF，字段和 196 行数据未改变。

```text
scope=run-p3356669-i32724486.scope
started_at=2026-09-01T03:05:52+08:00
finished_at=2026-09-01T06:51:06+08:00
wall=3h45min13.598s
cpu=1h52min36.709s
memory_peak=6.2G
MemoryMax=15G MemorySwapMax=0 CPUQuota=50% MAKEFLAGS=-j1 VERILATOR_JOBS=1
```

## 6. 验收边界

本任务没有修改 RTL、runner、workload、QEMU、comparator、schema 或参考结果；
完整 matrix 数据和 artifact 已保存。由于 cycle guard 仅 95/98，F1a 默认开关和性能
签核保持阻塞；strict 98/98 与 FIFO 全绿已满足标准 Gate D 正确性前置。集成者可在
合并后冻结候选运行用户授权的标准 Gate D；这不代表运行 F1a-on Gate D。未运行
Gate D、Linux、Quartus/FPGA。
