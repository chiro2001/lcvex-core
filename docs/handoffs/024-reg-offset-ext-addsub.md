# LCVEX 交接文档 024：M3 - 寄存器偏移寻址 + 扩展寄存器 ADD/SUB

日期：2026-08-24（Asia/Shanghai）
前置：handoff 023（LDP/STP）、PROJECT_STATUS M3。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（编译器数组/索引寻址）

编译器数组访问与索引计算的两种核心形式落地：
**LDR/STR 寄存器偏移寻址**（`[rn, rm, lsl #s]`）与**扩展寄存器
ADD/ADDS/SUB/SUBS**（`add x, x, w, uxtw #3` 等）。均以真实编译器输出
驱动（-O1/-O2 裸机 C 实测），并与 QEMU 锁步。

### 1.1 寄存器偏移寻址（decode）

- 模式：`insn[29:27]==111 && insn[26]==0 && insn[25:24]==00 &&
  insn[21]==1 && insn[11:10]==10`；
- 地址 = rn + ext(rm, opt) << (S ? sz : 0)；opt[1:0]=0/1/2/3 为
  8/16/32/64 位扩展宽度，opt[2]=符号（SXTB/SXTH/SXTW 等）；
- opc：00=STR（含 STRB/STRH/STRW）、01=LDR（sz3=64 位，其余零扩展）、
  10/11=LDRSB/LDRSH/LDRSW（符号扩展）；opc=10 且 sz=3 为 PRFM（NOP）；
- WB 扩展 LDRSB/LDRSH 的 8/16 位符号扩展。

### 1.2 扩展寄存器 ADD/SUB（decode）

- 模式：`insn[28:21]==01011001`；st=选项（同寄存器偏移的扩展编码）、
  sa=移位量（0..4，5..7 保留 -> UDEF）；
- 结果 = Rn +/- ext(Rm,st)<<sa；非 S 形式 Rn/Rd=31 为 SP（与 QEMU
  cpu_reg_sp 语义一致），S 形式 Rn/Rd=31 为 XZR。

### 1.3 测试

- `hard_reg_offset`：ldr/str 寄存器偏移（byte/half/word/dword）、LDRSW、
  SP 基址，与 QEMU 锁步；
- `hard_ext_addsub`：uxtw/sxtw/uxtb/lsl 四种选项 + 移位，锁步一致；
- 裸机 C 扩展：数组 `g_arr[i]` 循环（`str x1,[x5,x0,lsl#3]`）、
  `idx_sum`（寄存器偏移读）、结构体 pair_set/pair_sum（stp/ldp）；
  构建加 `-mgeneral-regs-only`（本阶段核无 FP/SIMD），delay 缩短使锁步
  窗口内覆盖全部代码；200 条锁步一致。

## 2. 验证结果（本机实跑）

- `make test` 全绿；hardening 21/21；M2/R1 24/24；
- `run_gate_d.sh`：67 项子检查全部 PASS。

## 3. 已知限制

- PRFM 按 NOP（无缓存提示语义，与 QEMU 一致）；
- 扩展寄存器 ADD 的 sa>4 保留编码按 UDEF（QEMU 同）；
- 原子（exclusive/LDADD 等）与 FP/SIMD 访存仍不支持（P6/P7）。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- M3 剩余：MADD/MSUB/UMULL、CSEL 族、BFM、LDR literal、exclusive；
  随后 Linux head.S 缺口清单。
