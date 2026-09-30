# LCVEX 交接文档 027：M3 - BFM 位域插入（BFI/BFXIL/BFC）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 026（条件选择族）、PROJECT_STATUS M3。
分支：`feature/m3-isa`（由 `feature/commit-memory-handshake` 更名）。

## 1. 本阶段完成（Data-processing bitfield 的 BFM）

`BFM`（含 `BFI`/`BFXIL`/`BFC` 别名）落地并与 QEMU 11.1.0 锁步一致。
SBFM/UBFM 早在 handoff 022 已实现，本次补上中间 opc=01。

### 1.1 解码（lcvex_decode.sv）

- 位域分支 `[28:23]==100110 && [30:29]!=11` 内，`[30:29]==01` 开放为
  BFM（此前 `d.valid=0`）；
- W 形式约束（N/immr[5]/imms[5] 必须为 0）提到 BFM/SBFM/UBFM 判断
  之前，三种 opc 共用；
- BFM 需读旧 Rd 作为 deposit 基础：`operand_c = rdg(rd)`，并登记
  `rs3=rd/rs3_en`（复用 MADD 的 rs3 前递与 load-use 路径）；
- `ALU_BFM` 携带 `{immr, imms}` 到 ALU。

### 1.2 ALU（lcvex_alu.sv）

- 新增 `c` 输入（旧 Rd）；`bfm_deposit` 实现 QEMU `trans_BFM` 语义：
  - `si>=ri`：`Rd[len-1:0] = Rn[si:ri]`（len=si-ri+1，pos=0）；
  - `si<ri`：`Rd[pos+len-1:pos] = Rn[si:0]`（len=si+1，
    pos=(bitsize-ri)&(bitsize-1)）；
  - 字段外位保留旧 Rd；W 形式最终低 32 位截断零扩展。
- 核心 ALU 实例接入 `.c(idex_d.operand_c)`。

### 1.3 测试

- `test_alu` 新增 3 例：bfi 插入保留其余位、bfxil 低字段替换、W 形式
  高 32 位清零（11/11 通过）；
- `hard_bfm` 定向 23 条/25 提交：bfi/bfxil/bfm r==s 单比特、全宽 64、
  W 形式（bfi/bfxil/宽字段）、源 XZR；base 25 条、全缓存 30 条、
  delay2 30 条全部与 QEMU 一致；
- 踩坑记录：单测期望值曾误算（`0xABCD[11:4]=0xBC` 而非 0xCD、旧
  Rd=-1 时 W bfi 字段外保留 0xFFFF），锁步 RTL==QEMU 始终一致，仅
  修正测试期望与程序注释，未改 RTL。

## 2. 验证结果（本机实跑）

- lint（Verilator `--lint-only -Wall`）通过；
- `run_gate_d.sh` 全量 PASS：make test（含 ALU 单测 11/11）、coverage、
  M2/R1 30/30、hardening 24/24、delay2 14 项、Gate C/P5a/P4b、
  随机 100k、裸机 C 200 条。

## 3. 已知限制

- 寄存器变量移位（LSLV/LSRV/ASRV）、ROR、EXTR 仍不支持（后续）；
- `LDR literal`（PC 相对加载）与 exclusive 仍是 M3 剩余项（exclusive
  计划 P6 前）；
- FP/SIMD 与 SVE 位域指令不在本阶段（P7/P8）。

## 4. 仓库状态与下一步

- 分支已更名为 `feature/m3-isa`（见 handoff 028 分支整理说明）；
- M3 剩余：**LDR literal**、**exclusive**；随后 Linux `head.S` 缺口
  清单。

关键命令：
`IMAGE=build/difftest/hard_bfm.bin MAX_INSNS=25 COORD=build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh`
`conda run --no-capture-output -n lcvex make -C sim/cocotb SIM=verilator TOPLEVEL=lcvex_alu COCOTB_TEST_MODULES=test_alu SIM_BUILD=sim_build_alu`
`bash sim/difftest/run_gate_d.sh`（约 5-8 分钟，全量验收）
