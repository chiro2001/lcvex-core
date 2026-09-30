# Handoff T-20260902-031: FP-P5 rerun round4 after T-029/T-030

```text
task=T-20260902-031
state=blocked
base=6f6702582bfe1181d018d580867f33245546ef78
head=7bce1ebe7839c1eebfac08840d5bc43437c24b20
branch=verify/T-20260902-031-fp-p5-rerun-round4
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-031
sent_at=2026-09-03T19:40:00+08:00
received_at=2026-09-03T19:40:00+08:00
reported_at=2026-09-03T20:35:30+08:00
```

## 结论

- 在包含 T-20260902-029（Core/MMU fault setup cut）和
  T-20260902-030（EMIF async FIFO gray CDC round2）的合并 SHA
  `6f6702582bfe1181d018d580867f33245546ef78` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- 相对 T-20260902-028 的重大变化：
  - **EMIF async FIFO 灰码路径已闭合**：
    - `emif core_usr_clk` setup 从 **-6.949 ns**（6 个 failing endpoints）
      转为 **+0.211 ns**（全绿）。
    - `sys_clk_50` hold 从 **-6.297 / -5.767 ns**（灰码路径）转为
      **+0.017 ns**（signoff Fast 0C），自定义 Slow 100C top-1 为 **+0.044 ns**。
    - 自定义 EMIF to/from `core_usr_clk` setup top-1 为 **+0.409 ns**（EMIF 内部
      ECC 数据路径），不再有 FIFO 灰码跨域 setup/hold 红项。
  - **Core/MMU fault 目标已离开 `mmu|fault_fsc_r`**：T-029 切级后该路径不再是
    sys_clk_50 setup top-1。新 top-1 变为 **core ALU 结果 → L1 I-cache 响应数据**
    的同域组合长链：
    `soc|core|idex_d.operand_a[13]` → `soc|coh|i_l1|rsp_data_r[18]`，
    slack **-12.446 ns**，data delay **32.334 ns**，**49 逻辑级**。
  - `sys_clk_50` setup 仍红，但已从 T-028 的 **-14.432 ns / 61 级 / 34.564 ns**
    改善到 **-12.446 ns / 49 级 / 32.334 ns**。
  - **recovery / removal / min-pulse / DDR / metastability 全部通过**
    （recovery worst +0.340 ns，removal signoff worst +0.156 ns，
    min-pulse +0.120 ns，DDR Pass，Metastability Pass）。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 44,920 MB / 总 63,092 MB；D: 可用约 77.2 GB。
