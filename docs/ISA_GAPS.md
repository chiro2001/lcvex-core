# LCVEX 指令集实现状态与缺口（P6 本地冻结，2026-08-26）

> 2026-08-29 B0 审计注：本文档的历史主文仍是 P6 冻结快照。P7 已实现的
> FP/Advanced SIMD 选定子集与最新的 blocked/deferred 分布，以
> [`docs/V82_PROFILE_MANIFEST.md`](V82_PROFILE_MANIFEST.md) 为准；本文件仅
> 修正“P7 全缺”这一过时表述。

记录时间点：2026-08-26。目标架构：ARMv8.2-A AArch64（单发射、顺序、
非 OoO、单核）。验证基准：QEMU 11.1.0（固定版本 + `qemu/patches/`
可重放补丁）逐指令差分锁步。

## 验证覆盖度与证据边界

### Gate D 定向/随机覆盖（T-043）

冻结候选 `b2568a506088ac34ef1529975b120a3f0849b0c1` 的本地 Gate D 全量
回归通过：缓存/MMU/维护定向、Gate C/P4b/P5a、随机 seed 1–3 各
100,000 条、裸机 C 和并行结果均为 `rc=0`。随机 trace 的覆盖记账期望集
命中 `expected_hit=60/60`，实际观察到 `observed_families=61`；额外的已知
族不改变覆盖脚本的期望集合或退出语义。

### Linux 动态覆盖（T-044）

T-044 的 Lite 标量线（`A64_FP_SIMD=0`，QEMU `-cpu max,vfp=off,neon=off,
vfp-d32=off`）已逐指令锁步启动 Linux 6.6 到用户态 `/init`：

```text
Run /init as init process
LCVEX linux-lite /init ready
```

`/init`（无 libc 静态 ELF）在 pause() 循环下持续锁步通过，T-044 的
fresh-root 窗口共 **35,000,000 条提交**。该窗口只证明 Linux 动态路径
实际执行到的指令族与 QEMU 逐位一致；它不是对所有实现族的静态或完整
ISA 覆盖声明。T-044 另有 main continuation 5M 的 early-boot 证据，但
该线不宣称进入用户态。

## 已实现（标量核心）

下列实现矩阵由 RTL、Gate D 定向/随机和 Linux 动态证据分别支撑；Linux
窗口未执行到的族仍以对应 RTL 与定向/随机测试为准。

### 整数 ALU

- ADD/SUB/ADDS/SUBS/CMP/CMN：立即数、移位寄存器、扩展寄存器
  （UXTB/UXTH/UXTW/SXTB 等）；
- AND/ORR/EOR/BIC/ORN/EON/BICS/MVN：移位寄存器与逻辑立即数（位掩码）；
- MOVN/MOVZ/MOVK；
- ADC/ADCS/SBC/SBCS/NGC/NGCS（带进位/借位，2026-08-25 补）；
- 位域：SBFM/UBFM（ASR/LSR/LSL/SXTB 等别名）、BFM/BFI/BFXIL；
- LSLV/LSRV/ASRV/RORV（寄存器变量移位，W/X 移位量按数据宽度掩码）；
- EXTR（含 ROR 立即数）、CLZ/CLS、REV/REV16/REV32、RBIT；
- 条件选择：CSEL/CSINC/CSINV/CSNEG（含 CINC/CINV/CNEG）、
  CCMP/CCMN（条件标志）；
- 乘除：MUL/UDIV/SDIV、MADD/MSUB、SMADDL/SMSUBL/UMADDL/UMSUBL、
  UMULH/SMULH；
- CRC32/CRC32C（B/H/W/X，IEEE 与 Castagnoli 双多项式）。

### 访存

- LDR/STR（8/16/32/64 位，unsigned 立即数）；
- LDP/STP（pre/post/offset，含 SP 写回）；
- LDUR/STUR（非缩放偏移）、LDR/STR 单寄存器 pre/post-index；
- LDTR/STTR（非特权访问，按 EL0 权限）；
- LDRSW/LDRSB/LDRSH（符号扩展）、字面量 LDR；
- LDXP/LDAXP/STXP/STLXP（128 位 exclusive 对）；
- LSE 原子族：LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/
  SWP/CAS/CASP，以及 `LDCLRP`/`LDSETP`/`SWPP`（LSE128，单核事务语义）；
- LDAR/STLR 族（顺序语义，单发射顺序核无需额外栅栏）；
- exclusive 监视器（LDXR 记录、STXR/CLREX/ERET 清除）。

### 分支与系统

- B/BL/B.cond/CBZ/CBNZ/TBZ/TBNZ/BR/BLR/RET；
- SVC/HVC/SMC（PSCI 最小子集：VERSION/FEATURES/MIGRATE_INFO_TYPE/
  AFFINITY_INFO/CPU_ON；SYSTEM_RESET/OFF 由差分协议终止窗口）；
