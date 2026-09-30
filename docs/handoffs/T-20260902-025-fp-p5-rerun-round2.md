# Handoff T-20260902-025: FP-P5 rerun round2 after T-023/T-024

```text
task=T-20260902-025
state=blocked
base=90c169535caeef3c1aa6be8d53737bc8c3efe947
head=90c169535caeef3c1aa6be8d53737bc8c3efe947
branch=verify/T-20260902-025-fp-p5-rerun-round2
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-025
sent_at=2026-09-03T11:56:00+08:00
received_at=2026-09-03T11:56:31+08:00
reported_at=2026-09-03T13:14:30+08:00
```

## 结论

- 在包含 T-20260902-023（FP-P3T round2 更深切级）和 T-20260902-024（A10 RTL CDC/reset 加固）的合并 SHA 上重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL**。
- 本次仍未通过 FPGA 时序签核，因此按任务约束**未运行 assembler/SOF**；远端 probe 确认未生成 `.sof/.jic/.rbf/.pof`。
- 相比 T-20260902-022：
  - `sys_clk_50` 最差 setup 仍为 **-319.497 ns**（T-022 -315.883 ns），没有闭合；top-1 从 `slot_idx[0]~DUPLICATE` → `rsp_r.v_data[116]`，data delay 339.743 ns / 834 逻辑级，仍落在 `fp_exec/scalar_unit`。
  - `emif core_usr_clk` setup 改善到 **-7.051 ns**（T-022 -7.932）。
  - `sys_clk_50` hold 仍 **-6.568 ns**（T-022 -6.423）。
  - `emif core_usr_clk` recovery 仍 **-7.851 ns**（T-022 -7.846）。
  - `sys_clk_50` recovery/removal 已转正：recovery **+0.454 ns**（T-022 -0.133），removal **+0.150 ns**（T-022 -5.196）；移除类恢复是 T-024 RTL 加固的明显改善。
  - **DDR Summary 已通过**（T-022 为 Fail），但 setup/hold/recovery 仍红，所以总体 Timing Closure 仍 Fail。
- 主要剩余阻断：
  1. `fp_exec/scalar_unit` 的 slot/operand mux → 共享 datapath → response 组合链仍是 `sys_clk_50` 的压倒性 setup 瓶颈（834 级、339.743 ns）。T-023 的切级未打断这条仍在 fp_exec 内部的长链。
  2. EMIF ↔ sys 的异步 FIFO/复位恢复路径仍存在负 hold/recovery，主要是灰码/复位同步器跨 EMIF core_usr_clk 与 sys_clk_50 的路径；T-024 已解决 removal/sys recovery，但未闭合这些点。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5 (GAMEPC)，Shell 使用 `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（保持不动）。
- 物理空闲 43,149.6 MB / 总 63,092.3 MB；D: 可用 80.29 GB。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。
- 首次确认 `T-20260902-025-probe` 不存在，完成后新建隔离 probe。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-025-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件（QSF/QPF/SDC），共 52 项 manifest，SHA-256 全部与本地 staging 一致（REMOTE_VERIFY_OK count=52）。
- 正式 SDC 使用当前 `fpga/catapult_a10/quartus/catapult_a10.sdc`（含 T-021 修复），无需再打 SDC 补丁。
- QSF 沿用 T-022 probe 模板，仅把 `T-20260902-022-probe` 替换为 `T-20260902-025-probe`；Qsys/IP/SFL/JTAG-UART 继续只读引用远端平台源树。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv` 移除输入端口默认值 `iter_kill/iter_pause/kill/pause`，与 T-018/T-019/T-022 相同。
- 关键输入 SHA-256：
  - `rtl/lcvex_fp_scalar.sv`（formal）：`66f60fb97f88c807ca303ae1317964af7851d5c528ab5b3fc44d377a53fde28d`
  - `rtl/lcvex_fp_scalar.sv`（remote patched）：`fb883772dc1442f63e94e1e68be5e511707236cb158c58462c701b760b5bc74a`
  - `rtl/lcvex_axi4_avalon_adapter.sv`：`2e952e4e43919fc0f44b6f2aa4f6f9eb7fc1048a462274b2cc50ea4499e3aef3`
  - `rtl/lcvex_calibration_gate.sv`：`bbdbd4047fa238f31afcfe0d54cdf805d9a3b70f3768f2e096e365a746ff26f0`
  - `rtl/lcvex_core.sv`：`bcc99194da7c42a8e3f0a931a56207a7f714795580b0557f3a0f1858e9a33b14`
  - `rtl/lcvex_pkg.sv`：`9e176ec9352b354cb1c33c7e27e8a4af55c36faa3db822b176a80271b3edacea`
  - `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`：`a165866e794d688ab5d99792fdcabf84d78b06701696102375faffa30620a191`
  - `project/real_a10_full_fp.sdc`：`77014d8e85b3b7236d93a92ba4b4637c782c1ecb24a2b6894abcbda70e2076c7`
  - `project/real_a10_full_fp.qsf`：`c0b81c16b58454c21ef7afbc8c946a754304a0135ad409c7cf8592dc34d2f0b3`
