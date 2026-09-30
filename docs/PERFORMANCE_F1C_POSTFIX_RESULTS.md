# PE-F1C H-04/T-006 后 F0/F1a 同 SHA 完整复测

> 任务：`T-20260831-007`（PE-F1C-POSTFIX）
> 测量源：`291018d9a63efe549be589d1127e424e1118ed8a`
> 结论：数据完整；严格架构摘要等价为 **83/98 pairs**，未达到 98/98，继续保持 F1a 默认关闭。

## 结论

本次使用冻结 source SHA，在 7 个 cache/delay base 上分别运行 FIFO 关闭（F0）与
2-entry FIFO 开启（F1a），共 196 个 canonical rows、98 个唯一 pair。所有 row
均有结果，且没有 `fail`/`error`；177 行 `pass`、19 行达到 5,000,000 周期上限
而为 `timeout`。

严格比较字段为 `status`、`returncode`、`retired_insn`、`commit_digest` 和
`memory_digest`。83/98 pairs 完全相同，15 对不相同；因此本次只能作为完整、可审计
的测量数据，不能作为 F1a 架构等价或性能签核。F1a 默认值继续为 0。

## 测量范围与复现命令

工作树为 `/home/chiro/projects/mycpu/lcvex-wt-T-20260831-007`，开始测量前 clean，
`HEAD` 与 `measurement_source_sha` 均为 `291018d9a63efe549be589d1127e424e1118ed8a`。
入口、配置和 workload 顺序均未改动：

```sh
systemd-run --user --scope \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% -- \
  env MAKEFLAGS=-j1 VERILATOR_JOBS=1 \
  python3 scripts/run_perf_matrix.py \
    --configs all --workloads all --max-cycles 5000000 \
    --out-dir build/agents/T-20260831-007/f1c_matrix \
    --artifact-dir docs/evidence/artifacts/T-20260831-007
```

7 个 base 为 `nocache_d0`、`l1i_d0`、`l1id_l2_d0`、`nocache_d1`、`nocache_d2`、
`fullcache_d1`、`fullcache_d2`；每个 base 都有 `f0`/`f1a` 两行配置。14 个
workload 为：

`alu_latency`、`alu_ilp`、`ctrl_branch`、`muldiv`、`mem_seq`、`mem_random`、
`mem_ldst`、`fp_scalar`、`fp_fp16`、`neon_vect`、`kernel_crc`、`kernel_hash`、
`kernel_matmul`、`kernel_sort`。

每个 workload 只构建一次镜像后复用于 14 个配置；每个配置独立构建 runner。Verilator
为 5.050（2026-07-01 conda-forge），交叉工具链为
`aarch64-linux-gnu-gcc (GCC) 16.1.0`，性能编译选项为 `-O2`。

## Row/pair 结果

| base | rows | pass/pass | timeout/timeout | status mismatch | strict equal | retired mismatch | memory digest/effect mismatch | commit-only mismatch | cycle guard |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `nocache_d0` | 28 | 14 | 0 | 0 | 13 | 0 | 0 | 1 | 14/14 |
| `l1i_d0` | 28 | 14 | 0 | 0 | 13 | 0 | 0 | 1 | 14/14 |
| `l1id_l2_d0` | 28 | 13 | 1 | 0 | 12 | 1 | 0 | 1 | 13/13 |
| `nocache_d1` | 28 | 12 | 1 | 1 | 12 | 2 | 2 | 0 | 12/12 |
| `nocache_d2` | 28 | 9 | 5 | 0 | 9 | 5 | 0 | 0 | 9/9 |
| `fullcache_d1` | 28 | 13 | 1 | 0 | 12 | 1 | 0 | 1 | 13/13 |
| `fullcache_d2` | 28 | 13 | 1 | 0 | 12 | 1 | 0 | 1 | 13/13 |
| **合计** | **196** | **88** | **9** | **1** | **83** | **10** | **2** | **5** | **88/88** |

`pass/pass` 的 cycle 护栏为 `cycles_f1a <= cycles_f0 * 1.02 + 64`，88/88 对通过；
护栏只描述周期关系，不覆盖摘要不等价。

