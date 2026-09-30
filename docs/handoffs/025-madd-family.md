# LCVEX 交接文档 025：M3 - 乘加族 MADD/MSUB/SMADDL/UMADDL

日期：2026-08-24（Asia/Shanghai）
前置：handoff 024（寄存器偏移寻址 + 扩展 ADD/SUB）、PROJECT_STATUS M3。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（Data-processing 3-source 乘加族）

编译器乘法/乘加指令族的六种形式全部落地，并与 QEMU 11.1.0 锁步一致：
`MADD/MSUB`（32/64 位同宽乘加）与 `SMADDL/SMSUBL`（有符号 32x32->64）、
`UMADDL/UMSUBL`（无符号 32x32->64）。

### 1.1 解码（lcvex_decode.sv）

- 3-source 分支：`insn[30:29]==00 && insn[28:23] inside {110110,110111}
  && insn[22]==0`；
- 操作区分：`bit21=0` -> MADD/MSUB；`bit21=1 && bit23=0` -> SMADDL/
  SMSUBL；`bit21=1 && bit23=1` -> UMADDL/UMSUBL；
- **加/减由 bit15 区分**（bit15=1 为 MSUB/SMSUBL/UMSUBL 族），不是
  bit21/bit22；
- `operand_c`（Ra 加数）随流水线 ID/EX 传递，参与前递与提交旁路。

### 1.2 多周期乘除单元扩展（lcvex_muldiv.sv）

- `op` 3 位 -> 4 位：0=MUL 1=UDIV 2=SDIV 3..8=MADD 族；
- 新增 `acc` 输入（Ra 初始累加）与 `sub_mode`（减族在 acc 上减乘积）；
- SMADDL/SMSUBL 对 Rn/Rm 符号扩展、UMADDL/UMSUBL 零扩展后走 64 位
  移位累加路径；32 位 MADD 最终截断低 32 位；
- **修复**：除零短路原条件 `op!=MUL` 会误伤 b=0 的 MADD 族（错误返回 0
  而非 Ra），改为仅 `op∈{UDIV,SDIV}` 生效；b=0 的乘加走正常移位累加。

### 1.3 裸机 C（baremetal/main.c）

- `madd(a,b,c)` 与 `mul32(a,b)` 改为从 volatile `g_arr[]` 读入参数，
  防止 `-O2` 常数折叠（此前编译器把 `madd(0x1234,0x56,0x789)` 折叠成
  mov/movk/add，未实际发出乘加指令）；
- 反汇编确认真实生成 `madd x0,x0,x1,x2` 与 `umull x0,w0,w1`。

## 2. 验证结果（本机实跑）

- lint（Verilator `--lint-only -Wall`）通过；
- `hard_madd` 定向：6 种操作各 1 例 + 3 个边界（b=0、a=0、32 位乘积
  溢出截断），base 40 条、全缓存 45 条、delay2 45 条全部与 QEMU 一致；
- 裸机 C 200 条锁步一致（含真实 MADD/UMULL 路径）；
- `run_gate_d.sh` 全量 PASS：make test、coverage、M2/R1 26/26、
  hardening 22/22、delay2 12 项、Gate C/P5a/P4b、随机 100k、裸机 C。

## 3. 已知限制

- MADD 族按 64 周期/32 周期移位累加实现，性能非最优（后续可换 Wallace
  树/乘法器阵列，属优化项）；
- 寄存器变量移位（LSLV/LSRV/ASRV）、ROR、CSEL/BFM、LDR literal、
  exclusive 仍不支持（M3 剩余 / P6）；
- FP/SIMD 与 SVE 乘加不在本阶段（P7/P8）。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，本阶段提交见 git log；
- M3 剩余：**CSEL 族**（csel_fn 已暴露 csel x,x,x,ls）、**BFM**
  （O0 暴露 bfi）、**LDR literal**（启动/跳转表）、**exclusive**
  （P6 前）；
- 随后对照 Linux `head.S` 缺口清单补齐剩余启动路径指令。

关键命令：
`IMAGE=build/difftest/hard_madd.bin MAX_INSNS=40 COORD=build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh`
`bash sim/difftest/run_gate_d.sh`（约 5-8 分钟，全量验收）
