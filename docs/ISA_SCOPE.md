# ISA 实现范围

> 2026-08-29 B0 审计注：本文档记录 P6 本地冻结的标量主体；P7 已实现的
> FP/Advanced SIMD 选定子集、SVE/SME 排除与 POST-V82-DEFERRED 后置项，
> 以 [`docs/V82_PROFILE_MANIFEST.md`](V82_PROFILE_MANIFEST.md) 的机器可检查
> 清单为准。本文只做少量过时表述修正，不替代该清单。

## 当前实现状态（P6 本地冻结，2026-08-26）

冻结候选 `b2568a506088ac34ef1529975b120a3f0849b0c1` 已满足本地 P6 退出
口径：T-043 的 Gate D 全量回归通过，T-044 的无 FP lite fresh-root
锁步运行 35,000,000 条并到达 `/init ready`。这代表本地功能验收事实；正式
Gate E、`main` 晋级和 CI 仍按阶段回顾结论待定，不等同于完整 ARMv8.2 覆盖。

以下指令已在 RTL 解码器/ALU/核心（5 级顺序流水线）中实现，并通过与
QEMU 11.1.0 的逐指令差分比较（Gate D 定向/随机、异常/MMU 与 P6
Linux 锁步）：

这里的实现矩阵由 RTL、Gate D 定向/随机用例和 Linux 动态窗口共同取证；
T-044 的 Linux 35M 窗口只覆盖实际执行到的族，不能推导为每个实现族都由
Linux 路径执行。

- 数据处理：
  - `ADD/ADDS/SUB/SUBS/CMP/CMN`：立即数（X/W，含 `sh=1` 的
    `LSL#12`）、移位寄存器（X/W，LSL/LSR/ASR）与扩展寄存器
    （`uxtw/sxtw/uxtb` 等选项 + 移位，非 S 形式支持 SP）
  - `AND/ANDS/ORR/EOR`：移位寄存器（X/W）与逻辑立即数
    （bitmask，`mov w,#0xf0f0f0f0` 等）；取反族
    `BIC/BICS/ORN/EON`（bit21=1，含 `MVN=ORN xzr` 别名）
  - `SBFM/UBFM`（X/W）：ASR/LSR/LSL 立即数、SXTB/SXTH/UBFX 等
  - `BFM`（X/W，含 `BFI/BFXIL/BFC` 别名）：位域插入，字段外保留旧 Rd
  - `MOVN/MOVZ/MOVK`：X/W，hw×16 移位
    - 保留 `opc=01` -> UDEF（不再当写零）
  - `MUL/UDIV/SDIV`：X/W，多周期（64 位 64 周期、32 位 32 周期），
    除零结果 0，SDIV 按幅值运算
  - `UMULH/SMULH`：X 形式，多周期 64x64 无符号/有符号乘积高 64 位
  - `MADD/MSUB`（X/W，32 位结果截断低 32 位）与
    `SMADDL/SMSUBL/UMADDL/UMSUBL`（32x32 -> 64，有/无符号扩展），
    复用多周期乘除单元（Ra 为初始累加，减族在其上减乘积）
  - `CSEL/CSINC/CSINV/CSNEG`（X/W）：条件真取 Rn，假取 Rm（+1/取反/
    取负），条件按 ID 级前递 NZCV 求值，与 B.cond 同机制
  - `LSLV/LSRV/ASRV/RORV`（X/W）：寄存器给出的移位量按数据宽度掩码，
    包括 32 位 `Rm[4:0]` 与 64 位 `Rm[5:0]`
  - `ADC/ADCS/SBC/SBCS/NGC/NGCS`（X/W）：按 PSTATE.C 完成带进位/借位
    运算并在 S 形式更新 NZCV
  - `RBIT/REV/REV16/REV32/CLZ/CLS`（W/X）及 `CCMP/CCMN`（立即数/
    寄存器形式）
  - `CRC32/CRC32C`（ARMv8 CRC extension）：`B/H/W/X` 数据宽度，采用
    ARM 指定的 reflected IEEE/ Castagnoli 多项式，Rm 从低字节向高字节
    消耗；seed/结果为 W 寄存器，结果始终零扩展至 Xd
