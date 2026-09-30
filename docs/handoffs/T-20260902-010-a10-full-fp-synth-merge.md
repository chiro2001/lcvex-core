# Handoff T-20260902-010：A10 Full-FP Synthesis on T-008 Merge SHA

```text
task=T-20260902-010
state=review
base=87777425e0a23c65763b847d39a2074f9bc77962
head=87777425e0a23c65763b847d39a2074f9bc77962
branch=verify/T-20260902-010-a10-full-fp-synth-merge
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-010
sent_at=2026-09-02T18:27:30+08:00
received_at=2026-09-02T18:28:00+08:00
reported_at=2026-09-02T20:35:00+08:00
```

## 摘要

在远端隔离 probe `D:\Projects\fpga-altra\lcvex\build\T-20260902-010-probe\real_a10_full_fp` 中，使用包含
T-20260902-008 全 lane-width 钳位的仓库正式 RTL（本地 SHA `87777425e0a23c65763b847d39a2074f9bc77962`）
重跑真实 SoC full-FP synthesis：

`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`

未设置 `A64_FP_SIMD=0`，顶层默认 `A64_FP_SIMD=1`、L2 64x1。未使用任何 probe-only RTL 补丁；
远端 `real_a10_full_fp/src` 未再单独覆盖 RTL，QSF 中全部 LCVEX RTL 均指向本 probe 内从当前仓库同步的
`rtl/` 与 `fpga/catapult_a10/rtl/`。

- **正式 RTL 直接通过**：synthesis 成功，0 errors / 38 warnings，未再出现
  `lcvex_neon_int.sv` 的 `index 128 out of range` elaboration 错误。
- **wall 7374.84 s（02:02:54）**，峰值 PM 12,533.1 MB / WS 12,152.4 MB / VM 17,537.0 MB，
  未触发安全停止；最终 synthesis 报告已产出。
- 资源估计：ALM 482,334、ALUT 720,722、registers 80,925、block memory bits 247,276、
  DSP 186、I/O 144、PLL 1。

## 运行结果

| run | 结果 | wall_s | 峰值 PM MB | 峰值 WS MB | 峰值 VM MB | exit | errors/warnings |
|---|---:|---:|---:|---:|---:|---|
| T-008 merge SHA formal RTL | PASS | 7,374.84 | 12,533.1 | 12,152.4 | 17,537.0 | 0 | 0 / 38 |

## Full-FP 最终资源估计

| 指标 | 值 |
|---|---|
| Estimate of Logic utilization (ALMs needed) | 482,334 |
| Combinational ALUT usage for logic | 720,722 |
| Dedicated logic registers | 80,925 |
| I/O pins | 144 |
| Total MLAB memory bits | 0 |
| Total block memory bits | 247,276 |
| Total DSP Blocks | 186 |
| Total PLLs | 1 |
| Maximum fan-out node | sys_clk_div2 |
| Maximum fan-out | 73,291 |
| Total fan-out | 3,513,505 |
| 报告 | `real_a10_full_fp.syn.rpt`（4,012,377 bytes） |
| 摘要 | `real_a10_full_fp.syn.summary` |

## 结论

**正式 RTL 可直接通过 Quartus 21.4 full-FP synthesis**。T-20260902-008 合入的
`rtl/lcvex_neon_int.sv` 全 lane-width lane 钳位已消除此前 T-004 as-is 在
`set_lane` 32-bit 路径上的 `index 128 out of range`，无需再依赖 T-007 的 probe-only
补丁。资源结论与 T-007 probe 成功运行接近（ALM 略低约 1.1 万），full-FP 仍属超大设计，
后续 fitter/STA 必须单阶段单作业。

## 边界

- 只运行到 synthesis；未运行 fit / STA / assembler / SOF / JIC / 编程。
- 未修改 candidate 原工程；所有实验在
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-010-probe\**`。
- 未读取 license；未停止 jtagserver / SlimeVR 等非 EDA 进程；未删除文件。
- 本地与远端 RTL 同步 50 个文件（`rtl/` + `fpga/catapult_a10/rtl/`），SHA-256 全部一致。

## 下一步

1. 集成者验收本 handoff/evidence。
2. 由于 full-FP ALM 约 48.2 万、DSP 186，按单阶段队列进入 fitter → STA → assembler/SOF，
   每阶段独立采样。
3. 若需恢复 P7-2 Cocotb 全绿，另行处理 decode B2c DUP/SQADD 编码重叠（非本任务范围）。

## 证据

- `docs/tasks/evidence/T-20260902-010.json`
- 远端 `D:\Projects\fpga-altra\lcvex\build\T-20260902-010-probe\**`
- 本地约束外证据 `build/agents/T-20260902-010/remote_manifest.json`、
  `build/agents/T-20260902-010/monitor_result.json`、
  `build/agents/T-20260902-010/run_synth_monitor.log`
