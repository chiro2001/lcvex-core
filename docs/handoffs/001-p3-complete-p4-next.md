# LCVEX 交接文档 001：P3 完成，进入 P4

日期：2026-08-23（Asia/Shanghai）
范围：为上下文压缩后的后续会话提供完整现状、决策依据与下一步计划。

## 1. 项目目标与阶段状态

实现 ARMv8.2-A AArch64 单核 CPU（单发射、顺序、非 OoO）：SystemVerilog
RTL + Verilator 仿真，Cocotb 与 SystemVerilog testbench 双轨验证，固定
稳定版 QEMU 11.1.0 做逐指令差分。路线图 P0–P10，总验收 Gate A–G。

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0 | ✅ | 仓库/工具链/文档（`5806564`、`560cb5e`） |
| P1 | ✅ | QEMU 状态导出插件 + 确定性 trace（`17946e2`） |
| P2 | ✅ | 标量 ISA + 1-cycle SRAM + RTL↔QEMU 差分（`9e263a8`、`04d7e08`） |
| P3 | ✅ | 5 级顺序流水线 + 多周期乘除（`3b9384c`、`0ad27c1`），Gate B 覆盖 |
| **P4** | **进行中** | 同步异常、EL0/EL1、ERET、MRS/MSR（下一步） |
| P5–P10 | 未开始 | MMU/TLB/Cache → Linux → FP/NEON → SVE → JTAG/PMU → FPGA |

配套锁步计划里程碑（`docs/DIFFTEST_QEMU_PLAN.md`）：Q0–Q5 已完成；
**Q6（QEMU fork 精确 step hook）即 P4 核心**；Q7 留给 P5。

## 2. 仓库与基线

- `main` 最新提交：`6e48ffc`（docs: add QEMU lockstep plan and
  collaboration rules）。工作区**干净**，无未提交文件。
- QEMU 源码在 `../qemu`（浅克隆、单提交、release 11.1.0），构建产物
  `../qemu/build/qemu-system-aarch64`；**尚未 fork/打补丁**，P4 需要。
- conda 环境：`lcvex`（`CONDA_RUN = conda run --no-capture-output -n lcvex`）。
- 所有文档（含用户后来要求提交的 `AGENTS.md`、`qemu/README.cn.md`、
  `docs/DIFFTEST_QEMU_PLAN.md`）均已入库。

## 3. 微架构现状（P3）

5 级流水线 IF→ID→EX→MEM→WB/COMMIT，单发射、顺序提交、每周期至多一个
提交。架构状态（GPR 31×64/SP/NZCV）只在 COMMIT 沿更新。

- **取指（issue-on-capture）**：fetch PC 只在指令被 IF/ID 捕获后推进；
  在途取指（`fetch_pending`/`fetch_pc_r`/`fetch_issued_r`）重复呈现地址
  以保持 SRAM rdata，stall/访存争用期间数据不丢不重。这是多次边角 bug
  后定型的方案，**不要退回旧的“fetch 每周期推进 + 回退/冗余保护”设计**。
- **转发**：EX/MEM/WB 三级写回前递到 ID 的 GPR/SP/NZCV 读视图
  （`gprv/spv/nzcvv`）；EX 级 load 不参与前递，改走 load-use stall。
- **stall**：load-use（等 load 到 WB）、单端口 SRAM 访存/取指争用
  （MEM 优先，取指推迟）、无效指令（当前停住，P4 改异常）、乘除忙
  （冻结 IF/ID、保持 ID/EX）。
- **flush**：分支在 ID 解析（decode 用前递后操作数算 `next_pc`），跳转
  冲刷 IF/ID 并重定向取指；flush 前抑制 load-use 与乘除忙。
- **乘除**：`rtl/lcvex_muldiv.sv`，移位累加乘法 + 恢复余数除法，
  64 位 64 周期 / 32 位 32 周期；`done = busy_r && cnt==last` 组合输出，
  `result` 在最后一个计算周期组合就绪，核心同一拍推进 EX/MEM 与取指。
- **访存**：单端口 1-cycle SRAM（1 MiB，`DEPTH 1<<20`，地址取低
  clog2(DEPTH) 位回绕）；`lcvex_mem` 的读是寄存输出（地址 N 周期发出、
  N+1 数据有效）。
- 已知特征：稳态 IPC 约 0.5；无效指令停住不提交（P2 语义，P4 改）；
  无 MMU/缓存/异常/中断/FP。

## 4. 指令实现状态

已实现并经差分验证：ADD/ADDS/SUB/SUBS/CMP/CMN（立即数与移位寄存器，
X/W）、AND/ANDS/ORR/EOR（移位寄存器，X/W）、MOVN/MOVZ/MOVK（X/W）、
MUL/UDIV/SDIV（X/W，多周期）、B/BL、B.cond、CBZ/CBNZ、TBZ/TBNZ、
BR/BLR/RET、LDR/STR（unsigned immediate 8/16/32/64）、LDRSW、ADR/ADRP、
NOP。XZR/SP 语义、32 位零扩展、逻辑 flag-setting 清零 C/V 已对齐 ARM。

未实现：逻辑立即数（bitmask）、UBFM/LSLV/LSRV/ASRV/ROR、MADD/MSUB 及
SMADDL/UMADDL 族、LDP/STP、pre/post-index、寄存器偏移访存、系统指令
（SVC/ERET/MRS/MSR/ISB/DSB/DMB，P4）、原子/LSE、Cache maintenance。
详细见 `docs/ISA_SCOPE.md`（已更新到 P3）。

## 5. 差分测试清单（全部实跑通过）

