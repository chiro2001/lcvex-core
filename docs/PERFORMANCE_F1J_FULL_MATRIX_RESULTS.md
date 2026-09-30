# PE-F1J：F1a 控制流修复后完整 196 行回归

> 任务：`T-20260901-011`（PE-F1J-FULL-MATRIX）
> 状态：review；冻结 source SHA 上 196/196 rows、98/98 strict、98/98 guard/FIFO 全通过。
> base/measurement source：`f0edcd2528c01520eb4e4922266a7913c5c7539b`
> received_at：`2026-09-01T16:32:45+08:00`；reported_at：`2026-09-01T20:14:46+08:00`

## 结论

在 `f0edcd2528c01520eb4e4922266a7913c5c7539b` own worktree 中，从空的本任务 build 目录重建 14 个 runner 和 14 个 image，完成 196 rows、98 unique pairs。所有 row `status=pass`、returncode=0；98/98 pairs 的 retired、active-payload commit digest、memory digest 和 memory effects 严格相等；所有 F1a FIFO bounds 与 98 个 `2%+64` guard 全通过。

T-004 原有 95/98 guard 通过、以下 3 项失败已全部闭合：

| pair | F0 cycles | F1a cycles | 增幅 | guard 上限 | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| `nocache_d2/alu_latency` | 5,795,747 | 4,904,275 | -15.381% | 5,911,725.94 | PASS |
| `nocache_d2/ctrl_branch` | 5,172,730 | 4,599,259 | -11.086% | 5,276,248.60 | PASS |
| `nocache_d2/mem_seq` | 7,273,882 | 6,664,445 | -8.378% | 7,419,423.64 | PASS |

## 1. Row/pair 汇总

| base | rows | pairs | strict equal | cycle guard |
| --- | ---: | ---: | ---: | ---: |
| `nocache_d0` | 28 | 14 | 14/14 | 14/14 |
| `l1i_d0` | 28 | 14 | 14/14 | 14/14 |
| `l1id_l2_d0` | 28 | 14 | 14/14 | 14/14 |
| `nocache_d1` | 28 | 14 | 14/14 | 14/14 |
| `nocache_d2` | 28 | 14 | 14/14 | 14/14 |
| `fullcache_d1` | 28 | 14 | 14/14 | 14/14 |
| `fullcache_d2` | 28 | 14 | 14/14 | 14/14 |
| **合计** | **196** | **98** | **98/98** | **98/98** |

## 2. FIFO、provenance 和资源

F0 98 rows FIFO counters 全零；F1a occupancy max=`2`、peak max=`2`、overflow total=`0`、push/pop=`29,886,879/29,886,808`，push<pop rows=`0`。
所有 196 rows 的 `sha`、`git_sha`、`measurement_source_sha` 均为 `f0edcd2528c01520eb4e4922266a7913c5c7539b`；pair 内 image/source/tool/max_cycles 和除 FIFO 外参数一致。

唯一矩阵 scope：`run-p1986779-i35557415.scope`，2026-09-01T16:35:58+08:00–2026-09-01T20:01:28+08:00（Asia/Shanghai），wall `12329.890s`、CPU `6164.976s`、MemoryPeak `5.6G`；限制为 MemoryMax=15G、MemorySwapMax=0、CPUQuota=50%、MAKEFLAGS=-j1、VERILATOR_JOBS=1。

## 3. Artifact 和边界

权威 JSON：[`f1j_full_matrix.json`](evidence/artifacts/T-20260901-011/f1j_full_matrix.json)，1355694 bytes，SHA256 `018dc721307ed286136e0f1365efff13ea8fc3a3ed94fb53b0b2b4f65b436d88`。
权威 CSV：[`f1j_full_matrix.csv`](evidence/artifacts/T-20260901-011/f1j_full_matrix.csv)，80723 bytes，SHA256 `796bbd4345bce19f411af65a992d5aa3cc69b9791ab2f0524d195b700e116b13`。
完整 per-row report/log/build 留在 `build/agents/T-20260901-011/`；本任务未运行 Gate D、Linux、QEMU lockstep、Quartus 或板测。

详细 provenance、14 runner/image/manifest hash、98 对数据和失败列表见 [T-20260901-011 evidence](tasks/evidence/T-20260901-011.json)。

下一步：集成者复核本报告并进入 F1a 默认启用决策；性能 cycle guard 与 FIFO/架构等价结果已全部闭合。
