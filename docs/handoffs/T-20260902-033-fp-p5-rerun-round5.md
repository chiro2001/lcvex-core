# Handoff T-20260902-033: FP-P5 rerun round5 after T-20260902-032

```text
task=T-20260902-033
state=blocked
base=ed1a0b92cf2427a82ca19cd39c7f832c100dca88
head=ed1a0b92cf2427a82ca19cd39c7f832c100dca88
branch=verify/T-20260902-033-fp-p5-rerun-round5
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-033
sent_at=2026-09-03T20:59:00+08:00
received_at=2026-09-03T20:59:30+08:00
reported_at=2026-09-03T22:02:10+08:00
```

## 结论

- 在包含 T-20260902-032（ID/EX GPR forwarding cut）的合并 SHA
  `ed1a0b92cf2427a82ca19cd39c7f832c100dca88` 上，重跑 full-FP：
  **synthesis PASS** → **fitter PASS** → **signoff STA FAIL（仅 setup 红）**。
- 因此按任务约束**未运行 assembler/SOF**；远端 probe 确认没有
  `.sof/.jic/.rbf/.pof/.jbc`。
- T-032 的预期目标已达成：旧的 `sys_clk_50` setup top-1
  `idex_d.operand_a[13] -> i_l1|rsp_data_r[18]`（T-031：-12.446 ns，49 级，
  32.334 ns）已完全离开 signoff setup top-N，汇总中不再出现 `i_l1|rsp_data_r`。
- 但仍剩 `sys_clk_50` setup 红项，且暴露了新的 FP 标量迭代/预舍入路径：
  - top-1：`soc|core|g_fp_simd_enabled.fp_exec|req_r.kind[1]`
    → `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_pre.sig[120]~DUPLICATE`
  - slack **-8.734 ns**，data delay **28.908 ns**，**54 逻辑级**，无 SDC exception。
  - 相对 T-031 的 -12.446 ns / 49 级 / 32.334 ns，setup 最差已有明显改善
    （-8.734 ns，Fmax 30.82 → 34.8 MHz）。
- EMIF/hold/recovery/removal/min-pulse/DDR/metastability 全部保持绿：
  - EMIF `core_usr_clk` setup +0.387 ns（TNS 0）
  - hold signoff 最差 +0.012 ns（`sys_clk_50`）/ +0.016 ns（EMIF）
  - recovery +0.572 ns（EMIF）
  - removal +0.179 ns（EMIF）
  - min-pulse +0.120 ns
  - DDR Pass，Metastability Pass。

## 各阶段摘要

### 1. 远端只读预检
- host=192.168.101.5（GAMEPC），shell 使用
  `pwsh.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand`。
- 无 Quartus/qsys/vsim/questa EDA 进程；`jtagserver.exe` 运行中（PID 5476，
  未停止）。
- 物理空闲约 44,890.9 MB / 总 63,092.3 MB；D: 可用约 75.9 GB。
- 确认 `T-20260902-033-probe` 不存在后新建隔离 probe。
- 未读取 license；未删除文件；未停止非 EDA 进程；未编程/上板/触碰 JTAG。