- 分支：`B/BL`、`B.cond`（14 条件）、`CBZ/CBNZ`、`TBZ/TBNZ`、
  `BR/BLR/RET`；`B.cond` 的 `cond=1111` 与 QEMU 一致按无条件分支处理
- 访存：`LDR/STR`（unsigned immediate、pre/post-index、寄存器偏移
  `[rn, rm, lsl #s]`，8/16/32/64 位）、`LDRSB/LDRSH`（unsigned
  immediate 与寄存器偏移两种寻址，W/X 符号扩展宽度正确）、`LDRSW`、
  `LDP/STP`（offset/pre/post，X/W 对，双/三写回）、`LDR（literal）`
  （W/X/LDRSW，PC 相对 ±1 MiB）、`PRFM`（NOP）
- 地址：`ADR/ADRP`
- 系统指令：`SVC #imm`（EC 0x15）、`ERET`、`MRS`/`MSR`
  （`VBAR_EL1/ELR_EL1/SPSR_EL1/SCTLR_EL1/TCR_EL1/TTBR0_EL1/
  TTBR1_EL1/MAIR_EL1/NZCV`，EL1 权限；NZCV 对 EL0 开放）
  - `NZCV` 读写位域为 `[31:28]`（PSTATE 语义）
- `HVC #imm16` / `SMC #imm16`：按 QEMU virt 的 HVC PSCI conduit 作为
  普通顺序提交；已实现 `PSCI_VERSION`（返回 1.1）、`PSCI_FEATURES`、
  `MIGRATE_INFO_TYPE`（无 Trusted OS 时返回 2）、单核 `AFFINITY_INFO`、
  单核 `CPU_ON` 最小返回集，
  未实现的函数返回 `PSCI_RET_NOT_SUPPORTED`。SYSTEM_OFF/RESET、CPU_OFF/
  SUSPEND 的停机/电源状态语义留待多核/平台阶段。
- 屏障与等待：`ISB/DSB/DMB/SB` 在顺序核上排空并按提交边界重取，
  `WFI/WFE/WFIT/WFET/SEV/SEVL` 的 idle、事件、Generic Timer/GIC 唤醒
  已纳入 P6 锁步；这些不是占位语义。
- 其他：`NOP`；XZR/SP 语义（ADD/SUB 立即数 Rd=31 写 SP、S=1 丢弃、
  Rn=31 读 SP）、32 位写入高 32 位清零、逻辑 flag-setting 清零 C/V。

### 解码边界（已支持/未支持/保留编码可证明）

- `ADD/SUB` 扩展寄存器（`bit21=1`）移位量 `sa>4` 的保留编码 -> UDEF。
- `ADD/SUB` 立即数 `bit23=1` 的编码属于 `ADDG/SUBG`（MTE）指令族，
  不在支持范围 -> UDEF。
- `MOVZ/MOVK/MOVN` 保留 `opc=01` -> UDEF；32 位 `hw>1` -> UDEF。
- `B.cond` `cond=1111` 按无条件分支处理（与 QEMU `trans_B_cond` 一致）。

### MMU（P5/P6 本地冻结权限与边界矩阵）

页描述符字段按 ARMv8 VMSAv8-64 标准：`AP[1:0]=desc[7:6]`、
`AF=desc[10]`、`UXN=desc[54]`、`PXN=desc[53]`、`OA[47:12]`。
数据权限矩阵与 QEMU `simple_ap_to_rw_prot` 一致：

| AP | EL1 读 | EL1 写 | EL0 读 | EL0 写 |
| --- | --- | --- | --- | --- |
| 00 | 允许 | 允许 | fault | fault |
| 01 | 允许 | 允许 | 允许 | 允许 |
| 10 | 允许 | fault | fault | fault |
| 11 | 允许 | fault | 允许 | fault |

取指权限与 QEMU `get_S1prot` 一致：

- EL1：`PXN=1` 或页面可被 EL0 写（AP=01，W^X 规则）-> fault；UXN 不影响。
- EL0：`UXN=1` 或无 EL0 读权限（AP=00/10）-> fault；PXN 不影响。

其他 MMU 行为：

