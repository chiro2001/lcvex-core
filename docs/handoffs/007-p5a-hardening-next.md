# LCVEX 交接文档 007：进入 P5a-Hardening（依据外部评估）

日期：2026-08-23（Asia/Shanghai）
基线：`main` @ `b1a7302`（P5a-2 完成，工作区除文档外干净）
前置：001–006 交接 + **`docs/PROJECT_STATUS.md`（外部评估，权威依据）**

## 1. 为什么本交接存在

用户用 GPT-5.6 Sol（xhigh）对项目做了质量评估并留下 `docs/PROJECT_STATUS.md`，
结论是：验证基础设施成熟，但 **P3/P4/P5a 的功能完成度不能按现有 Gate 文案
理解**；在开发 P5b（Cache）之前必须先做 P5a-Hardening 与内存接口重构。
随后用户压缩上下文。本文件把评估要点、我的实测发现与下一步顺序固化下来。

## 2. 仓库状态（压缩时）

- `main` HEAD = `b1a7302`；工作区未提交：`README.md`（+文档索引）、
  `docs/PROJECT_STATUS.md`（评估文档，待确认后入库）。
- QEMU fork 基线 11.1.0 `84f0721` + 补丁 `qemu/patches/0001-*`（工作区
  为基线+patch，未提交；分支 `lcvex-step-hook` 保留提交版）。
- conda 环境 `lcvex`；`CONDA_RUN = conda run --no-capture-output -n lcvex`。

## 3. 外部评估的核心结论（摘要）

### 状态口径（对外建议）

- 验证基础设施：P4/P5a 主路径已具备（trace、socket 锁步、精确 step hook、
  失败诊断窗口）。
- 处理器功能：**P3 支持子集稳定，P4/P5a 为受限实现，Gate D 未进入**；
  不要对外宣称“P0–P4 已收敛、可直接开发 Cache”。

### R0：开始 P5b 前必须关闭

1. **MMU AP 权限矩阵错误**（`lcvex_mmu.perm_fault`）：EL1 读写对 AP=00
   的处理与 ARM 标准不一致；评估认为 EL0 read 对 AP=10 也有争议。**以 QEMU
   为权威参考**：加 4×AP × EL0/EL1 × read/write 全组合差分后按 QEMU 行为
   修正（不能只信评估文案，QEMU `target/arm/ptw.c` 是最终裁决）。
2. **AF 未检查**：注释声称 AF 必须置位，但 L3 页描述符未检查 AF。
3. **NZCV 位域错误**：`MRS/MSR NZCV` 应在 `[31:28]`，当前 decoder 用低 4 位；
   且 `a64.py` 未列出 nzcv 编码，路径未被差分覆盖。
4. **decoder 严格性**：ADD/SUB 立即数缺 `shift=LSL #12`；MOV wide 保留
   `opc=01` 被当写零；ADD/SUB extended-register 可能被宽松掩码误认；
   分支保留位未检查。随机只生成已知合法编码，无法暴露这些。
5. **提交脉冲依赖气泡**：WB 以 `memwb_valid` 0→1 边沿提交，靠单端口 SRAM
   自然气泡工作；Cache 连续退休会漏提交。应改显式 `commit_fire`
   （valid/ready 消费一个 entry）。
6. **Store 副作用无握手**：Store 在 EX/MEM 直接拉 SRAM 写使能，无
   request/response；可变延迟/backpressure 下有重复/错写风险。
7. **内存边界只查首地址**：多字节访问靠近 SRAM_TOP 回绕，需显式 fault。

### R1：Gate D 前必须关闭

- MMU 一致性：TTBR gap/canonical、TG/TnSZ 合法性、描述符保留位、AF、
  PA 合法性、跨页访问；SCTLR/TCR/TTBR 修改后无 TLB 失效、TLBI 未实现。
- 异常状态：commit 只带 ESR.EC，无 ESR_EL1/FAR_EL1/ISS；ERET 非法状态、
  对齐 fault、精确 syndrome 缺失。
- `lcvex_core.sv` 接近千行、控制集中；应先抽 fetch/data/PTW 接口与
  stage advance/kill 协议。
- 无 SVA（单提交、顺序、无重复 Store、flush kill、request 保持等）。
- CI 只跑 lint+SV smoke+ALU Cocotb；差分/异常/MMU/随机未进 CI。
- `qemu/scripts/apply-patches.sh` 用 `checkout -f` 丢改动、且不幂等。

### R2：Linux 前必须关闭

- 缺逻辑立即数、bitfield/移位别名、LDP/STP、pre/post index、
  register-offset 访存、MADD/MSUB、conditional select、独占/原子、barrier。
- 无固定 AArch64 交叉工具链/ELF 装载/裸机 C 回归。
- P6 所需 timer/IRQ/GIC、WFI、更多 EL1 系统寄存器、Device 语义未设计。

## 4. 我（上一会话）自己的实测补充

### P5b-1 Cache 尝试已回退

我实现了分离 I/D L1（直接映射 2 KiB×2、写通、读分配）并接入核心，修过：
取指对齐移位、命中判定用错锁存地址、I/D 与 MMU 遍历争用 SRAM 端口、
提交脉冲漏连续指令（改过“WB 接受当拍提交”）。但**随机 10 万回归持续暴露
流水线时序问题**：缓存未应答（mem_hold）期间 ID/EX 与 EX/MEM 的冻结/推进
交互导致指令重复/丢失，多轮未收敛。已整体回退到 `b1a7302`（无缓存代码）。

经验（与评估 R0.5 一致，印证“先重构内存握手再做 Cache”）：
- WB 提交边沿依赖气泡是真实问题（我实测漏掉过连续指令的提交）。
- 可变延迟接入点必须统一 `valid/ready`，不能靠“冻结整条流水线”打补丁。
- 应该先给流水线加“同一条指令不得同时驻留相邻两级”之类的周期级断言，
  再加缓存。

## 5. 后续任务顺序（按评估，严格分支）

1. `verify/p5a-hardening-tests`：先加能暴露 AP/AF/NZCV/decoder 问题的
   失败测试 + 支持矩阵（`ISA_SCOPE.md` 精确化）。
2. `feature/p5a-arch-fixes`：修已知架构语义，跑 P0–P5a 全回归。
3. `feature/commit-memory-handshake`：stage fire（`commit_fire`）+ 内存
   request/response 重构，随机延迟与 SVA。
4. `infra/full-regression-ci`：fast + difftest 门禁进 CI；干净 QEMU patch
   重放任务。
5. `feature/p5b-l1-cache`、`feature/p5b-l2-cache`（M2 模块化实现）。

对应文档：`docs/PROJECT_STATUS.md` 的 M0–M4 与“回归与 CI 建议分层”是权威
执行依据；`DEVELOPMENT_PLAN.md`/`ROADMAP.md`/`ISA_SCOPE.md` 在修复时同步
更新（评估要求 Gate 状态必须能链接具体 CI run 或回归摘要）。

## 6. 压缩后建议的第一步

按顺序 1 开始：建分支 `verify/p5a-hardening-tests`，写定向测试
（优先 NZCV `[31:28]`、MOV wide opc=01→UDEF、ADD/SUB imm shift、
AP 全矩阵、AF=0），让它们先失败，再进入 `feature/p5a-arch-fixes` 修复。
注意：所有架构语义以 QEMU 实跑为最终裁决，评估文案有疑问时先查
`../qemu` 的 `target/arm/ptw.c`/`translate-a64.c` 并用锁步验证。