### 2. 源码同步与隔离
- 远端隔离 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260902-033-probe\`
- 同步 47 个 `rtl/*.sv` + 2 个 `fpga/catapult_a10/rtl/*.sv` + 3 个工程文件
  （QPF/QSF/SDC），共 52 个唯一远端目标；远端 SHA-256 全部与本地一致
  （REMOTE_VERIFY count=52, bad=0）。
- 正式 QSF/SDC 取自当前 worktree；QSF 仅把 probe 路径替换为
  `T-20260902-033-probe`。正式 SDC 保持 T-030 新增的 Gray CDC 约束。
- 仅保留一个隔离 RTL 兼容补丁（未写入正式仓库）：`lcvex_fp_scalar.sv`
  移除输入端口默认值 `iter_kill/iter_pause/kill/pause`（与历史 FP-P5 轮次相同）。
- 关键输入 SHA-256：
  - `rtl/lcvex_core.sv`（T-032 后）：`e261d8a3604d97e1d9b31bc1ec7f1ce20fb52b4dc72c6eb34b1679c8d2eee722`
  - `rtl/lcvex_fp_scalar.sv`（正式）：`c9de754bfb627c91fe1ef3d2ed3d3b9b40c6efbc3b58ba57e0d4d4ee8796dba5`
  - `rtl/lcvex_fp_scalar.sv`（远端隔离补丁）：`9953097c55f63fffb877bcb4739c6406247d59e68c2f885589f46b4a470a579d`
  - `fpga/catapult_a10/quartus/catapult_a10.sdc`：`2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`
  - 本地 manifest：`build/agents/T-20260902-033/sync/manifest_t033.json`
    SHA-256 `4a38609291c91355ed33c337b91848421034af43c91a0201afd6b73849a845c0`

### 3. Synthesis
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`
- exit 0；0 errors / 230 warnings / 0 critical warnings；wall 1270.157 s；
  peak PM 4,651.8 MB / WS 4,446.7 MB / VM 9,540.5 MB。
- 资源（估算）：
  - ALM estimate **145,146**（root partition）
  - Combinational ALUT 180,106；Dedicated logic registers 83,473
  - Block memory bits 247,272；DSP 27；PLL 1；I/O pins 144
  - Max fanout 75,835（`sys_clk_div2`）；Total fanout 1,270,727；
    Max LUT depth 79.40；Average LUT depth 24.45
- 关键 hierarchy：
  - `soc|core`：ALUT 121,522 / regs 22,711 / DSP 18
  - `g_fp_simd_enabled.fp_exec`：ALUT 60,642 / regs 3,132 / DSP 6
  - `scalar_unit`：ALUT 58,441 / regs 2,142 / DSP 6
  - `g_iter.it_divider`：ALUT 235 / regs 433
  - `g_iter.it_sqrt`：ALUT 791 / regs 390
  - `g_fp_simd_enabled.neon_int`：ALUT 8,528 / regs 0
  - `soc|core|mmu`：ALUT 3,672 / regs 5,972
  - `emif_adapter`：ALUT 20,221 / regs 2,998 / DSP 9
  - `calibration_gate`：ALUT 3 / regs 6

### 4. Fitter
- 命令：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start fitter -end fitter`
- exit 0；0 errors / 11 warnings / 3 critical warnings；wall 1504.671 s；
  peak PM 13,130.8 MB / WS 12,948.6 MB / VM 20,808.3 MB。
- 资源：
  - Logic utilization ALM **142,817 / 427,200（33%）**
  - Total registers 85,837；Total pins 141 / 826（17%）
  - Block memory bits 245,608 / 55,562,240（<1%）；RAM blocks 121 / 2,713（4%）
  - DSP 26 / 1,518（2%）；PLL 3 / 112（3%）
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
  - Setup `sys_clk_50`：**-8.734 ns**，TNS -104,366.614，Slow 900mV 100C
  - Setup `emif...core_usr_clk`：**+0.387 ns**（全绿，TNS 0）
  - Hold `sys_clk_50`：**+0.012 ns**（Fast 900mV 0C）
  - Hold `emif...core_usr_clk`：**+0.016 ns**（Fast 900mV 0C）
  - Recovery `emif...core_usr_clk`：**+0.572 ns**；`sys_clk_50` +2.995 ns
  - Removal `emif...core_usr_clk`：**+0.179 ns**；`sys_clk_50` +0.185 ns
  - Minimum pulse width 最差：**+0.120 ns**
  - DDR：Pass；Metastability：Pass
  - Fmax：`sys_clk_50` **34.8 MHz**；`emif...core_usr_clk` 297.35 MHz；
    `emif...core_cal_master_clk` 197.08 MHz；`emif...core_cal_slave_clk` 322.79 MHz；
    `clk_y3` 606.8 MHz

### 6. 自定义 TimeQuest top-N（`report_timing -setup/-hold/-recovery/-removal -npaths 10`）
- Setup top-1（Slow 900mV 100C）：
  - From `soc|core|g_fp_simd_enabled.fp_exec|req_r.kind[1]`
  - To `soc|core|g_fp_simd_enabled.fp_exec|scalar_unit|g_iter.pp_pre.sig[120]~DUPLICATE`
  - Slack **-8.734 ns**，data delay **28.908 ns**，**54 逻辑级**，
    无 SDC exception。该路径位于 FP 标量 `scalar_unit` 的预舍入/迭代
    数据路径（路径中包含 `slot_b`、`reduce_or`、`mult_2` DSP 链等）；
    top-2..10 为同一源到 `g_iter.pp_pre.sig[120]` 的重复/非重复寄存器，
    slack -8.693..-8.734。
- Hold top-1（自定义 Slow 900mV 100C）：
  - `emif|...|io_hmc_ecc_interface_fifo_inst|data_reg[1][154]` →
    `emif|...|io_hmc_ecc_inst|internal_master_rd_data[137]`，slack **+0.075 ns**（0 violated），
    1 逻辑级，EMIF 内部 ECC 数据路径。
- Recovery top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|core|ecc|io_hmc_ecc_inst|int_encoder_input_data[4][53]`，
    slack **+0.572 ns**（0 violated）。
- Removal top-1：
  - `emif|...|reset_sync_pri_sdc_anchor` →
    `emif|...|ecc_core|core|ecc|io_hmc_ecc_inst|int_master_cmd_data[40]`，
    slack **+0.434 ns**（0 violated）。

### 7. 未执行
- **assembler/SOF（setup 未全绿，明确未运行）**
- 编程/JTAG/上板/烧写
- 未读取 license；未停止 jtagserver；未删除远端文件
- 远端确认无 `.sof/.jic/.rbf/.pof/.jbc`

## 产出
- `docs/handoffs/T-20260902-033-fp-p5-rerun-round5.md`
- `docs/tasks/evidence/T-20260902-033.json`
- 远端隔离 probe 与全部报告：
  `D:\Projects\fpga-altra\lcvex\build\T-20260902-033-probe\**`
- 本地未提交副本：`build/agents/T-20260902-033/**`（git 忽略）

## 下一步
1. **闭合新的 `sys_clk_50` setup top：FP 标量 `req_r.kind[1]` →
   `scalar_unit|g_iter.pp_pre.sig[120]`**（54 逻辑级、28.908 ns、-8.734 ns）。
   该路径已从 T-031 的 L1 I-cache 响应链转移到 FP 标量预舍入/迭代数据链。
   建议：
   - 检查 `req_r.kind` 到 `pp_pre` 组合锥是否可在 `fp_exec` 请求解码或
     `scalar_unit` 预舍入入口做定向寄存器切级；
   - 或对 `g_iter`（FP 迭代 DIV/SQRT）相关 `pp_pre.sig`/多周期路径增加
     明确的流水级/使能切分；
   - 不要用 SDC false_path 掩盖该同域 setup。
2. 保持 T-032 的 ID/EX GPR 前递切级；旧 `i_l1|rsp_data_r` setup 链已确认离开 top-N。
3. 修复后重跑同 source/QSF/SDC 的 FP-P5；只有
   setup/hold/recovery/removal/min-pulse 全非负且 DDR pass 才允许 assembler/SOF。