- 未修改正式仓库 RTL/QSF/SDC；未做其它隔离 hack。

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 40 warnings（普通 + 汇总表统计），0 critical warnings；wall 2374.849 s；peak PM 6,089.6 MB / WS 5,720.4 MB / VM 10,992.3 MB。
- 资源（估算）：
  - ALM estimate 203,847；Combinational ALUT 270,247；Dedicated logic registers 83,332
  - Block memory bits 247,276；DSP 45；PLL 1；I/O pins 144
  - Max fanout 75,696（`sys_clk_div2`）；Total fanout 1,671,522
- Hierarchy：
  - `soc|core`：ALUT 213,676 / regs 22,571 / DSP 36
  - `g_fp_simd_enabled.fp_exec`：ALUT 152,928 / regs 2,992 / DSP 24
  - `scalar_unit`：ALUT 151,740 / regs 2,142 / DSP 24
  - `g_iter.it_divider`：ALUT 187 / regs 433
  - `g_iter.it_sqrt`：ALUT 756 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,529 / regs 0

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall 1902.014 s；peak PM 11,948.1 MB。
- 资源：
  - Logic utilization ALM 203,540 / 427,200（48%）
  - Total registers 84,707
  - Total pins 141 / 826（17%）
  - Block memory bits 245,612 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 43 / 1,518（3%）；PLL 3 / 112（3%）
- Critical warnings 与 T-022 同类：9 pins 无精确 location、48 unused RX/TX 等；无 errors。

### 5. Signoff STA
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start sta_signoff -end sta_signoff`
- 工具进程 exit 0；**Timing Closure Summary: Fail**；0 errors / 3 warnings。
- 关键时序：
  - Setup `sys_clk_50`：**-319.497 ns**，TNS -1,462,164.387，Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**-7.051 ns**，TNS -42.064，Slow 900mV 0C
  - Hold `sys_clk_50`：**-6.568 ns**，TNS -60.657，Slow 900mV 0C
  - Hold `emif...core_usr_clk`：+0.019 ns（Fast 0C，通过）
  - Recovery `emif...core_usr_clk`：**-7.851 ns**，TNS -31.176，Slow 900mV 0C
  - Recovery `sys_clk_50`：+0.454 ns（通过）
  - Removal `sys_clk_50`：+0.150 ns（通过）；Removal-wide worst +0.124 ns（通过）
  - Minimum pulse width：worst +0.120 ns（通过）
  - Fmax：`sys_clk_50` 2.95 MHz；`emif...core_usr_clk` 282.97 MHz；`clk_y3` 490.2 MHz
  - Timing Closure BETA：Setup Fail / Hold Fail / Recovery Fail / Removal Pass / Min Pulse Pass / **DDR Pass** / Metastability Pass。
- 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）：
  - Setup #1：`soc|core|g_fp_simd_enabled.fp_exec|slot_idx[0]~DUPLICATE` → `...fp_exec|rsp_r.v_data[116]`，同 `sys_clk_50`，slack -319.497，data delay 339.743 ns，834 逻辑级，无 SDC exception。
  - Hold #1：`soc|emif_adapter|request_fifo|rd_ptr_bin_q[2]` → `request_fifo|rd_ptr_gray_wr1_q[2]`，EMIF core_usr_clk → sys_clk_50，slack -6.105（自定义 Slow 900mV 100C 模型）。
  - Recovery #1：`reset_gate_inst|logic_rst_n_q` → `soc|emif_adapter|emif_rst_sync1_n`，sys_clk_50 → EMIF core_usr_clk，slack -7.404。
  - Removal #1：EMIF 内 reset synchronizer → `...transacto|p2m|address[23]`，same-domain，slack +0.348（无 violated）。

### 6. 未执行
- assembler/SOF（时序门未通过）
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件

## 产出
- `docs/handoffs/T-20260902-025-fp-p5-rerun-round2.md`
- `docs/tasks/evidence/T-20260902-025.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-025-probe\**`
- 本地未提交副本：`build/agents/T-20260902-025/**`（git 忽略）

## 下一步
1. 继续对 `fp_exec/scalar_unit` 的 slot/operand mux → 共享算术/移位 datapath → response mux 做定向寄存器切级。T-023 已将 CMP/MINMAX/FRINT/FP->int 拆到 `pp_other`，但当前 top-1 仍走 `slot_idx -> slot_conv/slot_a -> scalar_unit add/shift` 长链，重点应放在该通用 datapath 上。
2. 对 EMIF async FIFO 灰码跨域 hold（`rd_ptr_bin_q -> rd_ptr_gray_wr1_q`、`response_fifo mem -> cpu_state/read_beat`）和 reset synchronizer recovery（`logic_rst_n_q -> emif_rst_sync*`）继续做真实 CDC/RTL 修复；当前 SDC false_path/exception 未覆盖这些点。
3. 修复后按同一 source/QSF/SDC 重跑 FP-P4（功能/性能）与 FP-P5 synthesis→fitter→STA；只有 setup/hold/recovery/removal/min-pulse 全非负且 DDR 通过时，才允许 assembler/SOF。