严格失配按 canonical 配置顺序的第一项为 `nocache_d0/neon_vect`：两侧均
`retired_insn=66721`，但 commit digest 为 `3caef22144f0b28a` 与
`3ec03fbc5b7681d0`。全部 15 项失配如下：

| pair | 不同字段 | status f0/f1a | retired f0/f1a | commit digest f0/f1a |
| --- | --- | --- | ---: | --- |
| `nocache_d0/neon_vect` | `commit_digest` | pass/pass | 66721/66721 | `3caef22144f0b28a`/`3ec03fbc5b7681d0` |
| `l1i_d0/neon_vect` | `commit_digest` | pass/pass | 66721/66721 | `3caef22144f0b28a`/`3ec03fbc5b7681d0` |
| `l1id_l2_d0/mem_random` | `retired_insn,commit_digest` | timeout/timeout | 398516/420876 | `18174ac5155862e9`/`fe72e94fa7ae284a` |
| `l1id_l2_d0/neon_vect` | `commit_digest` | pass/pass | 66721/66721 | `3caef22144f0b28a`/`3ec03fbc5b7681d0` |
| `nocache_d1/mem_seq` | `retired_insn,commit_digest,memory_digest` | timeout/timeout | 787714/796232 | `21fa6f4867492b5d`/`4d4e958016fd784c` |
| `nocache_d1/mem_random` | `status,returncode,retired_insn,commit_digest,memory_digest` | timeout/pass | 474797/475192 | `8db34ca7282f37c4`/`08c9181cf290ad35` |
| `nocache_d2/alu_latency` | `retired_insn,commit_digest` | timeout/timeout | 647073/602941 | `02ea93e7af2acbd7`/`3f2cc6280d35122e` |
| `nocache_d2/alu_ilp` | `retired_insn,commit_digest` | timeout/timeout | 691402/694470 | `831fa17369682b8c`/`d6ea0e226e068f90` |
| `nocache_d2/ctrl_branch` | `retired_insn,commit_digest` | timeout/timeout | 668403/607808 | `be4d5838f31460fe`/`92f25245d411ba21` |
| `nocache_d2/mem_seq` | `retired_insn,commit_digest` | timeout/timeout | 562166/553599 | `8c4a9bb520bfdd2f`/`6780d87b236bc2ff` |
| `nocache_d2/mem_random` | `retired_insn,commit_digest` | timeout/timeout | 407881/413351 | `a9b36cc8cd729082`/`4f208b0b91e06700` |
| `fullcache_d1/mem_random` | `retired_insn,commit_digest` | timeout/timeout | 356074/374163 | `afb153dda1664de8`/`863cbfb03257b6f1` |
| `fullcache_d1/neon_vect` | `commit_digest` | pass/pass | 66721/66721 | `3caef22144f0b28a`/`3ec03fbc5b7681d0` |
| `fullcache_d2/mem_random` | `retired_insn,commit_digest` | timeout/timeout | 319908/333415 | `5c7b458e951ecafe`/`315023745c7805b3` |
| `fullcache_d2/neon_vect` | `commit_digest` | pass/pass | 66721/66721 | `3caef22144f0b28a`/`3ec03fbc5b7681d0` |

其中两项 memory digest/effect mismatch 为：

- `nocache_d1/mem_seq`：memory digest `891501d65678a0da` → `f457537fc364cd8c`；
- `nocache_d1/mem_random`：memory digest `c109a4332b568b5b` → `4e707e98e0c89190`。

另有 5 个 pair 只有 commit digest 不同、retired 和 memory 摘要相同；它们也不能
视为架构等价。

19 个 timeout row 全部保留，未因 timeout 或摘要差异重跑、过滤或挑选结果：

`l1id_l2_d0_f0/mem_random`、`l1id_l2_d0_f1a/mem_random`、
`nocache_d1_f0/mem_seq`、`nocache_d1_f0/mem_random`、
`nocache_d1_f1a/mem_seq`、`nocache_d2_f0/alu_latency`、
`nocache_d2_f0/alu_ilp`、`nocache_d2_f0/ctrl_branch`、
`nocache_d2_f0/mem_seq`、`nocache_d2_f0/mem_random`、
`nocache_d2_f1a/alu_latency`、`nocache_d2_f1a/alu_ilp`、
`nocache_d2_f1a/ctrl_branch`、`nocache_d2_f1a/mem_seq`、
`nocache_d2_f1a/mem_random`、`fullcache_d1_f0/mem_random`、
`fullcache_d1_f1a/mem_random`、`fullcache_d2_f0/mem_random`、
`fullcache_d2_f1a/mem_random`。

