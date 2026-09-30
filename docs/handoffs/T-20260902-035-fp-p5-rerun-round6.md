# Handoff T-20260902-035: FP-P5 rerun round6 after T-20260902-034 FP pre-round iterative cut

```text
task=T-20260902-035
state=blocked
base=9792255db13547a628f8bcc5f9688f64e3b40a64
head=33089cf4b0ca78608612bf3c510278ab4a9a6cf2
branch=verify/T-20260902-035-fp-p5-rerun-round6
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-035
sent_at=2026-09-03T22:28:00+08:00
received_at=2026-09-03T22:28:30+08:00
reported_at=2026-09-03T23:28:30+08:00
```

## 结论

- 在包含 T-20260902-034（FP pre-round iterative cut）的合并 SHA
  `9792255db13547a628f8bcc5f9688f64e3b40a64` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- T-034 的预期目标已达成：旧的 `sys_clk_50` setup top-1
  `fp_exec|req_r.kind[1] -> scalar_unit|g_iter.pp_pre.sig[120]`
  （T-033：-8.734 ns，54 级，28.908 ns）已完全离开 signoff setup top-10。
- 但 `sys_clk_50` setup 仍红，且暴露出新的核心 ID/EX 关键路径：
  - top-1：`soc|core|idex_d.operand_b[7]~DUPLICATE`
    → `soc|core|idex_d.next_pc[9]`
  - slack **-8.192 ns**，data delay **28.022 ns**，**45 逻辑级**，无 SDC exception。
  - T-034 只是把最差路径从 FP 标量预舍入转移到 ID/EX 操作数到 next_pc/原子比较
    的组合锥；`sys_clk_50` 最差 slack 从 -8.734 改善到 **-8.192 ns**
    （Fmax 34.8 → **35.47 MHz**），但仍未闭合。
- EMIF/hold/recovery/removal/min-pulse/DDR/metastability 全部保持绿：
  - EMIF `core_usr_clk` setup +0.291 ns（TNS 0）
  - hold signoff 最差 +0.018 ns（`sys_clk_50`）/ +0.021 ns（EMIF）
  - recovery +0.561 ns（EMIF）
  - removal `sys_clk_50` +0.191 ns / EMIF +0.198 ns / 全局最差 +0.144 ns
  - min-pulse +0.120 ns
  - DDR Pass，Metastability Pass。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 44,807.5 MB / 总 63,092.3 MB；D: 可用约 74.5 GB。
