# Handoff T-20260902-028: FP-P5 rerun round3 after T-026/T-027

```text
task=T-20260902-028
state=blocked
base=5970ea79eb0178f58cc3038078f63614c40ad40e
head=dac13ff5ed9081cc207f0af356eaef4443b43853
branch=verify/T-20260902-028-fp-p5-rerun-round3
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-028
sent_at=2026-09-03T18:17:00+08:00
received_at=2026-09-03T18:19:29+08:00
reported_at=2026-09-03T19:14:30+08:00
```

## 结论

- 在包含 T-20260902-026（FP shared datapath per-slot register cut）和
  T-20260902-027（EMIF FIFO/reset CDC deep hardening）的合并 SHA
  `5970ea79eb0178f58cc3038078f63614c40ad40e` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL**。
- 因此按任务约束**未运行 assembler/SOF**；远端 probe 确认无
  `.sof/.jic/.rbf/.pof`。
- 相对 T-20260902-025 有重大改善，但仍有红色，未闭合：
  - `sys_clk_50` 最差 setup 从 **-319.497 ns / 834 级 / 339.743 ns** 收敛到
    **-14.432 ns / 61 级 / 34.564 ns**，且 top-1 已离开
    `fp_exec/scalar_unit`，移至 **core 的 MMU fault 组合链**：
    `soc|core|idex_d.inv_b~DUPLICATE` → `soc|core|mmu|fault_fsc_r[2]`。
  - `emif core_usr_clk` setup 仍红 **-6.949 ns**（T-025 -7.051 ns），top-N 为
    async FIFO Gray 指针 sys_clk_50 → EMIF first-stage 同步器路径。
  - `sys_clk_50` hold 仍红 **-6.297 ns**（signoff）/ **-5.767 ns**（自定义
    Slow 100C）；top-1 仍为 `request_fifo|rd_ptr_bin_q[2]` →
    `rd_ptr_gray_wr1_q[2]` 的 EMIF→sys 灰码路径。
  - **recovery / removal / min-pulse / DDR / metastability 全部通过**
    （recovery emif +0.770 ns，removal worst +0.110 ns，min-pulse +0.120 ns，
    DDR Pass）。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲 44,821.3 MB / 总 63,092.3 MB；D: 可用 78.55 GB。
- 确认 `T-20260902-028-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-028-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 项 manifest；远端 SHA-256 全部与本地 staging 一致
  （REMOTE_VERIFY count=52, bad=0）。
- 正式 SDC 使用当前 `fpga/catapult_a10/quartus/catapult_a10.sdc`（包含
  T-027 新增的 reset first-stage false path），QSF 仅替换
  `T-20260902-025-probe` → `T-20260902-028-probe`。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`，与 T-018/T-019/T-022/T-025
  相同。
- 关键输入 SHA-256：
  - `rtl/lcvex_fp_scalar.sv`（正式）：`c9de754bfb627c91fe1ef3d2ed3d3b9b40c6efbc3b58ba57e0d4d4ee8796dba5`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`9953097c55f63fffb877bcb4739c6406247d59e68c2f885589f46b4a470a579d`
  - `rtl/lcvex_axi4_avalon_adapter.sv`：`6b07f793e81ba146c9fa7cbaa4e09deb4b2901790ba9ddd058988f9bec6f08bd`
  - `rtl/lcvex_neon_fp.sv`：`e26620a132f77c38e8ca520e174023f6b170a94045e8f62799deb47f522b368e`
  - `rtl/lcvex_core.sv`：`bcc99194da7c42a8e3f0a931a56207a7f714795580b0557f3a0f1858e9a33b14`
  - `rtl/lcvex_pkg.sv`：`9e176ec9352b354cb1c33c7e27e8a4af55c36faa3db822b176a80271b3edacea`
  - `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`：`a165866e794d688ab5d99792fdcabf84d78b06701696102375faffa30620a191`
  - `fpga/catapult_a10/quartus/catapult_a10.sdc` / probe SDC：
    `0e40fa6fb80372cb25b81f30fb81536895d7e27f364edb90a38a0946c2324b61`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 37 warnings / 0 critical warnings；wall 1244.719 s；
  peak PM 4,645.6 MB / WS 4,432.1 MB / VM 9,536.7 MB。
- 资源（估算）：
  - ALM estimate **143,972**（T-025 203,847）
  - Combinational ALUT 178,959；Dedicated logic registers 83,474
  - Block memory bits 247,272；DSP 27（T-025 45）；PLL 1；I/O pins 144
  - Max fanout 75,835（`sys_clk_div2`）；Total fanout 1,263,395；
    Average LUT depth 28.77（T-025 136.45）
- 关键 hierarchy：
  - `soc|core`：ALUT 120,517 / regs 22,711 / DSP 18
  - `g_fp_simd_enabled.fp_exec`：ALUT 59,435 / regs 3,132 / DSP 6
  - `scalar_unit`：ALUT 57,222 / regs 2,142 / DSP 6
  - `g_iter.it_divider`：ALUT 188 / regs 433
  - `g_iter.it_sqrt`：ALUT 776 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,528 / regs 0
  - `emif_adapter`：ALUT 20,225 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 4 / regs 6

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall 1470.271 s；
  peak PM 11,701.0 MB / WS 11,543.8 MB / VM 19,192.5 MB。
