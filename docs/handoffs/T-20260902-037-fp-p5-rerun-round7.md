# Handoff T-20260902-037: FP-P5 rerun round7 after T-20260902-036 core next_pc/atomic forwarding cut

```text
task=T-20260902-037
state=blocked
base=ac6f1154f4bd763024e2b6bdfd4086018c7365b6
head=16c1ac7b7f1623e9666cbe832b47c9f024fce15e
branch=verify/T-20260902-037-fp-p5-rerun-round7
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-037
sent_at=2026-09-04T00:02:00+08:00
received_at=2026-09-04T00:02:30+08:00
reported_at=2026-09-04T01:05:00+08:00
```

## 结论

- 在包含 T-20260902-036（core remaining ID/EX SP/NZCV/wb3 forwarding cut）的合并 SHA
  `ac6f1154f4bd763024e2b6bdfd4086018c7365b6` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端隔离 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- T-036 的预期目标已达成：T-035 的 `sys_clk_50` setup top-1
  `idex_d.operand_b[7] -> idex_d.next_pc[9]`（-8.192 ns，45 级，28.022 ns）
  **已完全离开 signoff setup top-10**，不再出现 `idex_d.operand_b` /
  `next_pc` / `atomic_cmp2` 关键路径。
- 但 `sys_clk_50` setup 仍红，且 top-1 转移到 FP 标量 `scalar_unit` 的
  pre-round/迭代数据路径：
  - top-1：`soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_other.pa.exp2[1]`
    → `soc|core|g_fp_simd_enabled.fp_exec|slot_result_r[13]`
  - slack **-6.207 ns**，data delay **26.489 ns**，**51 逻辑级**，无 SDC exception。
  - `sys_clk_50` 最差 setup 从 T-035 的 **-8.192 ns** 改善到 **-6.207 ns**
    （Fmax 35.47 → **38.16 MHz**），但仍未闭合。
  - top-2..10 为同一 FP scalar `g_iter.pp_other` → `slot_result_r[13]`
    的重复/相邻位路径，slack -6.207..-6.099。
- EMIF/hold/recovery/removal/min-pulse/DDR/metastability 全部保持绿：
  - EMIF `core_usr_clk` setup **+0.251 ns**（TNS 0）
  - hold signoff 最差 **+0.014 ns**（`emif...core_usr_clk`）/ +0.016 ns（`sys_clk_50`）
  - recovery **+0.510 ns**（EMIF）/ `sys_clk_50` +2.847 ns
  - removal 全局最差 **+0.140 ns**（`clk_y3`）/ `sys_clk_50` +0.169 ns /
    EMIF `core_usr_clk` +0.224 ns
  - min-pulse **+0.120 ns**
  - DDR Pass，Metastability Pass。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 44,558.7 MB / 总 63,092.3 MB；D: 可用约 73.1 GB。