- 确认 `T-20260902-035-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-035-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 个唯一远端目标；远端 SHA-256 全部与本地一致
  （REMOTE_VERIFY count=52, bad=0）。
- 正式 QSF/SDC 取自当前 worktree；QSF 仅把 probe 路径替换为
  `T-20260902-035-probe`。正式 SDC 保持 T-030 新增的 Gray CDC 约束。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与历史 FP-P5 轮次相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_core.sv`：`e261d8a3604d97e1d9b31bc1ec7f1ce20fb52b4dc72c6eb34b1679c8d2eee722`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`cc5354f446c24467bbf24152f6b7e240cdf606f7d707100fda1a9eb1d47e20b5`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`d3f5f53061fa53862b640fd41a4e0929d524a5dbc56703079f3934b9d53946ac`
  - `fpga/catapult_a10/quartus/catapult_a10.sdc`（T-035 工程内镜像）：`2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - 本地 manifest：`build/agents/T-20260902-035/sync/manifest_t035.json`
    SHA-256 `1649572e4ca36dd276c0514d171dbc5c69411ec05a9af499c025fb5c41878b3d`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 230 warnings / 0 critical warnings；wall 1278.599 s；
  peak PM 4,924.3 MB / WS 4,701.1 MB / VM 9,815.9 MB。
- 资源（估算）：
  - ALM estimate **153,825**（root partition）
  - Combinational ALUT 197,687；Dedicated logic registers 84,363
  - Block memory bits 247,272；DSP **186**；PLL 1；I/O pins 144
  - Max fanout 76,727（`sys_clk_div2`）；Total fanout 1,327,672；
    Max LUT depth 78.40；Average LUT depth 24.10
- 关键 hierarchy：
  - `soc|core`：ALUT 139,251 / regs 23,603 / DSP 177
  - `g_fp_simd_enabled.fp_exec`：ALUT 78,308 / regs 4,024 / DSP 165
  - `scalar_unit`：ALUT 76,171 / regs 3,034 / DSP 165
  - `g_iter.it_divider`：ALUT 235 / regs 433
  - `g_iter.it_sqrt`：ALUT 791 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,529 / regs 0
  - `soc|core|mmu`：ALUT 3,674 / regs 5,972
  - `emif_adapter`：ALUT 20,226 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 3 / regs 6
- 注：T-034 切级后 DSP 估算从 T-033 的 27 上升到 186（多数在 FP scalar，
  fitter 后仍为 186），需要后续评估该面积/乘法器推断变化。

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall 1582.8 s；
  peak PM 11,586.8 MB / WS 11,422.2 MB / VM 18,539.6 MB。
- 资源：
  - Logic utilization ALM **152,293 / 427,200（36%）**
  - Total registers 87,168；Total pins 141 / 826（17%）
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
  - Setup `sys_clk_50`：**-8.192 ns**，TNS -110,110.503，Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.291 ns**（全绿，TNS 0）
  - Hold `sys_clk_50`：**+0.018 ns**（Fast 900mV 0C）
  - Hold `emif...core_usr_clk`：**+0.021 ns**（Fast 900mV 0C）
  - Recovery `emif...core_usr_clk`：**+0.561 ns**；`sys_clk_50` +2.576 ns
  - Removal `sys_clk_50`：**+0.191 ns**；`emif...core_usr_clk` +0.198 ns；
    全局最差 `emif...core_cal_master_clk` +0.144 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **35.47 MHz**；`emif...core_usr_clk` 289.1 MHz；
    `emif...core_cal_master_clk` 192.46 MHz；`emif...core_cal_slave_clk` 320.92 MHz；
    `clk_y3` 499.75 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（Slow 900mV 100C）：
  - From `soc|core|idex_d.operand_b[7]~DUPLICATE`
  - To `soc|core|idex_d.next_pc[9]`
  - Slack **-8.192 ns**，data delay **28.022 ns**，**45 逻辑级**，
    无 SDC exception。该路径位于核心 ID/EX 操作数 -> next_pc / 原子比较的
    组合锥；top-2..10 也是同一源到 `next_pc`/`atomic_cmp2`，slack -8.192..-8.179。
  - **T-034 目标路径 `fp_exec|req_r.kind -> scalar_unit|g_iter.pp_pre.sig`
    未出现在 setup top-10。**
- Hold top-1（自定义 Slow 900mV 100C）：
  - `sfl_inst|epcq|...|read_dout_reg[5]` →
    `sfl_inst|epcq|...|read_dout_reg[6]`，slack **+0.076 ns**（0 violated），
    `sys_clk_50 (INVERTED)`，EPCQ 读数据寄存器间 hold。
- Recovery top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|core|ecc|internal_master_wr_data[444]`，
    slack **+0.561 ns**（0 violated）。
- Removal top-1：
  - `emif|...|jtag_phy...|clock_sense_reset_n_synchronizer|dreg[6]` →
    `emif|...|jtag_streaming|clock_sensor`，
    slack **+0.372 ns**（0 violated）。
- EMIF 定向 setup top-1：`internal_master_rd_data[165]` →
  `decoder_output_data[134]`，slack **+0.471 ns**（0 violated）。

### 7. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof/.jbc`

## 产出
- `docs/handoffs/T-20260902-035-fp-p5-rerun-round6.md`
- `docs/tasks/evidence/T-20260902-035.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-035-probe\**`
- 本地未提交副本：`build/agents/T-20260902-035/**`（git 忽略）

## 下一步
1. 闭合新的 `sys_clk_50` setup top：核心 ID/EX `operand_b[7]` →
   `idex_d.next_pc` / `atomic_cmp2`（45 逻辑级、28.022 ns、-8.192 ns）。
   建议：
   - 检查 ID/EX 到 next_pc / atomic 比较器的组合锥；这是 ALU/分支/原子操作
     结果计算或 next-pc mux 的共享路径，可在 operand 输入或 next_pc 生成处
     增加寄存器/切级。
   - 同时评估 T-034 后 FP scalar DSP 从 27 增至 186 是否可接受；若该资源/时序
     代价需回退，需先做 PPA 权衡。
2. 保持 T-032 的 ID/EX GPR 前递切级、T-034 的 FP pre-round 切级和 EMIF 闭合成果；
   不要用 SDC false_path 掩盖同域 setup。
3. 修复后按同 source/QSF/SDC 重跑 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