- `AF=0`（TCR_EL1.HA=0）-> AccessFlag fault，不填充 TLB。
- L0/L1/L2 无效或块描述符（当前不支持块）-> 翻译 fault。
- PA 越出 RAM（`0x40000000..0x48000000`，128 MiB，与 QEMU virt 对齐）-> fault。
- T0SZ/T1SZ 区间的 gap（非 canonical VA，如 T0SZ=16 下的
  `0x1000000000000`）-> 翻译 fault。
- TLB：64 项全相联、单级，按 VA[47:12] 匹配；TLBI EL1 全集（VMALLE1/VAE1/ASIDE1/VAAE1/VALE1/VAALE1，IS 与非 IS）统一按整表失效超集语义（P6，见 043）；SCTLR/TCR/TTBR 写后自动失效未做（R1 项）。EL1 数据翻译实现 PSTATE.PAN：PAN=1 时拒绝 AP=01/11 的 EL0 可访问页，TLB hit 与 page walk 一致。

### 同步异常（P4b，全部与 QEMU 差分一致）

- 未定义指令/保留编码 -> EC 0x00（UDEF）
- EL0 访问 EL1 系统寄存器（VBAR/ELR/SPSR）-> EC 0x00（UDEF）
- `SVC` -> EC 0x15
- 取指地址超出 1 MiB SRAM -> EC 0x20/0x21（IABT，EL0/同 EL）
- Load/Store 地址超出 1 MiB SRAM -> EC 0x24/0x25（DABT，EL0/同 EL）
- 分支/ERET 到越界地址与 QEMU 一致地合并为 IABT 提交
- 异常入口：`ELR_EL1`（SVC=pc+4，其余=pc/目标地址）、`SPSR_EL1`、
  PSTATE->EL1h+DAIF 全置位+NZCV=0、SP 切 `SP_EL1`；
  `ERET` 恢复 PSTATE/SP 并跳转 `ELR_EL1`

### 真实标量余量（不影响 P6 本地退出）

- 逻辑移位寄存器形式的 `ROR`（logical shifted-register 的 `shift_type=3`；
  `ADD/SUB` shifted-register 的对应编码是保留编码并按 UDEF 处理；
  `LSLV/LSRV/ASRV/RORV` 和 `EXTR` 已实现）
- MOPS、MTE 的 `ADDG/SUBG` 与标记访存，以及 RCpc `LDAPR/LDAPUR`；这些
  扩展不属于当前 ARMv8.2 标量冻结子集
- TLBI OS/RV/range、`DC CVADP`、EL2/EL3 维护和完整缓存一致性
- 其它 LSE128 原子族与多核一致性，以及 PMU 访问；未识别 SYS 空间仍按
  UDEF 处理

## 第一阶段标量子集

### 数据处理

- `MOVZ`、`MOVK`、`MOVN`
- `ADD`、`ADDS`、`SUB`、`SUBS`
- `AND`、`ANDS`、`ORR`、`EOR`
- `LSL`、`LSR`、`ASR`
- `CMP`、`CMN`
- `MADD`、`MSUB`
- `RBIT`、`REV`、`REV16`、`REV32`、`CLZ`、`CLS`（P6）
- `CCMP`、`CCMN`（立即数/寄存器，P6）
- `CRC32/CRC32C`（`B/H/W/X`，P6）

### 分支

- `B`、`BL`
- `BR`、`BLR`、`RET`
- `B.cond`
- `CBZ`、`CBNZ`
- `TBZ`、`TBNZ`

### 地址和访存

- `ADR`、`ADRP`
- `LDR`、`STR`
- `LDR`（literal，PC 相对；含 LDRSW 与 PRFM literal）
- `LDP`、`STP`
- `LDXR/STXR/LDAXR/STLXR/CLREX`（单寄存器 exclusive；M3）
- `LDAR/STLR`（B/H/W/X，顺序单发射核按普通访存；P6）
- 单寄存器 LSE 原子（P6）：`LDADD/LDCLR/LDEOR/LDSET`、`LDSMAX/LDSMIN`、
  `LDUMAX/LDUMIN`、`SWP` 的 B/H/W/X 形式及 `ST*`（`Rt=XZR`）别名；
  `CAS/CASA/CASL/CASAL` 的 W/X 形式。核心按“读旧值→条件计算→写回”
  两阶段事务执行，返回旧值和 Store 副作用均纳入锁步比较。
