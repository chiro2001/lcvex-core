# T-20260902-011 F1a-on Gate D rerun handoff

```text
task=T-20260902-011
state=done
base=a4503d0c56a674316cce92d5f83788e5473f8a24
head=b3f24e638e5b4bfffd750217916af9422a9fb7b7
branch=verify/T-20260902-011-f1a-on-gated-rerun
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-011
sent_at=2026-09-02T18:57:30+08:00
received_at=2026-09-02T18:57:40+08:00
reported_at=2026-09-02T20:24:10+08:00
```

## 结论

**DONE**：在包含 T-20260902-009 F1a 三类锁步修复的合并 SHA `a4503d0` 上，
完整本地串行 Gate D（默认 F1a-on）全部通过。退出码 0，无任何失败 step，
T-006 中 9 个 F1a-on 锁步失败用例（hard_timer、hard_adc_sbc、hard_sve_probe、
hard_postpre 的 base/cache/delay2 变体）全部转绿，未发现新回归。

默认-on 参数确认：

- `tb/sv/lcvex_soc_tb.sv`: `parameter int FETCH_FIFO_ENABLE = 1`
- `rtl/lcvex_core_wrap.sv`: `parameter int FETCH_FIFO_ENABLE = 1`
- `Makefile`: `PERF_FETCH_FIFO_ENABLE ?= 1`
- `rtl/lcvex_cluster_top.sv` / SoC / FPGA 顶层均透传 `FETCH_FIFO_ENABLE=1`

## 执行

在独立 worktree 上以 systemd transient service 运行单次完整串行 Gate D，
未使用 `--parallel`。资源限制符合 `MemoryMax=15G`、`MemorySwapMax=0`、
`CPUQuota=50%`、`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1`，一次只跑一个重型任务。

```bash
systemd-run --user --unit=lcvex-t20260902-011-gate-d-serial --wait \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% \
  -p 'Environment=PATH=/home/chiro/miniforge3/bin:/home/chiro/miniforge3/condabin:/usr/local/bin:/usr/bin:/bin' \
  --working-directory=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-011 \
  -E MAKEFLAGS=-j1 -E VERILATOR_JOBS=1 \
  -- /usr/bin/env bash -lc \
  'bash sim/difftest/run_gate_d.sh > build/logs/gate_d_serial.log 2>&1'
```

结果：

- exit code：`0`
- wall：`1h 22min 9.846s`（4929.846 s）
- CPU：`41min 4.949s`（2464.949 s）
- memory peak：`6,062,608,384 B`（约 5.65 GiB，<15G，无 swap）
- 日志：`build/logs/gate_d_serial.log`
- 日志 SHA256：`9cb11f7fd3d6a528e41eb280b28bd583917b7cdbde3308019c26dd7729a6126e`
- `OK(green)` 行：`151`
- `FAIL(red-expected)` 行：`0`
- 顶层 step 数：`45`
- 最终行：`PASS: Gate D 系统回归全部通过`

## Gate D 明细

| Step | 结果 |
| --- | --- |
| `make test（单元 + SVA）` | OK |
| `make coverage（缓存/MMU TB 覆盖率）` | OK |
| `M2-4b/4c 定向锁步（base + 全缓存）` | OK（80/80） |
| `lockstep-build-l1dl2-delay2 构建` | OK |
| `随机 smoke 镜像重新生成` | OK |
| `delay2-cache-*` | OK（31 个定向 + random_smoke） |
| `P5a-Hardening + M2 定向（13 组）` | OK（26/26） |
| `Gate C 异常/EL0-EL1（7 组）` | OK |
| `P5a MMU 数据翻译（3 组）` | OK |
| `P4b 异常/系统指令` | OK |
| `随机回归（seed 1~3 × 100k）` | OK |
| `指令覆盖记账` | OK（期望覆盖集全部命中） |
| `baremetal-C 工具链/镜像` | OK |
| `baremetal-C 锁步` | OK（200 条） |

## T-006 失败用例闭合确认

以下 9 个 T-006 失败用例在本次默认-on Gate D 中全部通过：

| 配置 | 用例 | 本次结果 |
| --- | --- | --- |
| base | hard_timer | PASS（40 条） |
| base | hard_adc_sbc | PASS（30 条） |
| base | hard_sve_probe | PASS（60 条） |
| cache | hard_timer | PASS（40 条） |
| cache | hard_postpre | PASS（70 条） |
| cache | hard_adc_sbc | PASS（30 条） |
| cache | hard_sve_probe | PASS（60 条） |
| delay2 | hard_timer | PASS（40 条） |
| delay2 | hard_postpre | PASS（70 条） |

## CORE_COUNT=1 / l2_cluster lint

Gate D 脚本不包含这两项；另行执行结果均 PASS：

| 命令要点 | 结果 | wall | 日志 |
| --- | --- | --- | --- |
| `verilator --lint-only --no-assert --no-timing -Wall -Wno-fatal -Wno-UNUSEDPARAM --top-module lcvex_cluster_top -GCORE_COUNT=1 -f rtl/filelist.f rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv` | PASS（既有 benign warnings） | 23s | `build/logs/core_count_1_cluster_lint.log` |
| `verilator --lint-only --no-assert --no-timing -Wall -Wno-fatal -Wno-UNUSEDPARAM --top-module lcvex_l2_cluster -GCORE_COUNT=1 -GMEM_LINES=16 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv` | PASS（既有 UNSIGNED warning） | 1s | `build/logs/core_count_1_l2_cluster_lint.log` |

## 证据

- 主任务 evidence：`docs/tasks/evidence/T-20260902-011.json`
- 完整 Gate D 日志：`build/logs/gate_d_serial.log`
- 本次未运行 Linux 长跑、CI、Quartus、FPGA 上板或性能矩阵。

## 风险与下一步

- 默认-on F1a 的完整 Gate D 已闭合，可以评估将 `FETCH_FIFO_ENABLE=1`
  作为正式默认配置纳入后续集成验收。
- 建议集成者在 main 候选上复跑冻结 Gate D，并保留本 evidence 作为
  T-009 修复的合并后确认。