## FIFO/epoch 边界

F0 的全部 FIFO counters 为 0。F1a 的全矩阵统计如下：

| 指标 | 结果 |
| --- | ---: |
| F1a rows | 98 |
| occupancy max | 2 |
| peak signal max | 2 |
| overflow total | 0 |
| push total | 29,476,582 |
| pop total | 28,935,387 |
| flush total | 6,580,600 |
| epoch bump total | 6,580,600 |
| stale drop total | 5,595,112 |
| stale drain cycles total | 5,269,955 |
| rows with push < pop | 0 |

所有 FIFO-on row 满足 occupancy/peak ≤2、overflow=0、push≥pop。FIFO counters 是
只读观测值，不是架构状态或 PMU 签核。

仅统计两侧均为 pass 的 pair 时，各 base 的周期汇总为：

| base | pass/pass | f0 cycles 总和 | f1a cycles 总和 | Δ |
| --- | ---: | ---: | ---: | ---: |
| `nocache_d0` | 14 | 17,971,370 | 14,992,695 | -16.575% |
| `l1i_d0` | 14 | 17,973,482 | 14,586,022 | -18.847% |
| `l1id_l2_d0` | 13 | 15,158,642 | 12,180,838 | -19.644% |
| `nocache_d1` | 12 | 17,251,008 | 16,403,933 | -4.910% |
| `nocache_d2` | 9 | 7,155,308 | 6,922,489 | -3.254% |
| `fullcache_d1` | 13 | 15,658,716 | 12,680,928 | -19.017% |
| `fullcache_d2` | 13 | 16,136,201 | 13,161,237 | -18.437% |

周期下降只是 Verilator 仿真的观测量；严格摘要不一致的 pair 不可据此宣称收益。

## 与 T-043 的 delta

T-043 的冻结测量结果为 196 rows、177 pass、19 timeout、56/98 strict-equivalent
pairs。本次结果为 196 rows、177 pass、19 timeout、83/98 strict-equivalent pairs：

| 指标 | T-043 | T-007 | delta |
| --- | ---: | ---: | ---: |
| rows | 196 | 196 | 0 |
| pass | 177 | 177 | 0 |
| timeout | 19 | 19 | 0 |
| fail | 0 | 0 | 0 |
| strict-equivalent pairs | 56 | 83 | +27 |

status mismatch 仍为 1（`nocache_d1/mem_random`），timeout/pass pair 仍为 1；
本次没有把状态变化隐藏成摘要或性能收益。

## Provenance 与边界

审计确认：

- 196/196 row 的 measurement source、toolchain 和 max_cycles 唯一且正确；
- 98/98 pair 无缺失/重复；每对除 FIFO 开关与 `FIFO_VARIANT` 外 cache/delay、
  workload source/image、toolchain、max_cycles 和 runner 参数完全一致；
- 14 个 runner 和 14 个 workload image 均在本 worktree 重新生成；
- 未修改 RTL、TB、runner、workload、QEMU、比较器或参考结果；
- 未运行 Gate D、Linux、Quartus，也不把本矩阵当作 F1b/A10/Fmax/FPGA 证据。

权威逐行数据为 [`f1c_matrix.json`](evidence/artifacts/T-20260831-007/f1c_matrix.json)
和 [`f1c_matrix.csv`](evidence/artifacts/T-20260831-007/f1c_matrix.csv)；精确运行
时间、资源、runner/image hash 和审计字段见任务 evidence JSON。

后续应保存 15 个 strict mismatch 的提交级差异，定位数据/FP/NEON/timeout 路径的
FIFO flush/quarantine 与 commit 序列关系；在新的修复任务和新的冻结 SHA 通过严格
摘要后，才能重新评估 F1a 签核。
