# 04 ISA / 架构：V82 非 SVE Profile 支持矩阵与后置

> 状态：**V82-BASE + V82-SELECTED-EXT 的机器可检查清单已冻结（T-098），
> 但这不是“完整 ARMv8.2-A”合规宣称；SVE/SME 和 POST-V82 扩展明确后置。**
> 权威：`docs/V82_PROFILE_MANIFEST.md`、`docs/ISA_SCOPE.md`、`docs/ISA_GAPS.md`。

## 1. Profile 口径（ADR-20260829-005）

| Profile | 定义 | 行数 |
| --- | --- | --- |
| `V82-BASE` | 项目选定的 AArch64 基础标量、系统、异常、MMU/Cache 语义 | 68 |
| `V82-SELECTED-EXT` | 明确列出的 FP/Advanced SIMD、FP16、CRC、LSE 等扩展 | 28 |
| `V82-SVE-EXCLUDED` | SVE/SVE2/SME 明确排除 | 5 |
| `POST-V82-DEFERRED` | PAuth、RCpc、MTE、MOPS、其它 LSE128、Crypto 等 | 16 |
| 合计 | | 117 |

按行状态：`implemented=94`、`shim=8`、`udef=1`、`blocked=1`、`deferred=13`。

只有 `V82-BASE + V82-SELECTED-EXT` 清单闭合才允许使用“非 SVE profile 已闭合”
措辞。当前 **94 implemented，另有 1 blocked + 13 deferred/shim 等**，因此不是全体闭合。

## 2. 已支持主体摘要（完成）

- 基础整数 ALU：ADD/SUB 立即数/移位/扩展、逻辑立即数/移位、位域、
  MOV 族、ADC/SBC 族、变量移位、EXTR、REV/CLZ/CLS/RBIT、条件选择、
  乘除/乘加、UMULH/SMULH、CRC32/CRC32C。
- 分支：B/BL/B.cond/CBZ/CBNZ/TBZ/TBNZ/BR/BLR/RET。
- 访存：LDR/STR、LDP/STP、LDUR/STUR、LDR literal、LDRSB/LDRSH/LDRSW、
  LDTR/STTR、exclusive 对、LSE 原子/比较交换、LSE128 选定单核事务。
- 系统：SVC/HVC/SMC（PSCI 最小子集）、ERET、MRS/MSR 大批 EL1/EL0 寄存器、
  ISB/DSB/DMB/SB、WFI/WFE/WFIT/WFET/SEV/SEVL、DC/IC/TLBI/AT 基线、
  Generic Timer、GICv2/GICv2m、PL011/PL061/PL031、PSTATE.PAN/UAO/DIT/SSBS/
  ALLINT/TCO。
- FP/NEON（选定）：V0–V31、FPCR/FPSR、FPEN/trap 访问门控、标量 FP32/64/16
  算术/比较/FMA/转换/sqrt/min/max/rint、NEON 整数与单 Q 访存、NEON FP 与向量
  FMA/转换等。

具体每行的 RTL、SV TB、Cocotb、QEMU oracle 和 negative 记录见
`docs/V82_PROFILE_MANIFEST.md` 内嵌 JSON。

## 3. 解码边界 / 明确缺口

- `V82-BASE`：逻辑移位寄存器 `ROR` 形式（shift_type=3）已实现
  （`BASE-DP-018`）；`ADD/SUB` shifted-register 的对应 `shift_type=3` 是
  保留编码并按 UDEF；`LSLV/LSRV/ASRV/RORV` 和 `EXTR` 也已实现。
- `V82-SELECTED-EXT`：`EXT-FP-012`（标量 FP16 memory LDR/STR H）为 blocked，
  当前不实现。
- 保留/负测：`ADDG/SUBG` (MTE)、非法 bitmask、MOV 保留 opc、非法移位等均
  按 UDEF/保留处理；manifest 有 `negative` 列。

## 4. 系统寄存器、异常、权限、barrier/maintenance