- ERET、MRS/MSR（大量 EL1/EL0 系统寄存器，见下）；
- ISB/DMB/DSB/SB；
- WFI/WFE/WFIT/WFET/SEV/SEVL（含 WFxT 超时与计时同步）；
- 维护指令：DC ZVA/CVAC/CVAU/CIVAC/IVAC/CVAP、IC IALLU/IVAU、TLBI
  E1 基线、AT S1E1R/W/S1E0R/W/S1E1RP/WP（更新 PAR_EL1）。

### PSTATE

- DAIF、SPSel、SSBS（bit12）、ALLINT（bit13）、UAO（bit23）、PAN（bit22）、
  DIT（bit24）、TCO（bit25）——全部随 SPSR 保存/恢复；ALLINT 的异常入口、
  IRQ 屏蔽和 ERET 恢复已按 QEMU 语义实现（T-033）。

## 占位（shim：RAZ/WI 或 NOP，语义自洽但非真实实现）

| 占位 | 说明 |
| --- | --- |
| PAuth（PAC） | key 寄存器（APIA/B、APDA/B、APGA）RAZ/WI；PACIASP/AUTIASP 等按 NOP（与 QEMU pauth=off 对齐） |
| BTI | 提示编码按 NOP（SCTLR.BT=0 语义） |
| SVE | ZCR_EL1 保留 VL 低 4 位；RDVL 按标量返回；无向量状态 |
| SME | SMCR_EL1/SMPRI_EL1/SMIDR_EL1/TPIDR2_EL0 shim |
| RAS | ISR_EL1/DISR_EL1 RAZ/WI |
| Debug（P9） | OSDLR_EL1/OSLAR_EL1/DBGB/DBGW 关闭语义 RAZ/WI |
| EL2 | SCTLR_EL2/HCR_EL2/VBAR_EL2/ELR_EL2/SPSR_EL2 等读 0 写忽略 |
| 其它 | SCTLR2_EL1、PAUTH_KEY、CSSELR_EL1（部分）等启动未触及寄存器按 RAZ/WI |

## 真实未实现（按路线图）

| 阶段 | 缺口 |
| --- | --- |
| P7 | FP/NEON：P7-0～P7-5 选定子集已实现（见 `docs/V82_PROFILE_MANIFEST.md`）；剩余 FP/NEON 族、`LDR/STR H`、完整 FP 异常 trap 仍为 blocked/deferred，不再表述为“全缺”。 |
| P8 | SVE256/SME 向量与 ZA 状态（V82-SVE-EXCLUDED，仅 probe shim） |
| P9 | PMU 事件计数、JTAG/GDB、外部 debug 机制 |
| 未排期 | EL2/EL3 虚拟化与安全态（QEMU 关闭，寄存器读 0） |

## 标量余量缺口（ARMv8.2 基础，lite 启动未触及）

- **逻辑移位寄存器形式的 ROR**（logical shifted-register 的 `shift_type=3`
  仍待补；`ADD/SUB` shifted-register 的对应编码是保留编码并按 UDEF
  处理；可用 EXTR/RORV 表达）；
- **MOPS**（CPY/CPYM/CPYE、SETP/SETM/SETE，ARMv8.6）：内核检测到
  “Memory Copy and Memory Set” 特征但 lite 路径未使用；
- **MTE**：ADDG/SUBG、STG/LDG 等地址/内存标记指令（TCO 位已保存）；
- **RCpc LDAPR/LDAPUR**：LDAR/STLR 已按顺序语义处理，LDAPR 未单独实现；
- **维护剩余项**：当前已覆盖 ARMv8.2 E1 TLBI 基线和 DC CVAP；
  TLBI OS/RV/range、DC CVADP、EL2/EL3 维护及缓存层级的完整硬件
  一致性仍未覆盖；
- **其它 LSE128 原子族与多核一致性**：当前仅实现 CASP/CASPA/CASPL/CASPAL
  与 LDCLRP/LDSETP/SWPP 的单核四阶段事务；不覆盖其它未来扩展。
- **未识别系统寄存器**：SYS 空间非启动路径的寄存器 → UDEF，遇缺再补。

## 已知风险

- 主线（全量 Linux 内核）与更复杂用户态（busybox、信号、clone、浮点
  库）会继续暴露新指令；当前 `/init` 是最小用户态。
- FP/NEON（P7）是 Linux 完整能力的必经项：当前已覆盖选定子集，但仍不是
  完整 ARMv8.2-A FP/Advanced SIMD，复杂用户态浮点/NEON 库仍可能触发
  未实现族。
- 恢复续跑不改写已固化的 `__setup` 参数（如 rdinit）；参数变更必须
  全新首跑。

## 相关文档

- `docs/handoffs/095`：lite 标量线（rdinit 根因、无 FP 配置）
- `docs/handoffs/097`：PSTATE.DIT
- `docs/handoffs/098`：IRQ+SP、varshift、LDTR/STTR
- `docs/handoffs/099`：无 FP QEMU 补丁与 ID 寄存器
- `docs/handoffs/100`：lite 标量线到达 /init
- `docs/V82_PROFILE_MANIFEST.md`：B0 机器可检查 V82 非 SVE profile 清单