- `CASP/CASPA/CASPL/CASPAL` 的 X 寄存器对形式（LSE128，P6）：四阶段
  低读/高读/低写/高写事务，比较失败不产生两段 Store。
- `LDCLRP`、`LDSETP`、`SWPP`（LSE128，P6）：QEMU `atomic128` 固定编码，
  `rt2=bits[20:16]`，仅支持 X 寄存器对；低/高半独立读、计算、写回，
  旧值写回 `rt/rt2`，提交包上报两个 8B Store。16B 对齐、SRAM/MMIO
  窗口及 MMU 跨页翻译在首个 Store 前预检；a/r 按顺序核 full barrier
  处理。完整 LSE128/多核一致性不在当前范围。
- `CNTPCTSS_EL0/CNTVCTSS_EL0`（FEAT_ECV 兼容视图，P6；与对应 CNT* 同值）
- `WFI/WFE`（P6）：等待指令正常退休后进入 idle；QEMU TCG idle 回调与
  协议同步，Generic Timer/GIC IRQ 唤醒产生独立的异步 IRQ 提交；SEV/SEVL
  设置单核事件寄存器。单核范围内 WFE/WFET 会消费本地事件寄存器。
- `WFIT/WFET Xt`（P6，FEAT_WFxT 标量等待）：Xt 作为 `CNTVCT_EL0` 的
  绝对超时值；未到期时进入 idle，到期后恢复到下一条指令，WFET 优先消费
  已置位事件。QEMU fork 的 `wfxt_timer` 与插件 idle/resume 路径纳入锁步；
  实际 halt 恢复时，plugin 将 QEMU 的 `CNTVCT_EL0` 经 `WAIT_RESUME`
  sideband 交给协调器重基准 DUT 虚拟计时；QEMU `cpu_has_work()` 立即返回
  时不发送该 sideband，协调器只注入非架构 wake event，不伪造时间流逝。
  EL0 陷阱矩阵、跨核 SEV 广播和调试单步的完整架构语义仍不在本阶段范围。
- `BTI`（hint，按 NOP；P6）
- 字节、半字、字、双字访问
- 基本 unsigned、pre-index、post-index addressing
- `LDUR/STUR` 族（非缩放 9 位有符号偏移，P6 Linux 启动实证缺口）：
  `STUR/STURW/STURH/STURB`、`LDUR/LDURW/LDURH/LDURB`、
  `LDURSW`、`LDURSB/LDURSH`（X 与 W 形式符号扩展）、`PRFUM`（NOP）；
- `LDR/STR` 单寄存器 pre/post-index（P6 Linux 启动实证缺口，
  `ldrb w6,[x0],#1` 等）：8/16/32/64 位 + 符号扩展 X/W 形式，正/负
  9 位偏移，基址写回（Rn=31 为 SP；XZR 无写回）；
- CSEL 族别名（汇编助记符，同一编码）：`CSET/CSETM`（条件取反的
  `CSINC/CSINV xzr,xzr`）、`CINC/CINV/CNEG`（同寄存器 `CSINC/CSINV/
  CSNEG`）。
- `DC ZVA`（按 DCZID_EL0 块大小清 64B，8×8B 写；QEMU 插件不记账，
  协调器以 RTL 侧清零为准）、`DCZID_EL0`（只读，QEMU virt=4）。

### MMIO（P6：PL011 UART，与 QEMU virt 一致）

- 地址窗口 `0x09000000..0x09001000`；MMU 翻译 PA 落入窗口不报 fault，
  且**强制不可缓存**（bypass L1D/L2，Device 语义）；
- MMU 关闭时（裸机/earlycon 前）直接访存窗口地址放行（不 DABT）；
- PL011 寄存器子集按 QEMU 11.1.0 `hw/char/pl011.c` 复刻并差分验证：
  `UARTDR`（TX + INT_TX，LBE 回环入 RX FIFO）、`UARTRSR/ECR`、
  `UARTFR`（TXFE 恒 1；RXFE/RXFF 由 FIFO 决定）、`UARTILPR`、
  `UARTIBRD`（掩 0xFFFF）、`UARTFBRD`（掩 0x3F）、`UARTLCR_H`（FEN
  切换重置 FIFO）、`UARTCR`（LBE 时 FR 调制位映射）、`UARTIFLS`、
  `UARTIMSC`、`UARTRIS`、`UARTMIS`、`UARTICR`、`UARTDMACR`、
  Peripheral/PrimeCell ID（0xFE0..0xFFC）；