- P6 Linux 系统寄存器集合见 `docs/ISA_SCOPE.md`，包括 EL1/EL0 读写、只读 ID、
  SVE/SME probe shim、debug shim、`PAR_EL1`/`CONTEXTIDR_EL1`（v4 已加入恢复
  字段）。
- EL2/EL3：QEMU 配置 `-cpu max,el3/el2=off`，EL2 寄存器读 0/写忽略；无虚拟化/
  安全态实现。
- 异常：UDEF/SVC/IABT/DABT/IRQ 入口和 `ERET` 均已与 QEMU step 模式差分；
  IRQ 只在普通 WB 提交边界取走；FIQ 未实现。
- 权限：MMU AP/PAN/UXN/PXN/W^X、EL0 系统寄存器 trap 等与 QEMU 矩阵一致。
- Barrier/maintenance：已实现 ISB/DSB/DMB/SB、DC CVAP/CVAC/CVAU/CIVAC/IVAC/
  ZVA、IC IALLU/IVAU、TLBI EL1 基线、AT 系列。未实现的 `DC CVADP`、TLBI
  OS/RV/range、EL2/EL3 maintenance、完整缓存一致性归 POST-V82-DEFERRED。
- `CONTEXTIDR_EL1`：live core 已实现（reset 0，EL1 读写，EL0 UDEF）；
  checkpoint sidecar v4 已加入恢复字段，AUD-12（T-20260829-117）已完成
  QEMU/DUT 联合恢复验证（见 05/09）。

## 5. SVE / POST-V82 后置

| Item | 状态 |
| --- | --- |
| SVE vector state / 指令 / SVE2 / SME | `V82-SVE-EXCLUDED`，未实现；仅保留 Linux probe shim（ZCR/SMCR/RDVL/RDSVL 等） |
| PAuth | 仅 key 寄存器 shim/写掩码，不实现指令/签名 |
| RCpc load-acquire PC-rel | `DEF-RCPC-001` deferred |
| MTE | `DEF-MTE-001` deferred |
| MOPS | `DEF-MOPS-001` deferred |
| 其它 LSE128 族与多核一致性 | `DEF-LSE128-001` deferred |
| Crypto/AES/SHA/PMULL | `DEF-CRYPTO-001` deferred |
| FP exception enable/trap / 完整 IEEE 异常 | `DEF-FPEXC-001` deferred |
| 剩余 FP/Advanced SIMD 家族 | `DEF-FP-REMAIN-001` deferred |
| 剩余 Cache/TLB maintenance | `DEF-MAINT-001` deferred |
| PMU 事件计数 | P9 后置 |
| EL2/EL3 | 后置/off |

## 6. QEMU lockstep 绑定

- 参考模型：QEMU 11.1.0 固定 release + 13 个 patch；插件 `lcvex_difftest.c`。
- 运行配置：`-machine virt -cpu max -accel tcg,thread=single -icount
  shift=0,align=off,sleep=off`；无 FP lite 线另加 `vfp=off,neon=off,
  vfp-d32=off`。
- 协议：逐指令 `PRE/COMMIT`、严格 seq 对应、commit packet 字段比较；
  同步异常和异步 IRQ 以 `exc_code` 进入 COMMIT；FP 使用 raw-bit
  V/FPCR/FPSR delta + `LCVXFP01` checkpoint。
- 差分覆盖：Gate D 定向/随机、P6 Linux lite 35M、FP/NEON 定向 A76 矩阵。
- 已知限制：QEMU 多 vCPU 锁步（C 线）尚未实现，仅完成 D0 可行性设计。

## 7. 声明边界

- 当前“支持”严格限于 V82-BASE + V82-SELECTED-EXT 清单中的已实现行，
  不包含未列出的可选扩展。
- SVE256 仍是 P8 后置，不因 probe shim 而算作 SVE 实现。
- 完整 ARM memory model、RCpc、LSE128 多核、cache coherence 仍需多核/后续线。
