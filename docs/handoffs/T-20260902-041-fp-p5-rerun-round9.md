# Handoff T-20260902-041: FP-P5 rerun round9 after T-20260902-040 FP MAC->pp_pre_hi product-register cut

```text
task=T-20260902-041
state=blocked
base=cb0980a56ec4a4f036510bc5e04e31cf1186232a
head=edf0514396168f0173b54b0bda9f914f7e684d9a
branch=verify/T-20260902-041-fp-p5-rerun-round9
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-041
sent_at=2026-09-04T03:27:00+08:00
received_at=2026-09-04T03:27:30+08:00
reported_at=2026-09-04T04:54:31+08:00
```

## 结论

- 在包含 T-20260902-040（FP scalar DSP MAC → `pp_pre_hi` product register cut）的合并 SHA
  `cb0980a56ec4a4f036510bc5e04e31cf1186232a` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端隔离 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- **T-040 的定向目标已达成**：T-039 的 `sys_clk_50` setup top-1
  `scalar_unit|mult_1~mac_11~reg0 -> g_iter.pp_pre_hi.sig[*]`
  （-7.685 ns，62 级，27.811 ns）已完全离开 signoff setup top-10；
  setup top-10 中不再出现 `mult_1` / `pp_pre_hi` / `pm_pre` / `product`。
- 但 `sys_clk_50` setup 仍红，且 top-1 转移到 FP 标量 `fp_exec` 的
  **slot_idx -> slot_result_r** 路径：
  - top-1：`soc|core|g_fp_simd_enabled.fp_exec|slot_idx[2]`
    → `soc|core|g_fp_simd_enabled.fp_exec|slot_result_r[26]`
  - slack **-5.200 ns**，data delay **25.478 ns**，**49 逻辑级**，无 SDC exception。
  - `sys_clk_50` 最差 setup 从 T-039 的 **-7.685 ns** 改善到 **-5.200 ns**
    （Fmax 36.12 → **39.68 MHz**），TNS **-28,027.473**，失败端点 **18,739**。
  - top-2..10 为同一 `slot_idx[2] -> slot_result_r[26]` 的重复/相邻位路径，
    slack -5.200..-5.172。
- EMIF/hold/recovery/removal/min-pulse/DDR/metastability 全部保持绿：
  - EMIF `core_usr_clk` setup **+0.222 ns**（TNS 0）
  - hold signoff 最差 **+0.012 ns**（`sys_clk_50`）/ `core_usr_clk` +0.018 ns
  - recovery 最差 **+0.584 ns**（EMIF `core_usr_clk`）/ `sys_clk_50` +2.787 ns
  - removal 最差 **+0.162 ns**（`core_cal_master_clk`）/ `sys_clk_50` +0.201 ns
  - min-pulse **+0.120 ns**
  - DDR Pass，Metastability Pass。
  - EMIF 定向 setup/cross：`core_usr_clk` to/from 最差均 **+0.449 ns**（0 violated）。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 34,783.4 MB / 总 63,092.3 MB；D: 可用约 70.2 GB。
- 确认 `T-20260902-041-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-041-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 个唯一远端目标；远端 SHA-256 全部与本地一致
  （REMOTE_VERIFY count=52, bad=0）。
- QSF 沿用 T-039 隔离工程模板，仅把 probe 路径替换为 `T-20260902-041-probe`；
  正式 SDC 保持 T-030 新增的 Gray CDC 约束（SHA
  `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`）。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与历史 FP-P5 轮次相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_core.sv`：`fdc5571cdb5b8e50001b45789142931941fb45a34d783fa5171e4a4c816b44b8`
  - `rtl/lcvex_decode.sv`：`1b01f3c482db2b5e509899740306806e094ee803b6f18dbe5239e80dfa262edf`
  - `rtl/lcvex_pkg.sv`：`de43ab7118605baa8e8d5c7a2072bcdd1b20bcc0317c4d04d6d7091090faab6b`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`66bf6b198e82a5d5e9b5fb843b78cf432c193404f66fb6f96020078965b1b9da`（见 evidence）
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`ae5d6924e7b041cc3bc12bb4e0b06719fd8ea3b2339f65fc1271e8072e60d438`
  - `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`：`a165866e794d688ab5d99792fdcabf84d78b06701696102375faffa30620a191`
  - `real_a10_full_fp.qsf`：`27d7bcdbe9fc9cc1f9cc131c0a3c31756e7a84f6c4cddc0d67a76dbe3e329401`
  - `real_a10_full_fp.sdc`：`2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - 本地 manifest：`build/agents/T-20260902-041/sync/manifest_t041.json`
    SHA-256 `d323ef902535235ecfc30e506b231c946847e19278e8cd7531613cbde8789407`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 230 warnings / 0 critical warnings；wall **2757.522 s**；
  peak PM **8,891.6 MB** / WS 8,122.0 MB / VM 13,699.0 MB。
- 资源（估算）：
  - ALM estimate **152,512**（root partition）
  - Combinational ALUT **194,552**；Dedicated logic registers **86,066**
  - Block memory bits 247,272；DSP **186**；PLL 1；I/O pins 144
  - Max fanout 78,430（`sys_clk_div2`）；Total fanout 1,321,598；
    Max LUT depth 75.20；Average LUT depth 22.85
- 关键 hierarchy：
  - `soc|core`：ALUT 136,126 / regs 25,306 / DSP 177
  - `g_fp_simd_enabled.fp_exec`：ALUT 77,518 / regs 5,727 / DSP 165
  - `scalar_unit`：ALUT 75,504 / regs 4,737 / DSP 165
  - `g_iter.it_divider`：ALUT 203 / regs 433
  - `g_iter.it_sqrt`：ALUT 777 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,528 / regs 0
  - `soc|core|mmu`：ALUT 3,673 / regs 5,972
  - `emif_adapter`：ALUT 20,222 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 3 / regs 6
- 注：T-040 在 `scalar_unit` 增加 `pm_pre*` 后，synthesis 寄存器由 T-039 的
  85,254 增至 **86,066**；DSP 仍为 186。

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall **1879.951 s**；
  peak PM **11,393.2 MB** / WS **11,232.9 MB** / VM **18,520.4 MB**。
- 资源：
  - Logic utilization ALM **150,451 / 427,200（35%）**
  - Total registers **88,869**；Total pins 141 / 826（17%）
  - Block memory bits 245,608 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 186 / 1,518（12%）；PLL 3 / 112（3%）
- Critical warnings 同历史：9 个引脚无精确 location、48 RX/TX 未使用等。
- 注：T-040 的 `pm_pre*` 寄存器使 fitter 总寄存器从 T-039 的 87,729 增至 **88,869**。

### 5. Signoff STA
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start sta_signoff -end sta_signoff`
- 工具进程 exit 0；0 errors / 3 warnings；Timing Closure Summary = Fail。
- **Timing Closure Summary（BETA）**：
  - Setup Summary **Fail**
  - Hold Summary **Pass**
  - Recovery Summary **Pass**
  - Removal Summary **Pass**
  - Minimum Pulse Width Summary **Pass**
  - Metastability Summary **Pass**
  - Double Data Rate (DDR) Summary **Pass**