- 复位：`CR=0x300`、`IFLS=0x12`、`FR=0x90`，其余 0；RX FIFO 深度
  `FEN ? 16 : 1`，空读返回残留字节（QEMU 同语义）。

exclusive 监视器语义（与 QEMU 实测一致）：LDXR 记录 clean VA 与加载值；
STXR 在地址相等且内存当前值（按 STXR 宽度截取）等于记录值时写入并返回
0，否则不写并返回 1；STXR 无论成败、CLREX、ERET、复位都清监视器；
A profile 异常入口（SVC/UDEF/Abort）不清。STXR 的条件写只在监视器通过
时才发生，地址 fault 也只在该路径出现（QEMU gen_store_exclusive）。

### 系统指令初始范围

- `NOP`
- `SVC`、`ERET`、`MRS`、`MSR`、`HVC/SMC`（PSCI 最小子集）、`ISB`、
  `DSB`、`DMB`
- `MSR（immediate）`：`DAIFSet`、`DAIFClr`、`SPSel`、`ALLINT`（P6）
- `AT S1E1R/W`、`AT S1E0R/W`（`S3_0_C7_C8_0..3`）以及
  `AT S1E1RP/WP`（`S3_0_C7_C9_0/1`）：EL1 地址翻译；E0 形式使用
  EL0 权限，P 形式在 PSTATE.PAN=1 时使用 PAN regime。结果只在 AT
  提交边界写入 `PAR_EL1`；成功结果包含 QEMU 的 LPAE/NS/ATTR/SH 字段，
  失败置 PAR fault/FSC；MMU 关闭时按直接映射处理。
- `DC CVAP`（`S3_0_C7_C12_1`）：EL1 或 EL0（需 `SCTLR_EL1.UCI=1`）
  可执行；当前无持久介质模型，按无副作用维护提交，不产生伪 Store。
- `MRS/MSR DAIF`（`S3_3_C4_C2_1`）：读写 `PSTATE.DAIF`，映射到寄存器
  `[9:6]`；`DAIFSet/DAIFClr` 立即数操作独立保留。
  若写后 `I=0` 且 GIC IRQ 已 pending，在同一条 MSR/DAIFClr 的提交边界
  转入 IRQ（而不是延迟到下一条普通 WB 指令）。
- `MSR ALLINT,#imm`（`d501401f/d501411f`）和 `MRS/MSR ALLINT`
  （`S3_0_C4_C3_0`）：EL1 可访问，值映射到 PSTATE bit13；SPSR/ERET/
  checkpoint 均保留该位。QEMU 仅在 `SCTLR_EL1.NMI=1` 时用 ALLINT
  屏蔽普通 IRQ，RTL 同时保留可见状态与实际屏蔽条件。
- checkpoint/异常路径保留 `PSTATE.PAN`（SPSR bit22）与 `PSTATE.DIT`
  （SPSR bit24），以对齐 Linux IRQ handler 的 `MRS SPSR_EL1`；PAN 权限
  检查和 DIT 时序约束仍不是本阶段的完整 ISA 实现。
- `OSLAR_EL1`/`OSDLR_EL1`（`S2_0_C1_C0/C3_4`，P6 debug shim）：QEMU
  debug helper 的 RAZ/WI dummy 寄存器，Linux 写入/读取均不改变架构状态
  （OSLAR 只允许写入，读取仍按 QEMU 报 UDEF）。
- `DBGBVR[n]_EL1`、`DBGBCR[n]_EL1`、`DBGWVR[n]_EL1`、`DBGWCR[n]_EL1`
  （`S2_0_C0_Cn_4..7`，P6 debug-monitor 关闭 shim）：Linux early boot
  写零关闭 6 个 breakpoint 与 4 个 watchpoint；P6 对该关闭用法 RAZ/WI，
  读零。非零比较器、调试异常与外部调试接口留待 P9。

### P6 Linux 启动系统寄存器（与 QEMU `-cpu max,el3/el2=off` 一致）

