# LCVEX 交接文档 021：R1 - ESR_EL1/FAR_EL1 完整 syndrome 完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 020（空流水线取指 fault 完成）、PROJECT_STATUS R1。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（完整 ESR/FAR syndrome）

异常提交从仅比较 ESR.EC 升级为完整 ESR（EC<<26 | IL | ISS）与 FAR_EL1，
Linux 前必需的精确 syndrome 架构状态落地。

### 1.1 QEMU fork（qemu/patches/0001-...patch 更新并重放）

- `lcvex_exc_note` 增加 `esr`（完整 syndrome）与 `far`（故障地址）；
- `qemu_lcvex_difftest_note_exception` 在异常入口后捕获
  `env->exception.syndrome` 与 `env->exception.vaddress`；
- `take_exception` 导出 `*esr`/`*far`。

### 1.2 插件/协议/协调器

- `lcvex_commit` 增加 `exc_far`/`exc_esr`；
- 插件填充并随异常 COMMIT 发送；协调器在 exc_valid 时严格比较
  `exc_code/exc_esr/exc_far`（不一致即失败，失败转储打印三者）。

### 1.3 RTL

- `commit_packet_t` 增加 `exc_esr/exc_far`；soc_tb/TB 端口透出；
- 核心新增 `esr_el1`（32 位）/`far_el1`（64 位）寄存器，MRS/MSR 支持
  （decode op0=3,op1=0,crn=5,crm=2 / crn=6,crm=0）；
- 异常入口：ESR_EL1 每次异常都写（EC<<26|IL|ISS），FAR_EL1 仅
  IABT/DABT 写故障地址（QEMU 语义：UDEF/SVC 不更新 FAR）；
- 各异常源 syndrome 生成：
  - UDEF：0x02000000（EC=0、IL=1）；
  - SVC：0x56000000 | imm16；
  - IABT/DABT（翻译/外部中止）：`abort_esr(EC, wnr, fsc)`；
- MMU 输出 `fault_fsc` 与 `tlb_level`：翻译 fault=0x04+level、
  AF=0x08+level、权限=0x0C+level、输出 PA 越界=0x10（外部中止）、
  TxSZ>48（tsz_oob）与 TTBR gap=0x04（level 0）；
- 数据/取指翻译完成均锁存 `trans_fsc_r`/`fetch_fsc_r`（含失败路径，
  修复 fsc 只锁成功分支的 bug）；imem 响应 fault 用 0x10。

### 1.4 经验证修正的语义细节

- mmu 关闭时访问未映射地址（如 0x50000000）：QEMU 报同步外部中止
  （DFSC=0x10），不是翻译 fault；
- TTBR gap：QEMU 在 level 0 报翻译 fault（FSC=4）；
- `movz x5,#0x100010` 的 imm16 截断使 TCR 实际为 0x10（T1SZ=0 ->
  tsz_oob），QEMU 报 level 0 翻译 fault，RTL 需显式 tsz_oob 检查。

## 2. 验证结果（本机实跑）

- `make test`（含更新后的 MMU TB）全绿。
- 新增 `hard_esr_far`：DABT 后 handler 用 MRS 回读 ESR_EL1/FAR_EL1，
  验证 syndrome 与故障地址架构可见；基础/全缓存锁步与 QEMU 一致。
- 全套异常用例（p4b/p4c/p5a/hardening 17 组/M2-R1 16 组/delay2）在
  完整 ESR/FAR 比较下全部 PASS。
- `run_gate_d.sh`：51 项子检查全部 PASS。

## 3. 设计取舍与已知限制

- 数据中止 ISS 采用 no-ISS 形式（FnV/EA/CM/S1PTW=0，WnR+FSC），与
  QEMU TCG 对常规访存的模板一致；带 ISV 的精确访问 syndrome 留待
  Linux 需要时扩展。
- 外部中止（0x10）用于“PA 不在 RAM”与 mmu 关闭越界访问，与 QEMU
  virt 机器未映射区语义一致；真实总线错误模型后续再细化。
- ERET 目标越界按外部中止 IABT 处理（mmu 关闭场景）。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）；
  QEMU fork patch 已更新并重放（apply-patches.sh 幂等校验通过）。
- R1 剩余：SCTLR/TCR/TTBR 写后失效（可选）、交叉工具链/ELF/裸机 C、
  MMU 起始级别按 T0SZ 计算（完整化）。
