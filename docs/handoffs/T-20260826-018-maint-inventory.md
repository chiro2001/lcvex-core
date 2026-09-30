# T-20260826-018：维护指令支持矩阵审计

日期：2026-08-26（Asia/Shanghai）  
基线：`5e17f56e85ebcd82f081262f8338ed3b99ca12ee`  
证据：[T-20260826-018.json](../tasks/evidence/T-20260826-018.json)

## 结论

- ARMv8.2-A AArch64 的 E1 TLBI 基线 12 项（`VMALLE1[IS]`、
  `VAE1/ASIDE1/VAAE1/VALE1/VAALE1[IS]`）均可由 binutils 2.47
  `-march=armv8.2-a` 汇编，QEMU 11.1.0 `tlb-insns.c` 有对应 cpreg，当前
  decoder 的 `CRn=8, CRM={3,7}, op2={0,1,2,3,5,7}` 已覆盖。没有真实
  ARMv8.2 TLBI 缺口；`VMALLE1OS`、RV* 等需更高扩展，不能列为本阶段任务。
- IC 基线 `IALLUIS/IALLU/IVAU` 和 DC 基线 `IVAC/ISW/CVAC/CVAU/CIVAC/ZVA`
  已在 decoder/core 维护状态机中识别。历史 `ISA_SCOPE` 的“维护子集未完成”
  需改成精确支持矩阵，而不是泛化派单。
- 真实 ARMv8.2 缺口为 `DC CVAP`（编码 tuple `op0=1,op1=3,CRn=7,CRm=12,op2=1`，
  `d50b7c20`）以及 `AT S1E0R/S1E0W`（`d5087840/d5087860`）和
  `AT S1E1RP/S1E1WP`（`d5087900/d5087920`）。当前 decoder 只接受
  `AT` 的 `CRM=8, op2={0,1}`，因此漏掉这四个可执行编码。

## 权限与提交语义边界

| 指令 | QEMU 权限/语义 | 当前 RTL 状态 |
| --- | --- | --- |
| `DC CVAP` | `PL0_W`；`aa64_cacheop_poc_access` 要求 EL0 的 `SCTLR_EL1.UCI`，写回 cache line；`SUPPRESS_TB_END` | 未识别；应沿 DC 维护路径 ID 排空后提交，当前无 cache 时可保持 NOP，但权限必须与 UCI 对齐 |
| `AT S1E0R/W` | `PL1_W`；使用 EL0 translation regime，读/写权限由 op2 低位选择；结果写 `PAR_EL1`，不产生数据异常 | 未识别；现有 `MAINT_AT` 只按 EL1 regime 翻译 |
| `AT S1E1RP/WP` | `PL1_W`；`CRM=9`，E1 regime；QEMU 在 PAN 开启时选择 PAN translation regime；结果写 `PAR_EL1` | 未识别；需要携带 permission/PAN 模式，不能简单别名 S1E1R/W |
| E1 `TLBI` 12 项 | `PL1_W`，EL0 执行应 UDEF；QEMU 各变体有独立 cpreg，但当前单核实现可统一整表失效超集 | 已识别并 ID 排空、发 `tlb_invalidate` 脉冲；decoder 需补 `op1==0` 精确约束，避免把保留 op1 编码误接纳 |

## 任务边界

建议把 `DC CVAP` 与四个 `AT` 变体作为一个串行维护指令任务：写集为
`rtl/lcvex_pkg.sv`（维护枚举/AT 模式字段）、`rtl/lcvex_decode.sv`、
`rtl/lcvex_core.sv`（维护提交与翻译 regime）、`sim/difftest/a64.py`、
`sim/difftest/test_program.py`、registry 和文档。它们共享 decoder/core，
不应与另一维护实现或系统寄存器 shim 并行修改；QEMU fork 不需要改动。定向
测试至少覆盖权限拒绝、`PAR_EL1` 成功/故障结果、PAN/E0/E1 模式和 CVAP 的
提交无内存副作用边界。

TLBI/IC 当前没有 ARMv8.2 实现缺口；后续需补精确 op1 负向测试并收紧文档。
尤其是当前 TLBI 条件未约束 `op1==0`，可能把 `op1=4` 的 E2 TLBI 在
`has_el2=false` 配置下误接纳为 E1 失效，而 QEMU 应按 EL2 权限/关闭状态
UDEF。IC/DC 也应按 QEMU 精确 tuple 拒绝非目标 op1。
`DC CVADP`、TLBI OS/RV/range、EL2/EL3 变体属于更高扩展或关闭的执行级别，
不应混入本任务。

## 风险

QEMU fork 工作树存在既有本地 difftest 修改；本审计未修改或重建 QEMU。证据
绑定 QEMU commit `84f07211cc5b4fc6a371559bf8a5de4fb068e648` 及相关源文件 SHA，
实现任务仍须在指定 QEMU 11.1.0 上复核 `CPAccessResult` 与提交时机。