只读（MRS 返回 QEMU 复位值）：`CurrentEL`（=EL<<2）、`MIDR_EL1`、
`REVIDR_EL1`、`ID_DFR0/1_EL1`、`ID_AA64PFR0/1/DFR0/1/2/ISAR0/1/2/MMFR0/1/2/3/ZFR0/SMFR0_EL1`、`CTR_EL0`、
`CNTFRQ_EL0`（1GHz）。

读/写（复位 0）：`CPACR_EL1`、`MDSCR_EL1`、`PMUSERENR_EL0`（写掩
低 4 位，QEMU pmuserenr_write）、`CNTKCTL_EL1`、`TPIDR_EL0`、
`TPIDRRO_EL0`、`SP_EL0`、`TCR2_EL1`（写掩 `PIE|AIE|A2|FNG0|FNG1`
= 0x70012）、`PIR_EL1`、`PIRE0_EL1`。

P6 兼容 SVE/SME 探测（均不实现向量状态）：
- `ZCR_EL1`（S3_0_C1_C2_0）保存/读取 LEN 低 4 位；`RDVL #imm` 返回
  `imm × (LEN+1) × 16`（QEMU sve_vq.map 覆盖 0..15，无截断）。
- `SMCR_EL1`（S3_0_C1_C2_6）保存/读取 LEN 低 4 位；`RDSVL #imm` 按
  QEMU `SVE_VQ_POW2_MAP`（VL 128/256/512/1024/2048）把 LEN 取整到
  “最高支持档”后再算字节数（例如 LEN=14 -> 有效 7 -> 128 B）。
- `SMPRI_EL1`（S3_0_C1_C2_4）为 RES0（QEMU SMIDR_EL1.SMPS=0），
  读 0、写忽略，且写不影响 SMCR。
- `SMIDR_EL1`（S3_1_C0_C0_6）与 `AIDR_EL1`（S3_1_C0_C0_7）只读 0
  （QEMU IMPDEF/IMPLEMENTOR=0）。
- `CSSELR_EL1`（S3_2_C0_C0_0，QEMU opc1=2）只保留 Level[3:1]+Ind[0]
  低 4 位读写（QEMU csselr_write 掩 0xf）。
- `RNDR`/`RNDRRS`（S3_3_C2_C4_0/1）只读：真实值随机无法差分，difftest
  下 QEMU fork 与 RTL 一致返回“当前指令可见计数”并置 NZCV=0000。

正式 checkpoint sidecar v3 已纳入：v2 的 ZCR/SMCR/CSSELR 基础上补齐
`PMUSERENR_EL0`、`TCR2_EL1`、`PIRE0_EL1` 与 exclusive monitor；v1/v2
旧链仍可读，但新增寄存器按 reset、monitor 按无效恢复，见 handoff 092。

`EXTR`（Data-processing extract，`ror #imm` 的编译器/alternatives
别名）：`{Rn, Rm} >> lsb`，32/64 位均支持，已纳入 hard_p6_isa。

`PAR_EL1` 由上述 AT 变体更新，也可由 EL1 `MRS/MSR` 读写；复位值为 0，
AT 的结果更新延迟到指令提交。成功值按 QEMU `do_ats_write()` 编码
LPAE/NS/ATTR/SH（例如 Normal RAM attr0=0xff、非 shareable 页为
`0xff000000<PA>000a00`）；失败值保留 fault/FSC，写入不改变地址翻译状态。

EL2 寄存器（el2 关闭，读 0 写忽略）：`SCTLR_EL2`、`HCR_EL2`、
`VBAR_EL2`。

### P6 Generic Timer（差分语义与 QEMU `-icount shift=0` 对齐）

- `CNTPCT_EL0`/`CNTVCT_EL0`（只读）：计数器 = **已执行指令数**（QEMU
  icount shift=0 下 1 虚拟 ns/指令、CNTFRQ=1GHz；RTL 每提交 +1，读时
  +1 含本指令）；`CNTVCT = CNTPCT`（CNTVOFF_EL2=0）；
- `CNTP_CTL_EL0`/`CNTV_CTL_EL0`：bit0=enable、bit1=imask；
  `ISTATUS`（bit2）读时组合计算 = `enable && (count >= cval)`（QEMU
  定时器在 icount 指令边界精确触发，读即最新）；
