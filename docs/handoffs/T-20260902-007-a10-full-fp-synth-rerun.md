# Handoff T-20260902-007：A10 Full-FP Synthesis Rerun

```text
task=T-20260902-007
state=review
base=335d75a4c6a49760fe55b0b744477456b26a5847
head=d0439d6d6e8d3002c311f8c5d368389e3cc28695
branch=verify/T-20260902-007-a10-full-fp-synth-rerun
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-007
sent_at=2026-09-02T13:05:00+08:00
received_at=2026-09-02T13:03:55+08:00
reported_at=2026-09-02T15:14:40+08:00
```

## 摘要

在远端隔离 probe `D:\Projects\fpga-altra\lcvex\build\T-20260902-007-probe\real_a10_full_fp` 中重跑 T-004 修复后的真实 SoC full-FP synthesis（`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`，未设 `A64_FP_SIMD=0`，candidate 顶层默认 `A64_FP_SIMD=1`、L2 64x1）。

- **T-004 as-is 第一次运行 FAIL**：`lcvex_neon_int.sv` 只保护了 64-bit lane index，Quartus 21.4 在 32-bit `set_lane` 处仍报 `index 128 out of range`；elaboration 阶段 70.6s 失败，未进入资源综合。
- **隔离 probe 补丁后第二次运行 PASS**：为继续取得资源数据，在远端 probe 内对 `lcvex_neon_int.sv` 的 `set_lane`/`lane_unsigned` 增加与 T-001 简易补丁一致的全 lane-width 钳位（8/16/32/64-bit）。仓库内 RTL 未修改（本任务写集不含 rtl）。
- 第二次运行 **0 errors / 38 warnings**，wall 7275.16 s，峰值 PM 12,618.9 MB，未触发安全停止，成功产出最终 synthesis 报告。

## 运行结果

| run | 结果 | wall_s | 峰值 PM MB | 峰值 WS MB | 峰值 VM MB | exit | errors/warnings |
|---|---:|---:|---:|---:|---:|---|
| T-004 as-is | FAIL elaboration | 70.555 | 2,283.4 | 2,276.0 | 7,038.7 | 3 | 1 x index128 out-of-range / 20 warnings |
| + probe lane clamp | PASS | 7,275.16 | 12,618.9 | 12,248.3 | 17,632.1 | 0 | 0 / 38 |

## Full-FP 最终资源估计

| 指标 | 值 |
|---|---|
| Estimate of Logic utilization (ALMs needed) | 493,378 |
| Combinational ALUT usage for logic | 731,869 |
| Dedicated logic registers | 80,715 |
| I/O pins | 144 |
| Total MLAB memory bits | 0 |
| Total block memory bits | 247,276 |
| Total DSP Blocks | 186 |
| Total PLLs | 1 |
| 报告 | `real_a10_full_fp.syn.rpt`（4,075,077 bytes） |
| 摘要 | `real_a10_full_fp.syn.summary` |

## 资源门限结论

- 本次 full-FP synthesis 峰值 PM **12.62 GB**，低于当前 host 安全窗口（preflight 48.56 GB；monitor 后期安全窗口 41.33 GB）。
- 第一资源结论：full-FP 最终综合可完成，资源不是阻断；但逻辑规模非常大（ALM ~493k，DSP 186），后续 fitter/STA 需要单作业逐阶段确认。
- 对比 T-001 no-FP：ALM 81,552 / DSP 21 / regs 78,917；full-FP 的 ALM 和 DSP 显著增加。

## 边界

- 只运行到 synthesis；未运行 fit/STA/assembler/SOF/JIC/编程。
- 未修改 candidate 原工程；所有实验在 `D:\Projects\fpga-altra\lcvex\build\T-20260902-007-probe\**`。
- 未读取 license；未停止非 EDA 进程；未删除文件。
- 仓库内 `rtl/lcvex_neon_int.sv` 仍缺少全 lane-width 钳位；本次成功使用的是远端 probe-only 补丁。后续需将等价修复合入正式 RTL，否则正式 RTL 在 Quartus 21.4 仍会 elaboration 失败。

## 下一步

1. 将 `lcvex_neon_int.sv` 的 `set_lane`/`lane_unsigned` 全 lane-width 钳位（或等价保护）合入仓库，跑 Verilator/lint。
2. 在合并 SHA 上复跑真实 full-FP synthesis，确认正式 RTL 可直接产出最终资源报告。
3. 成功后按单阶段队列进入 fitter → STA → assembler/SOF；由于 full-FP ALM 约 49 万，fitter 阶段需单作业并采样，避免并行。

## 证据

- `docs/tasks/evidence/T-20260902-007.json`
- 远端 `D:\Projects\fpga-altra\lcvex\build\T-20260902-007-probe\**`