| 命令 | 覆盖 | 备注 |
| --- | --- | --- |
| `make test` | P0：toolcheck/compile/sim-sv/cocotb 单测 | 每次提交应跑 |
| `make difftest` | P1 两次运行确定性 + P2 RTL↔QEMU 33 条 | |
| `make difftest-hazard` | 34 条定向（forwarding/load-use/flush/NZCV/MOVK/乘除/除零/BL-RET） | |
| `make difftest-random` | 固定种子随机（`SEED=`/`LENGTH=`，seed 1–5 通过） | |
| `make difftest-random-big` | 10 万条随机（约 5% 乘除） | 与 QEMU 完全一致 |
| `make lockstep` | 实时锁步 36 条 | C++ 协调器 |
| `make lockstep-q5` | 四场景：正常/提前 STOP/DISCON/断开 | |

关键实现文件：`qemu/plugins/lcvex_difftest.c`（trace + sync 插件）、
`qemu/plugins/lcvex_protocol.h`（二进制协议）、
`sim/difftest/lockstep_coordinator.cc`（DUT 封装 + 握手 + 比较）、
`sim/difftest/run_lockstep.sh`（支持 `EXPECT_FAIL`/`KILL_QEMU_AFTER`/
`MAX_INSNS`/`COORD_TIMEOUT_S`）、`sim/difftest/run_lockstep_q5.sh`、
`sim/difftest/run_qemu.py`、`sim/difftest/a64.py`（汇编器）、
`sim/difftest/state_model.py`（参考模型）、`sim/difftest/random_program.py`。

## 6. 注意事项与坑

- **Cocotb 2.0.1 无 `cocotb.runner`**：用 Makefile +
  `COCOTB_TEST_MODULES`/`SIM_BUILD`；`COCOTB_RESULTS_FILE` 可覆盖结果
  文件避免增量缓存误判。`sim/cocotb/Makefile` 的 `VERILOG_SOURCES` 手工
  列出 RTL，新增模块要同步加（如 `lcvex_muldiv.sv`）。
- Verilator lint `-Wall` 把 warning 当 error（`make compile`）；`rem_sub`
  64 位截断是恢复除法不变式的有意截断。
- cocotb 周期预算：`max_cycles = 96*len(words)+4096`（覆盖 64 周期乘除）。
- 提交纪律：不要 `git add -A`；只 add 本阶段文件（历史教训）。
- QEMU 插件 API：atexit 回调签名是 `qemu_plugin_udata_cb_t`
  （`void (*)(void*)`）；discon 回调已注册（Q5）。
- Q5 discon 测试程序 `build/difftest/q5exc.bin` =
  `movz x0,#0x5000,lsl#16; str x0,[x0]`（store 到未映射地址触发数据
  abort → DISCON）。`udf.bin` 已废弃（首条 UDF 会触发 DUT 超时而非
  DISCON，不要再用）。
- virt 机器默认 RAM 128 MiB；程序基址 `0x44000000`，随机程序数据基址
  `0x44080000`（SRAM 内回绕，两者不重叠）。
- `make lockstep-build` 用 `verilator --cc --exe` 重建协调器。

## 7. 下一步：P4 详细计划

**P4a（Q6）QEMU fork 精确 step hook**

- 在 `../qemu` 加 `qemu_lcvex_difftest_step(CPUState*, struct
  lcvex_qemu_commit*)`：单指令 TB + 内部 step hook，必须区分
  （1）指令正常退休；（2）同步异常未退休；（3）异常入口 PC
  discontinuity；（4）IRQ/FIQ 异步事件。不得把插件 before-instruction
  回调当 retirement hook。
- 补丁管理：`qemu/patches/` 可重放，`qemu/VERSION` 记录 release；
  每个 QEMU release 需重新验证 hook 位置。
- 验证：SVC 能上报精确异常；`make difftest` 无回归。

**P4b RTL 异常与 EL0/EL1**

- 非法指令（EC 0x00）、SVC（EC 0x15）、指令/数据 Abort（EC 0x20/0x25）
  生成同步异常；异常向量入口；`ERET`；`SPSR_EL1/ELR_EL1`；必要
  `MRS/MSR`；无效指令从“停住”改为异常提交；`exc_valid/exc_code` 写入
  commit packet（字段已预留）。
- 新增系统状态需说明 reset 值、读写权限、提交时机（AGENTS.md 规则 5）。

**P4c 差分与验收（Gate C）**

- 协调器/插件适配异常提交比较；非法指令、SVC、Abort、ERET 定向测试
  纳入 QEMU 差分；完成后跑 P0–P3 全量回归（第 5 节清单）。

## 8. 文件地图

- 核心 RTL：`rtl/lcvex_core.sv`（流水线/转发/stall/flush/乘除集成）、
  `rtl/lcvex_decode.sv`、`rtl/lcvex_alu.sv`、`rtl/lcvex_muldiv.sv`、
  `rtl/lcvex_mem.sv`、`rtl/lcvex_pkg.sv`、`rtl/lcvex_regfile.sv`（单测用）。
- 仿真顶层/测试台：`tb/sv/lcvex_soc_tb.sv`、`tb/sv/lcvex_core_tb.sv`。
- 差分：`qemu/plugins/`、`sim/difftest/`、`sim/cocotb/`。
- 文档：`ROADMAP.md`、`DEVELOPMENT_PLAN.md`、`ISA_SCOPE.md`、
  `DIFFTEST.md`、`DIFFTEST_QEMU_PLAN.md`、`COMMIT_PACKET.md`、
  `VERIFICATION.md`、`GIT_WORKFLOW.md`、本文件。