- 资源：
  - Logic utilization ALM **142,389 / 427,200（33%）**（T-025 203,540 / 47.6%）
  - Total registers 85,774；Total pins 141 / 826（17%）
  - Block memory bits 245,608 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 26 / 1,518（2%）；PLL 3 / 112（3%）
- Critical warnings 仍为 9 个引脚无精确 location、48 RX/TX 未使用等同类；无 errors。

### 5. Signoff STA
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start sta_signoff -end sta_signoff`
- 工具进程 exit 0；0 errors / 3 warnings / 1 critical warning（timing not met）。
- **Timing Closure Summary: Fail**
  - Setup Summary Fail；Hold Summary Fail
  - Recovery Summary Pass；Removal Summary Pass
  - Minimum Pulse Width Summary Pass
  - Metastability Summary Pass；**Double Data Rate (DDR) Summary Pass**
- 关键时序（从 `real_a10_full_fp.sta.summary`）：
  - Setup `sys_clk_50`：**-14.432 ns**，TNS -170,475.513，failing endpoints 21,194，Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**-6.949 ns**，TNS -41.533，failing endpoints 6，Slow 900mV 0C
  - Hold `sys_clk_50`：**-6.297 ns**，TNS -6.297，failing endpoints 1，Slow 900mV 0C
  - Hold `emif...core_usr_clk`：+0.019 ns（Fast 0C，通过）
  - Recovery `emif...core_usr_clk`：**+0.770 ns**（通过）
  - Recovery `sys_clk_50`：+3.515 ns（通过）
  - Removal worst：`emif_cal_master_clk` +0.110 ns（通过）；`sys_clk_50` +0.176 ns；
    `emif core_usr_clk` +0.183 ns
  - Minimum pulse width worst：+0.120 ns（通过）
  - Fmax：`sys_clk_50` **29.04 MHz**；`emif...core_usr_clk` 288.93 MHz；
    `emif core_cal_master_clk` 220.41 MHz；`emif core_cal_slave_clk` 328.62 MHz；
    `clk_y3` 579.37 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（sys_clk_50，Slow 900mV 100C）：
  - From `soc|core|idex_d.inv_b~DUPLICATE`
  - To `soc|core|mmu|fault_fsc_r[2]`
  - Slack **-14.432 ns**，data delay **34.564 ns**，**61 逻辑级**，
    无 SDC exception。top-2..10 为同源 MMU fault 路径，slack -14.416..-14.431。
- EMIF setup（Slow 900mV 0C，`-to_clock emif core_usr_clk`）：
  - #1：`soc|emif_adapter|response_fifo|rd_ptr_gray_q[1]` →
    `response_fifo|rd_ptr_gray_wr1_q[1]`，sys_clk_50 → emif core_usr_clk，
    slack **-6.949 ns**，clock skew -6.562 ns，data delay 0.589 ns。
  - #2：`request_fifo|wr_ptr_gray_q[2]` → `request_fifo|wr_ptr_gray_rd1_q[2]`，
    slack -6.946；#3 -6.923；#4 -6.918；#5 -6.910；#6 -6.887。
- Hold top-1（Slow 900mV 100C）：
  - `soc|emif_adapter|request_fifo|rd_ptr_bin_q[2]` →
    `request_fifo|rd_ptr_gray_wr1_q[2]`，emif core_usr_clk → sys_clk_50，
    slack **-5.767 ns**，关系 -0.117，clock skew 6.076，data delay 0.721。
- Recovery top-1：
  - `emif|...|non_hps.core_clks_rsts_inst|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|...|data_reg[3][393]`，same emif core_usr_clk，
    slack **+0.770 ns**（0 violated）。
- Removal top-1：
  - `emif|...|colmaster|rst_controller|...|altera_reset_synchronizer_int_chain_out` →
    `emif|...|transacto|p2m|writedata[6]`，same cal_master_clk，
    slack **+0.396 ns**（0 violated）。

### 7. 未执行
- **assembler/SOF（时序门未通过，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件

## 产出
- `docs/handoffs/T-20260902-028-fp-p5-rerun-round3.md`
- `docs/tasks/evidence/T-20260902-028.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-028-probe\**`
- 本地未提交副本：`build/agents/T-20260902-028/**`（git 忽略）

## 下一步
1. **闭合 `sys_clk_50` setup 新 top：`idex_d.inv_b/operand_b` → `mmu|fault_fsc_r`
   （61 级、34.5 ns）**。这是 T-026 释放 fp_exec 长链后暴露的 core/MMU 组合路径；
   建议对 fault status/PC 构造做寄存器切级或对 ALU 标志生成路径切级。
2. **EMIF async FIFO 灰码交叉 setup 仍红**：当前 SDC 只切了一侧
   （request rd_ptr_gray_q→wr1_q、response wr_ptr_gray_q→rd1_q），缺失
   request wr_ptr_gray_q→rd1_q、response rd_ptr_gray_q→wr1_q 的
   first-stage 约束；但首选继续在 RTL 中硬化双向灰码同步/keep，而不是只补 false_path。
3. **request_fifo hold**（`rd_ptr_bin_q → rd_ptr_gray_wr1_q`）仍负；需检查
   `rd_ptr_bin_q` 是否未经 Gray 编码直接驱动目的域首级同步器，或补真正的
   源域 Gray 寄存器。
4. 修复后重跑同 source/QSF/SDC 的 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