- 关键 signoff 数字：
  - Setup `sys_clk_50`：**-5.200 ns**，TNS **-28,027.473**，失败端点 **18,739**，
    Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.222 ns**（全绿，TNS 0）
  - Hold `sys_clk_50`：**+0.012 ns**；`emif...core_usr_clk`：**+0.018 ns**
  - Recovery `emif...core_usr_clk`：**+0.584 ns**；`sys_clk_50` +2.787 ns
  - Removal 最差 `emif...core_cal_master_clk`：**+0.162 ns**；`clk_y3` +0.165 ns；
    `emif...core_usr_clk` +0.177 ns；`sys_clk_50` +0.201 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **39.68 MHz**；`emif...core_usr_clk` 283.45 MHz；
    `emif...core_cal_master_clk` 205.17 MHz；`emif...core_cal_slave_clk` 336.02 MHz；
    `clk_y3` 499.5 MHz
- 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）：
  - Setup top-1（Slow 900mV 100C）：
    - From `soc|core|g_fp_simd_enabled.fp_exec|slot_idx[2]`
    - To `soc|core|g_fp_simd_enabled.fp_exec|slot_result_r[26]`
    - Slack **-5.200 ns**，data delay **25.478 ns**，**49 逻辑级**，
      无 SDC exception。top-2..10 也是 `slot_idx[2]` → `slot_result_r[26]`
      的重复/相邻位，slack -5.200..-5.172。
    - **T-039 目标路径 `mult_1~mac_11~reg0 -> g_iter.pp_pre_hi.sig[*]`
      未出现在 setup top-10。**
  - Hold top-1：
    - `sfl_inst|epcq|epcq|asmi_parallel_inst|altera_asmi_parallel_epcq_epcq|wrstage_cntr|auto_generated|dffe2a[1]`
      → 同点，slack **+0.072 ns**（0 violated），`sys_clk_50 (INVERTED)`。
  - Recovery top-1：
    - `emif|...|reset_sync_pri_sdc_anchor` →
      `emif|...|io_hmc_ecc_inst|pending_data[0][211]`，
      slack **+0.584 ns**（0 violated），`core_usr_clk`。
  - Removal top-1：
    - `emif|...|jtag_phy...|clock_sense_reset_n_synchronizer|dreg[6]` →
      `emif|...|jtag_streaming|clock_sensor`，
      slack **+0.403 ns**（0 violated），`core_cal_master_clk`。
  - EMIF 定向 setup top-1：`internal_master_rd_data[159]` →
    `decoder_output_data[165]`，slack **+0.449 ns**（0 violated）。
  - EMIF cross to/from `core_usr_clk` 也全绿：to 最差 **+0.449 ns**，
    from 最差 **+0.449 ns**。

### 6. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof/.jbc`

## 产出
- `docs/handoffs/T-20260902-041-fp-p5-rerun-round9.md`
- `docs/tasks/evidence/T-20260902-041.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-041-probe\**`
- 本地未提交副本：`build/agents/T-20260902-041/**`（git 忽略）

## 下一步
1. 闭合新的 `sys_clk_50` setup top：FP `fp_exec`
   `slot_idx[2] -> slot_result_r[26]`（49 逻辑级、25.478 ns、-5.200 ns）。
   该路径从 `slot_idx` 经 `slot_c/slot_a`、`scalar_unit` 的
   `reduce_or/reduce_nor/Select` 等组合锥到 `slot_result_r`，是 T-040 未覆盖的
   DSP 乘积级之外的另一条 FP 标量 slot 结果捕获路径。
   建议：
   - 在 `fp_exec` 的 slot 组合结果（如 `slot_c/slot_a`）到 `slot_result_r`
     之间再切一级；或把 `slot_idx` 对 `slot_result` 的控制/合法性前缀提前寄存。
   - 保持 T-032/T-034/T-036/T-038/T-040 已切成果，不要回退；不要用
     SDC false_path 掩盖同域 setup。
2. 保持 EMIF/hold/recovery/removal/min-pulse/DDR 的绿色成果。
3. 修复后按同 source/QSF/SDC 重跑 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