- `CNTP_TVAL_EL0`/`CNTV_TVAL_EL0`：读 = `(uint32_t)(cval - count)`；
  写 = `cval = count + sext32(value)`（QEMU do_tval_write）；
- `CNTP_CVAL_EL0`/`CNTV_CVAL_EL0`：cval 原样读写；
- `WFIT/WFET` 的超时比较使用同一 `CNTVCT` 指令边界计数；等待期间 RTL
  仅推进仿真计数，不产生架构提交，QEMU 超时恢复后直接发送下一条 PRE；
- 中断输出 `timer_phys_irq/timer_virt_irq`（供 GIC；非差分提交状态）；
- 差分前提：QEMU 锁步/trace 统一加 `-icount shift=0,align=off,sleep=off`
  （无 icount 时计数器为宿主时间抖动，不可差分——探针实测）；
- EL0 定时器访问按 CNTKCTL gate 与 QEMU EC=0x18 trap 对齐（T-017）；
  其它未列出的 EL0 系统寄存器仍按既有权限矩阵处理。

### P6 PL061 GPIO（QEMU virt `0x09030000..0x09030fff`）

非安全 PL061 保留为原生、可综合的 SystemVerilog 外设，不纳入后续的 C++
MMIO fabric。当前实现与 QEMU virt 的非 Luminary 变体对齐：

- `GPIODATA` 的地址掩码 aperture、`GPIODIR`、`GPIOIS/IBE/IEV/IM/RIS/MIS`、
  `GPIOICR` 与 `GPIOAFSEL`；
- Peripheral ID (`0xfe0..0xfec`：`61 10 04 00`) 与 PrimeCell ID
  (`0xff0..0xffc`：`0d f0 05 b1`)；
- QEMU virt 对未驱动引脚的下拉行为：P6 仿真顶层固定输入为 0，因此不会
  产生非确定性的 GPIO 中断；输出方向和数据寄存器仍按硬件语义保存。

`hard_pl061` 在无 Cache 与 I/D L1+L2 配置下均逐指令锁步通过。P10 的板级
顶层应把 8 个 GPIO 输入/输出/方向信号显式映射到 pin，并把 `gpio_irq` 接入
GIC 的 SPI7（GIC INTID 39）；这属于板卡、约束和具体 I/O 电气标准确定后的
集成工作，不应提前耦合到 P6 的确定性仿真顶层。

### P6 C++ MMIO fabric / PL031 RTC（`0x09010000..0x09010fff`）

不适合在 P6 逐一实现为 RTL 的 QEMU virt 外设经 `lcvex_mmio_fabric` 的 M1-B
bridge 进入 Verilator 链接的 C++ model。bridge 固定一拍响应；C++ model 与
SV/Cocotb/microbench/锁步协调器使用同一源文件，未知已分派地址记录
PA/方向/字节使能/数据后返回可复现 fault，不依赖运行时 QEMU。

首个模型为 ARM PrimeCell PL031：`DR/MR/LR/CR/IMSC/RIS/MIS/ICR` 与
`0xfe0..0xfff` 的 PrimeCell ID（`31 10 14 00 0d f0 05 b1`）。锁步 runner
固定使用 `-rtc base=2000-01-01T00:00:00,clock=vm`；RTC 以已退休指令的
`1 ns/条` 虚拟时间推进，消除宿主时间不确定性。PL031 的 C++ 状态作为
`.dev.mmio.gz` 纳入新差分 checkpoint 链；旧链没有该 sidecar 时只能恢复为
fabric reset，不能宣称已恢复其设备状态。

### P6 GICv2/GICv2m（MMIO 0x08000000..0x08021000，单核无安全扩展）

GICD/GICC 维持原有 0x08000000..0x08020000 语义；GICv2m frame
0x08020000..0x08021000 提供 MSI_TYPER/IIDR 只读探测和受限 SETSPI_NS。