- 确认 `T-20260902-031-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-031-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 项；远端 SHA-256 全部与本地 staging 一致
  （REMOTE_VERIFY count=52, bad=0）。
- 正式 QSF/SDC 取自当前 worktree；QSF 仅把 probe 路径替换为
  `T-20260902-031-probe`。正式 SDC 包含 T-030 新增的四个 Gray 首级
  false_path/max_delay。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与 T-018/T-019/T-022/T-025/T-028
  相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_mmu.sv`（T-029 后）：`2095d5f12c3b083e4cfd043fcb36e9f6dfccbd377afdb2bbe93b09a70b111df1`
  - `rtl/lcvex_axi4_avalon_adapter.sv`（T-030 后）：`9108a1c5fb8d99b4f42200669f71918418179ff6d99fb2cd44d720a3cd55265d`
  - `fpga/catapult_a10/quartus/catapult_a10.sdc`（T-030 后）：
    `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`c9de754bfb627c91fe1ef3d2ed3d3b9b40c6efbc3b58ba57e0d4d4ee8796dba5`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`9953097c55f63fffb877bcb4739c6406247d59e68c2f885589f46b4a470a579d`
  - 远端 qpf：`6bffe8b352c4b031498165511e4b36523ba127f5a20bac7747d9d1b67d3bb109`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 0 critical warnings；syn.smsg 3；syn.rpt warning-table 15 IDs / 228 次（其中 192 次为 T-030 preserve 属性被 Quartus 21.4 忽略的告警）；wall 1250.614 s；
  peak PM 4,675.4 MB / WS 4,472.3 MB / VM 9,563.4 MB。
- 资源（估算）：
  - ALM estimate **145,769**（T-028 143,972）
  - Combinational ALUT 180,510；Dedicated logic registers 83,471
  - Block memory bits 247,272；DSP 27；PLL 1；I/O pins 144
  - Max fanout 75,835（`sys_clk_div2`）；Total fanout 1,273,827；
    Max LUT depth 79.40；Average LUT depth 26.41（T-028 28.77）
- 关键 hierarchy：
  - `soc|core`：ALUT 122,081 / regs 22,711 / DSP 18
  - `g_fp_simd_enabled.fp_exec`：ALUT 60,990 / regs 3,132 / DSP 6
  - `scalar_unit`：ALUT 58,733 / regs 2,142 / DSP 6
  - `g_iter.it_divider`：ALUT 235 / regs 433
  - `g_iter.it_sqrt`：ALUT 789 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,529 / regs 0
  - `soc|core|mmu`：ALUT 3,691 / regs 5,972
  - `emif_adapter`：ALUT 20,223 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 4 / regs 6

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 8 warnings / 3 critical warnings；wall 1441.896 s；
  peak PM 10,940.4 MB / WS 10,257.3 MB / VM 18,282.5 MB。
- 资源：
  - Logic utilization ALM **143,432 / 427,200（34%）**（T-028 142,389 / 33%）
  - Total registers 85,706；Total pins 141 / 826（17%）
  - Block memory bits 245,608 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 26 / 1,518（2%）；PLL 3 / 112（3%）
- Critical warnings 仍为 9 个引脚无精确 location、48 RX/TX 未使用等同类；无 errors。

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
  - Setup `sys_clk_50`：**-12.446 ns**，TNS -183,275.375，Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.211 ns**（全绿，TNS 0）
  - Hold `sys_clk_50`：**+0.017 ns**（Fast 900mV 0C）
  - Hold `emif...core_usr_clk`：**+0.017 ns**（Fast 900mV 0C）
  - Recovery `emif...core_usr_clk`：**+0.340 ns**；`sys_clk_50` +3.679 ns
  - Removal 最差：`emif...core_cal_master_clk` **+0.156 ns**；`sys_clk_50` +0.178 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **30.82 MHz**；`emif...core_usr_clk` 282.57 MHz；
    `emif...core_cal_master_clk` 252.27 MHz；`emif...core_cal_slave_clk` 321.34 MHz；
    `clk_y3` 512.82 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（Slow 900mV 100C）：
  - From `soc|core|idex_d.operand_a[13]`
  - To `soc|coh|i_l1|rsp_data_r[18]`
  - Slack **-12.446 ns**，data delay **32.334 ns**，**49 逻辑级**，
    无 SDC exception。该路径为 core ALU 结果到 L1 I-cache 响应数据寄存器的
    同域组合长链；top-2..10 为同源 L1 `rsp_data_r` 不同 bit，slack -12.438..-12.446。
- EMIF setup（Slow 900mV 0C，EMIF `core_usr_clk` to/from）：
  - #1：`emif|...|ecc_core|...|internal_master_rd_data[141]` →
    `...|decoder_output_data[114]`，slack **+0.409 ns**（0 violated），
    3 逻辑级，EMIF 内部 ECC 数据路径。
  - 全部 10 条均为 EMIF 内部 ECC/解码数据路径，无 FIFO 灰码跨域红项。
- Hold top-1（自定义 Slow 900mV 100C）：
  - `emif|...|ecc_core|...|io_hmc_ecc_interface_fifo_inst|read_ptr[1]` →
    `...|internal_master_rd_data[206]`，slack **+0.044 ns**（0 violated），
    同域 EMIF 路径；`sys_clk_50`/灰码 hold 不再上榜。
- Recovery top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `...|ecc_core|...|master_rd_data_r[162]`，slack **+0.340 ns**（0 violated）。
- Removal top-1：
  - `soc|emif_adapter|cpu_rst_sync1_n_fifo` →
    `soc|emif_adapter|request_fifo|rd_ptr_gray_wr1_q[1]`，slack **+0.471 ns**（0 violated）。

### 7. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof`

## 产出
- `docs/handoffs/T-20260902-031-fp-p5-rerun-round4.md`
- `docs/tasks/evidence/T-20260902-031.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-031-probe\**`
- 本地未提交副本：`build/agents/T-20260902-031/**`（git 忽略）

## 下一步
1. **闭合 `sys_clk_50` setup 新 top：`idex_d.operand_a[13]` → `i_l1|rsp_data_r[18]`**
   （49 逻辑级、32.334 ns、-12.446 ns）。这是 T-029 打断 MMU fault 链后暴露的
   core 运算结果到 L1 I-cache 响应数据的同域长链；建议对 L1 I-cache 返回数据
   做输出/输入寄存器切级，或对 `idex_d.operand_a` 的生成/消费路径切级，并重新评估
   ALU/前递与 L1 返回的时序余量。
2. **不要用 SDC false_path 掩盖该同域 setup**；先确认 L1 `rsp_data_r` 为何由
   core 组合信号直接驱动/经过 49 级组合到寄存器 D 端。
3. EMIF FIFO 灰码与 hold 已闭合；本轮不再需要 EMIF CDC 修复，除非后续 reg/resource
   变化再次引入。
4. 修复后重跑同 source/QSF/SDC 的 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
