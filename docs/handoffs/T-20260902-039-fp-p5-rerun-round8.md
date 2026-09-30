# Handoff T-20260902-039: FP-P5 rerun round8 after T-20260902-038 FP pp_other->slot_result cut

```text
task=T-20260902-039
state=blocked
base=8b531a5422cb703ae1474bfa66b734e6efdefc15
head=7c564f63b0e093df71bcf5f85548fa8ec6c448bc
branch=verify/T-20260902-039-fp-p5-rerun-round8
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-039
sent_at=2026-09-04T01:34:00+08:00
received_at=2026-09-04T01:34:00+08:00
reported_at=2026-09-04T03:00:30+08:00
```

## 结论

- 在包含 T-20260902-038（FP scalar `pp_other -> slot_result_r` 切级）的合并 SHA
  `8b531a5422cb703ae1474bfa66b734e6efdefc15` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端隔离 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- **T-038 的定向目标已达成**：T-037 的 `sys_clk_50` setup top-1
  `g_iter.pp_other.pa.exp2[1] -> slot_result_r[13]`
  （-6.207 ns，51 级，26.489 ns）已完全离开 signoff setup top-10；
  top-10 中不再出现 `pp_other` / `ot_mid` / `slot_result`。
- 但 `sys_clk_50` setup 仍红，且 top-1 转移到 FP 标量 `scalar_unit` 的
  **DSP 乘法器输出 → pre-round 高位部分积**路径：
  - top-1：`soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|mult_1~mac_11~reg0`
    → `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_pre_hi.sig[153]~DUPLICATE`
  - slack **-7.685 ns**，data delay **27.811 ns**，**62 逻辑级**，无 SDC exception。
  - `sys_clk_50` 最差 setup 从 T-037 的 **-6.207 ns** 略恶化为 **-7.685 ns**
    （Fmax 38.16 → **36.12 MHz**），TNS -65,649.909，失败端点 20,542。
  - top-2..10 为同一 `mult_1~mac_11~reg0` → `g_iter.pp_pre_hi.sig[*]`
    的重复/相邻位路径，slack -7.685..-7.603。
- EMIF/hold/recovery/removal/min-pulse/DDR/metastability 全部保持绿：
  - EMIF `core_usr_clk` setup **+0.190 ns**（TNS 0）
  - hold signoff 最差 **+0.015 ns**（`sys_clk_50`）/ `core_usr_clk` +0.017 ns
  - recovery **+0.505 ns**（EMIF）/ `sys_clk_50` +3.632 ns
  - removal 最差 **+0.159 ns**（EMIF）/ `clk_y3` +0.190 ns / `sys_clk_50` +0.208 ns
  - min-pulse **+0.120 ns**
  - DDR Pass，Metastability Pass。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 31,981.6 MB / 总 63,092.3 MB；D: 可用约 71.5 GB。
- 确认 `T-20260902-039-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-039-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 个唯一远端目标；远端 SHA-256 全部与本地一致
  （REMOTE_VERIFY count=52, bad=0）。
- QSF 沿用 T-037 隔离工程模板，仅把 probe 路径替换为 `T-20260902-039-probe`；
  正式 SDC 保持 T-030 新增的 Gray CDC 约束（SHA
  `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`）。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与历史 FP-P5 轮次相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_core.sv`：`fdc5571cdb5b8e50001b45789142931941fb45a34d783fa5171e4a4c816b44b8`
  - `rtl/lcvex_decode.sv`：`1b01f3c482db2b5e509899740306806e094ee803b6f18dbe5239e80dfa262edf`
  - `rtl/lcvex_pkg.sv`：`de43ab7118605baa8e8d5c7a2072bcdd1b20bcc0317c4d04d6d7091090faab6b`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`ec580179a9611d8f5e7d56255accbf2195a166095b77469283b1dda43a4d96a9`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`7ab4ee54025c84490fdac1b092251a70782365f8df28f8171c7838cb1dbbeee2`
  - `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`：`a165866e794d688ab5d99792fdcabf84d78b06701696102375faffa30620a191`
  - `real_a10_full_fp.qsf`：`21e0b553679b5d74ae2a1fbefab2b6e76968408827e480570f0d45e9af61585c`
  - `real_a10_full_fp.sdc`：`2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - 本地 manifest：`build/agents/T-20260902-039/sync/manifest_t039.json`
    SHA-256 `32b78b2a1055f152b9fb5812c58a4aaf85fdbd657d5f2bf11edcac2b7191d302`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 0 critical warnings；wall **2727.076 s**；
  peak PM **8,838.4 MB** / WS 8,065.4 MB / VM 13,655.3 MB。
- 资源（估算）：
  - ALM estimate **152,170**（root partition）
  - Combinational ALUT **194,611**；Dedicated logic registers **85,254**
  - Block memory bits 247,272；DSP **186**；PLL 1；I/O pins 144
  - Max fanout 77,619（`sys_clk_div2`）；Total fanout 1,316,678；
    Max LUT depth 78.20；Average LUT depth 23.65
- 关键 hierarchy：
  - `soc|core`：ALUT 136,157 / regs 24,495 / DSP 177
  - `g_fp_simd_enabled.fp_exec`：ALUT 77,549 / regs 4,916 / DSP 165
  - `scalar_unit`：ALUT 75,558 / regs 3,926 / DSP 165
  - `g_iter.it_divider`：ALUT 199 / regs 433
  - `g_iter.it_sqrt`：ALUT 777 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,528 / regs 0
  - `soc|core|mmu`：ALUT 3,674 / regs 5,972
  - `emif_adapter`：ALUT 20,243 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 3 / regs 6
- 注：T-038 新增 `ot_mid*` 后 scalar_unit 寄存器由 T-037 的 3,034 增至 **3,926**，
  DSP 仍为 186。

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall **1822.72 s**；
  peak PM **11,489.5 MB** / WS **10,447.5 MB** / VM **18,513.7 MB**。
- 资源：
  - Logic utilization ALM **150,814 / 427,200（35%）**
  - Total registers **87,729**；Total pins 141 / 826（17%）
  - Block memory bits 245,608 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 186 / 1,518（12%）；PLL 3 / 112（3%）
- Critical warnings 同历史：9 个引脚无精确 location、48 RX/TX 未使用等。

### 5. Signoff STA
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start sta_signoff -end sta_signoff`
- 工具进程 exit 0；0 errors / 3 warnings；Timing Closure Summary = Fail。
- **Timing Closure Summary**：
  - Setup Summary **Fail**
  - Hold Summary **Pass**
  - Recovery Summary **Pass**
  - Removal Summary **Pass**
  - Minimum Pulse Width Summary **Pass**
  - Metastability Summary **Pass**
  - Double Data Rate (DDR) Summary **Pass**
