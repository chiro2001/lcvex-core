# LCVEX 交接文档 030：M3 - LDR literal（PC 相对加载）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 029（覆盖率补缺）、测试增强计划 TEST_ENHANCEMENT_PLAN。

## 1. 本阶段完成

`LDR（literal）` 四种形式全部落地并与 QEMU 11.1.0 锁步一致：

### 1.1 解码（lcvex_decode.sv）

- 模式：`insn[29:24]==011000`（[29:27]=011、bit26=0、[25:24]=00），
  opc=insn[31:30]；
- `addr = pc + SignExtend(imm19)<<2`（imm19 范围 ±1 MiB）；
- opc=00 LDR W（32 位零扩展）、01 LDR X（64 位）、10 LDRSW（32 位
  符号扩展，复用 ldr_sw/ldr_x 通路）、11 PRFM（按 NOP）；
- PC 恒 4 字节对齐，imm<<2 保持 4 对齐；64 位加载要求 8 字节对齐
  （测试里 literal 池按 8 对齐放置）。

### 1.2 测试汇编器（a64.py）

- 新增 `ldr_w_lit` / `ldr_lit` / `ldrsw_lit` / `prfm_lit` 编码器，
  按标签两遍汇编生成 imm19（±1 MiB、4 字节对齐校验），供测试与
  Linux `head.S` 复现使用。

### 1.3 测试

- `hard_ldr_literal`：W/X/LDRSW/PRFM 各一例，literal 池放程序末尾
  作死数据（循环回 main 不会被取指），lit64 8 字节对齐；
- LDRSW 用 0xF1234567 验证 32 位符号扩展
  （`0xfffffffff1234567`）。

## 2. 验证结果（本机实跑）

- lint（Verilator `--lint-only -Wall`）通过；
- `hard_ldr_literal` base 10 条、全缓存 15 条、delay2 15 条与 QEMU
  一致；
- `run_gate_d.sh` 全量 PASS（M2/R1 34/34、hardening 26/26、delay2
  16 项、随机 100k、裸机 C）——见提交对应日志
  `build/gate_d_ldr_literal.log`。

## 3. 已知限制

- PRFM literal 按 NOP（无缓存提示语义，与 QEMU 一致）；
- 64 位 literal 未对齐访问仍受"未实现 FSC=0x21"限制（handoff 029）；
- 尚未支持 LDR literal 的负偏移用例（imm19 负值路径未显式测试，
  编码器支持，后续可补）。

## 4. 仓库状态与下一步

- `feature/m3-isa`，本阶段提交见 git log；
- **M3 仅剩 exclusive**（P6 前）；
- 测试增强计划见 `docs/TEST_ENHANCEMENT_PLAN.md`（microbench 优先、
  后台 difftest 分层）。

关键命令：
`IMAGE=build/difftest/hard_ldr_literal.bin MAX_INSNS=10 COORD=build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh`
