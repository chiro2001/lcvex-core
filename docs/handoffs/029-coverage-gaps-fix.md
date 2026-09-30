# LCVEX 交接文档 029：覆盖率补缺（BLR/LDRSB/LDRSH）+ 符号扩展修复

日期：2026-08-24（Asia/Shanghai）
前置：handoff 028（分支整理）、覆盖率审查发现 BLR/LDRSB/LDRSH 无定向测试。

## 1. 背景

按 AGENTS.md「每条已支持指令必须有定向测试」核查，发现三个实现但未被
差分验证的缺口：`BLR`、`LDRSB`、`LDRSH`。补测试过程中暴露并修复了一个
真实 RTL bug。

## 2. 本阶段完成

### 2.1 解码补全（unsigned-immediate LDRSB/LDRSH）

- 原 unsigned-immediate 分支只支持 LDRSW（opc=10, size=2），LDRSB/
  LDRSH 全部 UDEF；现补 opc=10（size 0/1 = X 形式、size 2 = LDRSW、
  size 3 = PRFM 按 NOP）与 opc=11（size 0/1 = W 形式，其余无效）；
- 寄存器偏移分支的 opc=10/11 同样按 W/X 区分（此前统一 64 位扩展）；
- 新增 `ldr_x` 管道字段：1 = 符号扩展到 64 位（X 形式/LDRSW），
  0 = 符号扩展到 32 位再零扩展（W 形式）；WB 按 `ldr_x` 选择扩展宽度。

### 2.2 修复真实 bug：LDRSB/LDRSH 的 W/X 符号扩展反了

- **编码表记反**：`opc=10` 是 X 形式（64 位符号扩展），`opc=11` 是
  W 形式（32 位符号扩展 + 零扩展）。原实现（以及最初补丁）把两者
  分配反了，导致 `ldrsb w` 返回 64 位符号扩展、`ldrsb x` 只扩 32 位；
- 该路径此前从未被差分覆盖，锁步在第一条 `ldrsb w` 处即失败；
- 修复后用 decode 单测逐项验证：LDRSW/LDR W/LDRB/LDRSB W/X/LDRSH
  W/X/PRFM 全部与编码表一致。

### 2.3 BLR 定向测试

- `adr x0, target; blr x0`：验证间接调用链接写回（x30=pc+4）、目标
  跳转、中间指令被冲刷，以及 adr 结果到 BLR 寄存器读的前递；
- 锁步每拍比较全部 GPR，链接地址错误会立即暴露。

### 2.4 测试踩坑与已知限制

- 测试初版把 `ldrsh w6, [x8]` 的编码写成了 `[x9]`（0x79C00126），
  导致加载 0xbeef（未对齐）触发 DABT：QEMU 报对齐 fault（FSC=0x21），
  RTL 报 PA 越界（FSC=0x10）——**暴露 RTL 未实现对齐 fault 检查**
  （对齐地址按越界处理），属已知限制（R1 遗留），本次仅修正测试编码；
- 已修正编码为 `0x79C00106/0x79800107`（[x8]）。

## 3. 验证结果（本机实跑）

- lint（Verilator `--lint-only -Wall`）通过；
- decode 单测 6 例全部符合 A64 编码表；
- `hard_insn_gaps` 定向 32 条/40 提交：BLR、LDRSB/LDRSH W/X（unsigned-
  immediate + 寄存器偏移）、PRFM；base 40 条、全缓存 45 条、delay2
  45 条全部与 QEMU 一致；
- `run_gate_d.sh` 全量 PASS：make test、coverage、M2/R1 32/32、
  hardening 25/25、delay2 15 项、Gate C/P5a/P4b、随机 100k、裸机 C。

## 4. 仓库状态与下一步

- `feature/m3-isa`，本阶段提交见 git log；
- M3 剩余：**LDR literal**、**exclusive**；随后 Linux `head.S` 缺口
  清单；
- 已知限制新增：非对齐访存当前按 PA 越界报 0x10，未实现 FSC=0x21
  对齐 fault（Linux 前需补）。

关键命令：
`IMAGE=build/difftest/hard_insn_gaps.bin MAX_INSNS=40 COORD=build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh`
`bash sim/difftest/run_gate_d.sh`（约 5-8 分钟，全量验收）