- 关键 signoff 数字：
  - Setup `sys_clk_50`：**-7.685 ns**，TNS **-65,649.909**，失败端点 **20,542**，
    Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.190 ns**（全绿，TNS 0）
  - Hold `sys_clk_50`：**+0.015 ns**；`emif...core_usr_clk`：**+0.017 ns**
  - Recovery `emif...core_usr_clk`：**+0.505 ns**；`sys_clk_50` +3.632 ns
  - Removal 最差 `emif...core_usr_clk`：**+0.159 ns**；`clk_y3` +0.190 ns；
    `sys_clk_50` +0.208 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **36.12 MHz**；`emif...core_usr_clk` 280.9 MHz；
    `emif...core_cal_master_clk` 223.96 MHz；`emif...core_cal_slave_clk` 337.72 MHz；
    `clk_y3` 499.25 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（Slow 900mV 100C）：
  - From `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|mult_1~mac_11~reg0`
  - To `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_pre_hi.sig[153]~DUPLICATE`
  - Slack **-7.685 ns**，data delay **27.811 ns**，**62 逻辑级**，
    无 SDC exception。top-2..10 也是 `mult_1~mac_11~reg0` →
    `g_iter.pp_pre_hi.sig[*]` 的重复/相邻位，slack -7.685..-7.603。
  - **T-037 目标路径 `g_iter.pp_other -> slot_result_r` 未出现在 setup top-10。**
- Hold top-1：
  - `emif|...|io_hmc_ecc_interface_fifo_inst|data_reg[3][125]` →
    `emif|...|io_hmc_ecc_inst|internal_master_rd_data[108]`，
    slack **+0.071 ns**（0 violated），1 逻辑级，EMIF 内部 ECC 数据路径。
- Recovery top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|core|ecc|io_hmc_ecc_inst|int_encoder_input_data[3][41]`，
    slack **+0.505 ns**（0 violated），0 逻辑级。
- Removal top-1：
  - `soc|emif_adapter|emif_rst_sync1_n` →
    `soc|emif_adapter|emif_state_q.EMIF_ISSUE`，
    slack **+0.393 ns**（0 violated），0 逻辑级，`core_usr_clk`。
- EMIF 定向 setup top-1：`emif|...|io_hmc_ecc_inst|internal_master_rd_data[398]` →
  `emif|...|ecc_core|core|ecc|io_hmc_ecc_inst|decoder_output_data[380]`，
  slack **+0.424 ns**（0 violated）。
- EMIF cross to/from `core_usr_clk` 也全绿：to 最差 **+0.424 ns**，
  from 最差 **+0.424 ns**。

### 7. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof/.jbc`

## 产出
- `docs/handoffs/T-20260902-039-fp-p5-rerun-round8.md`
- `docs/tasks/evidence/T-20260902-039.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-039-probe\**`
- 本地未提交副本：`build/agents/T-20260902-039/**`（git 忽略）

## 下一步
1. 闭合新的 `sys_clk_50` setup top：FP 标量
   `scalar_unit|mult_1~mac_11~reg0 -> g_iter.pp_pre_hi.sig[*]`
   （62 逻辑级、27.811 ns、-7.685 ns）。
   建议：
   - 检查 `scalar_unit` 的 DSP `mult_1` MAC 输出到 `g_iter.pp_pre_hi`
     pre-round 高位部分积的组合锥；这是 T-038 未覆盖的路径（不是
     `pp_other`/`ot_mid`，也不是 `slot_result_r`）。
   - 可评估把 `mult_1` 的 MAC 输出或 `pp_pre_hi` 的 pre-round 高位再做
     一级中间寄存器；或拆分 DSP MAC 到 `pp_pre_hi` 的组合逻辑。
   - 保持 T-032/T-034/T-036/T-038 已切成果，不要回退 ID/EX 前递切级；
     不要用 SDC false_path 掩盖同域 setup。
2. 保持 EMIF/hold/recovery/removal/min-pulse/DDR 的绿色成果。
3. 修复后按同 source/QSF/SDC 重跑 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