- GICD：`CTLR`（EN_GRP0/1）、`TYPER`（0x8）、`IIDR`（0x43b）、
  `IGROUPR`、`ISENABLER/ICENABLER`（读均返回 enabled；SGIs 写强制
  置位/清位忽略）、`ISPENDR/ICPENDR`（读返回 pending；SGIs 写忽略）、
  `ISACTIVER/ICACTIVER`、`IPRIORITYR`、`ITARGETSR`（单核 RAZ/WI）、
  `ICFGR`（SGIs 强制 edge）、`SGIR`、`SPENDSGIR/CPENDSGIR`；
- GICC：`CTLR`（掩 0x21f）、`PMR`、`BPR`、`IAR`（确认：置 active、
  清 pending）、`EOIR`（清 active）、`RPR`（空闲 0xff）、`HPPIR`、
  `ABPR`（复位 1）、`IIDR`（0x2043b）；
- CPU 接口：best_irq = enabled && pending && !active，优先级低值优先、
  低编号破平；`current_pending` 需 `best_prio < PMR` 且组使能；IRQ 线
  = `best_prio < PMR && best_prio < running_priority && GICD/GICC 组使能`；
- 复位值全部 QEMU 探针实证（ISENABLER0=0xffff、ICFGR0=0xaaaaaaaa、
  ABPR=1、IAR/HPPIR=0x3ff、RPR=0xff）。

### P6 异步 IRQ 入口

- 核心新增 `irq` 输入；IRQ 在**普通 WB 提交边界**取走（`daif.I=0` 且
  非同步异常提交）：ELR=被中断指令的下一条、SPSR=当前 PSTATE、
  PSTATE -> EL1h + DAIF 全置、向量 = `VBAR + (EL1h ? 0x280 : EL1t ?
  0x80 : 0x480)`、`exc_code = 0x40`（协议专用码，非 ESR.EC）；
- QEMU fork step 模式把异步异常（IRQ/FIQ）转为 exc_code=0x40 的
  COMMIT（lcvex_difftest.c vcpu_discon），与 RTL 一致；
- 已知限制：IRQ 只在普通提交边界取走（MSR/ERET 等 sys 提交后不
  抢占，下一普通指令边界补取）；FIQ 未实现（GICC_CTLR.FIQ_EN=0）。

## 后续标量功能

P6 已实现的变量移位、屏障、等待/事件和当前维护子集不再列为待办。仍需
单独立项的标量余量与上方“真实标量余量”一致：

- 逻辑移位寄存器形式的 `ROR`（`LSLV/LSRV/ASRV/RORV` 与 `EXTR` 已支持；
  `ADD/SUB` shifted-register 的 `shift_type=3` 是保留编码）；
  RCpc `LDAPR/LDAPUR`、MOPS/MTE 等扩展也不在当前冻结子集
- 其它 LSE128 原子族与多核一致性（当前仅实现 `CASP` 及
  `LDCLRP/LDSETP/SWPP` 的单核事务语义）
- 其余 Cache/TLBI maintenance 与 PMU 访问

## FP/NEON 阶段（B0 审计已更新为现状）

P7-0～P7-5 已实现 `V82-SELECTED-EXT` 中登记的 FP/Advanced SIMD 子集，
包括 V/FPCR/FPSR/FPEN、标量 FP32/64/16 算术/比较/FMA/转换/sqrt/min/max/
rint、NEON 整数与单 Q 访存、NEON FP 与向量 FMA/转换/sqrt/min/max/rint。
这是协议冻结的选定子集，不是完整 ARMv8.2-A FP/Advanced SIMD。

仍未实现并明确后置/UDEF 的剩余 FP 族（饱和、narrow/widen、permute、table、
across-lane、结构化/lane/replicate/pair 访存、estimate、完整 FP 异常 trap、
标量 `LDR/STR H` 等）见 `docs/V82_PROFILE_MANIFEST.md` 的 blocked/deferred 行。

SVE256/SME 不属于本轮 V82 非 SVE profile；SVE 相关 shim 仅为 Linux 探测兼容。

## SVE256 阶段

暂定实现 ARMv8.2-A 基础 SVE，固定实现向量长度 `VL=256 bit`：

- `Z0`～`Z31` 向量寄存器
- `P0`～`P15` 谓词寄存器
- `FFR`
- 谓词算术和逻辑
- 向量 Load/Store
- 基本整数和浮点向量运算
- 向量长度相关系统语义

暂不实现 SVE2，除非后续需求明确提出。