- 确认 `T-20260902-037-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-037-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 个唯一远端目标；远端 SHA-256 全部与本地一致
  （REMOTE_VERIFY count=52, bad=0）。
- QSF 沿用 T-035 隔离工程模板，仅把 probe 路径替换为 `T-20260902-037-probe`；
  正式 SDC 保持 T-030 新增的 Gray CDC 约束（当前 SHA
  `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`）。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与历史 FP-P5 轮次相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_core.sv`：`fdc5571cdb5b8e50001b45789142931941fb45a34d783fa5171e4a4c816b44b8`
  - `rtl/lcvex_decode.sv`：`1b01f3c482db2b5e509899740306806e094ee803b6f18dbe5239e80dfa262edf`
  - `rtl/lcvex_pkg.sv`：`de43ab7118605baa8e8d5c7a2072bcdd1b20bcc0317c4d04d6d7091090faab6b`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`cc5354f446c24467bbf24152f6b7e240cdf606f7d707100fda1a9eb1d47e20b5`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`d3f5f53061fa53862b640fd41a4e0929d524a5dbc56703079f3934b9d53946ac`
  - `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`：`a165866e794d688ab5d99792fdcabf84d78b06701696102375faffa30620a191`
  - `real_a10_full_fp.qsf`：`57d0c2a45498a0fe929c08b1a7f1dad9dbc2e8b7b7c14608c12829f73704d218`
  - `real_a10_full_fp.sdc`：`2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - 本地 manifest：`build/agents/T-20260902-037/sync/manifest_t037.json`
    SHA-256 `4f1f9a6f02ec3737f9933a689fddf85b2c00116ab66d2e1085fc60497fd1d5cc`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 0 critical warnings；wall 1277.060 s；
  peak PM 4,917.1 MB / WS 4,690.9 MB / VM 9,797.9 MB。
- 资源（估算）：
  - ALM estimate **153,219**（root partition）
  - Combinational ALUT 195,240；Dedicated logic registers 84,363
  - Block memory bits 247,272；DSP **186**；PLL 1；I/O pins 144
  - Max fanout 76,727（`sys_clk_div2`）；Total fanout 1,317,323；
    Max LUT depth 78.40；Average LUT depth 23.52
- 关键 hierarchy：
  - `soc|core`：ALUT 136,790 / regs 23,603 / DSP 177
  - `g_fp_simd_enabled.fp_exec`：ALUT 78,172 / regs 4,024 / DSP 165
  - `scalar_unit`：ALUT 76,062 / regs 3,034 / DSP 165
  - `g_iter.it_divider`：ALUT 235 / regs 433
  - `g_iter.it_sqrt`：ALUT 790 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,528 / regs 0
  - `soc|core|mmu`：ALUT 3,669 / regs 5,972
  - `emif_adapter`：ALUT 20,244 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 3 / regs 6
- 注：T-034 后 DSP 仍为 186；T-036 核心切级没有显著改变 DSP。

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 10 warnings / 3 critical warnings；wall 1560.485 s；
  peak PM 12,492.0 MB / WS 12,324.9 MB / VM 20,010.3 MB。
- 资源：
  - Logic utilization ALM **151,350 / 427,200（35%）**
  - Total registers 87,077；Total pins 141 / 826（17%）
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
  - Setup `sys_clk_50`：**-6.207 ns**，TNS -44,998.396，失败端点 19,794，
    Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.251 ns**（全绿，TNS 0）
  - Hold `emif...core_usr_clk`：**+0.014 ns**；`sys_clk_50`：**+0.016 ns**
    （Fast 900mV 0C）
  - Recovery `emif...core_usr_clk`：**+0.510 ns**；`sys_clk_50` +2.847 ns
  - Removal 全局最差 `clk_y3`：**+0.140 ns**；`sys_clk_50` +0.169 ns；
    `emif...core_usr_clk` +0.224 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **38.16 MHz**；`emif...core_usr_clk` 285.8 MHz；
    `emif...core_cal_master_clk` 186.88 MHz；`emif...core_cal_slave_clk` 329.16 MHz；
    `clk_y3` 527.7 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（Slow 900mV 100C）：
  - From `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_other.pa.exp2[1]`
  - To `soc|core|g_fp_simd_enabled.fp_exec|slot_result_r[13]`
  - Slack **-6.207 ns**，data delay **26.489 ns**，**51 逻辑级**，
    无 SDC exception。top-2..10 也是 FP scalar `g_iter.pp_other` →
    `slot_result_r[13]` 的重复/相邻位，slack -6.207..-6.099。
  - **T-035 目标路径 `idex_d.operand_b -> idex_d.next_pc/atomic_cmp2`
    未出现在 setup top-10。**
- Hold top-1：
  - `emif|...|io_hmc_ecc_interface_fifo_inst|data_reg[0][343]` →
    `emif|...|io_hmc_ecc_inst|internal_master_rd_data[326]`，
    slack **+0.080 ns**（0 violated），1 逻辑级，EMIF 内部 ECC 数据路径。
- Recovery top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|core|ecc|io_hmc_ecc_inst|int_encoder_output_data_byte_enable[0]`，
    slack **+0.510 ns**（0 violated）。
- Removal top-1：
  - `emif|...|use_counter_lock.counter_lock_gen_master.pll_ref_clk_reset_n_sync_rrr` →
    `emif|...|use_counter_lock.counter_lock_gen_master.cpa_count_to_lock[6]`，
    slack **+0.359 ns**（0 violated），`clk_y3`。
- EMIF 定向 setup top-1：`emif|...|io_hmc_ecc_inst|int_master_wr_data[522]` →
  `emif|...|ecc_core|core|ecc|internal_master_wr_data[522]`，
  slack **+0.398 ns**（0 violated）。
- EMIF cross to/from `core_usr_clk` 也全绿：to 最差 **+0.375 ns**，
  from 最差 **+0.398 ns**。

### 7. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof/.jbc`

## 产出
- `docs/handoffs/T-20260902-037-fp-p5-rerun-round7.md`
- `docs/tasks/evidence/T-20260902-037.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-037-probe\**`
- 本地未提交副本：`build/agents/T-20260902-037/**`（git 忽略）

## 下一步
1. 闭合新的 `sys_clk_50` setup top：FP 标量
   `g_iter.pp_other.pa.exp2[1] -> slot_result_r[13]`
   （51 逻辑级、26.489 ns、-6.207 ns）。
   建议：
   - 检查 `scalar_unit` 的 `pp_other.pa` / `pp_pre` 到 `slot_result_r`
     的组合锥，是否可在 FP 标量 slot result 寄存前对 `pp_other`/预舍入
     输出做一步切级，或进一步拆分 `g_iter` 的迭代/round 数据路径。
   - 保持 T-032/T-034/T-036 的核心与 FP 已切成果，不要回退 ID/EX 前递切级。
   - 同时评估 T-034 后 DSP 186 / FP scalar 面积是否可接受。
2. 保持 EMIF/hold/recovery/removal/min-pulse/DDR 的绿色成果；不要用
   SDC false_path 掩盖同域 setup。
3. 修复后按同 source/QSF/SDC 重跑 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
