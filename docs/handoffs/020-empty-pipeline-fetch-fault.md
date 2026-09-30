# LCVEX 交接文档 020：R1 - 空流水线取指 fault 合成提交完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 019（块描述符完成）、PROJECT_STATUS R1。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（空流水线取指 fault 合成提交）

关闭 handoff 016 记录的已知限制：系统指令（MSR）提交使 MMU 状态改变后，
下一条取指翻译失败时流水线已空，此前无法把 IABT 合并到任何提交而挂死。
同时修复一个潜在死锁：mmu_en=1 时任意 MSR 因 `fetch_next_settled` 永不
满足而卡住。

### 1.1 RTL 改动（lcvex_core）

- **前瞻 MMU 状态**：ID 级 MSR 提交前，取指翻译按提交后的状态进行——
  `mmu_en_eff/tcr_eff/ttbr0_eff/ttbr1_eff/mair_eff` 在对应系统寄存器
  MSR 于 ID 时取 `d.sys_wdata`，否则取当前架构值；MMU 实例接入这些
  前瞻输入。
- **MSR 提交条件**（`sys_commit_ready`）：
  - mmu_en=0 的非 SCTLR MSR、SCTLR MSR 关闭 M：立即提交（原行为）；
  - 其余 MSR（含使能 MMU 的 SCTLR、mmu_en=1 时任意 MSR）：等待
    `fetch_next_settled`（下一条取指翻译完成），翻译失败经
    `sys_fetch_merge` 把 MSR 提交合并为 IABT（与 QEMU step 插件把异常
    合并到前一条指令的 pending 提交语义一致）。
- **取指路径**：`fetch_req_valid`/`fetch_imem_req_valid`/
  `fetch_imem_req` 的 MMU 使能条件改用 `mmu_en_eff`；`sys_fetch_redirect`
  扩展到 SYS_MSR。

### 1.2 测试

- `hard_sys_fetch_fault`：MMU 使能（msr sctlr）后下一条指令位于未映射页
  （0x44001000），取指翻译 fault 合并到 msr 的提交为 IABT（EC=0x21，
  ELR=0x44001000）；此前 RTL 挂死，现在与 QEMU 锁步。
- `hard_msr_mmu_on`：MMU 开启后执行 msr tcr_el1（写回同值），验证
  mmu_en=1 时 MSR 提交不阻塞、下一条已映射取指正常继续。
- 两者均加入 M2/R1 定向（base + 全缓存 + delay2）与 hardening 套件。

## 2. 验证结果（本机实跑）

- `make test` 全绿。
- `run_m2_4b.sh`：14/14（base 7 + l1dl2 全缓存 7）。
- hardening 16/16、p4c/p5a/p4b 全部锁步一致。
- `run_gate_d.sh`：47 项子检查全部 PASS。

## 3. 设计取舍与已知限制

- 前瞻状态只覆盖 MMU 相关系统寄存器（SCTLR/TCR/TTBR/MAIR）；其他系统
  寄存器 MSR 的提交无需等待下一条取指（取指翻译不依赖它们）。
- RTL MMU 的遍历结构固定为 48 位 4 级（不按 T0SZ 计算起始级别）；
  T0SZ != 16 时与 QEMU 的行走级别可能不一致，属后续 MMU 完整化范围，
  现有测试均用 T0SZ=16。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- R1 剩余：ESR_EL1/FAR_EL1 完整 syndrome（含锁步协议扩展）、
  SCTLR/TCR/TTBR 写后失效（TLBI 已支持，写后自动失效可选）、
  交叉工具链/ELF/裸机 C、MMU 起始级别按 T0SZ 计算。
