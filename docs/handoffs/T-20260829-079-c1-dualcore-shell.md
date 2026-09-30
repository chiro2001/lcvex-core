# T-20260829-079 C1 双核壳层（owner handoff）

状态：**owner review candidate**。

```text
task=T-20260829-079 state=review base=3d717e763209923f5ddaedeeeafa9d0b9985ba6c head=fe16e1be08196db1d9496d42172581fe37973017 branch=feature/T-20260829-079-c1-dualcore-shell worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-079 sent_at=2026-08-29T02:26:00+0800 received_at=2026-08-29T04:32:17+0800 reported_at=2026-08-29T04:32:17+0800 files=rtl/lcvex_cluster_pkg.sv,rtl/lcvex_core_wrap.sv,rtl/lcvex_cluster_top.sv,tb/sv/lcvex_cluster_tb.sv,sim/cocotb/test_lcvex_cluster.py,scripts/mc_shell_check.sh,docs/handoffs/T-20260829-079-c1-dualcore-shell.md,docs/tasks/evidence/T-20260829-079.json tests=C1/C2 verilator-lint-pass,directed-SV-TB-PASS blockers=core-MPIDR-read-hardcoded,no-public-core-wfi-port,C1-clock-gating-not-PSCI next=integrator-review
```

## 目标与结论

- 新增参数化 `lcvex_cluster_top`，通过 `CORE_COUNT` 复制 `lcvex_core_wrap`。
- 每个 wrapper：
  - 实例化未修改的 `lcvex_core`（`rtl/lcvex_core.sv` 只读）；
  - 拥有独立私有 `lcvex_mem_ram`，通过 `lcvex_mem_arb` 直连
    imem/dmem/PTW（C1 旁路 cache，不使用共享地址内存）；
  - 具有独立 start/stop/reset、`core_id`/`mpidr` 输出、独立 `irq`/`event_in`/
    `timer_phys_irq`/`timer_virt_irq`；
  - 输出本地可观察的 MC commit envelope（`core_id/vcpu_seq/event_kind` +
    原 `commit_packet_t` payload）和扁平 per-core commit 观测。
- C1 **不做 coherence**：没有共享 L2 目录、没有跨核 snoop、没有 MSI/MESI、
  没有 ACE/CHI，不声明完整 ARM 内存模型。两个核使用不同私有 RAM/缓存路径。
- `CORE_COUNT=1` 时同一 cluster 只生成一个 wrapper；现有单核
  `lcvex_catapult_soc_top` 路径未修改，`rtl/filelist.f`/`Makefile` 未改动。

## 实现文件

- `rtl/lcvex_cluster_pkg.sv`：MC envelope/event 类型/等待指令编码常量。
- `rtl/lcvex_core_wrap.sv`：per-core 生命周期状态机、真实 core 实例、私有
  缓存/内存、WFI/WFE/event 观测、commit envelope。
- `rtl/lcvex_cluster_top.sv`：`CORE_COUNT` 参数化顶层，逐核实例化和 SEV
  广播（仅作为 WFE/SEV event，不是 coherence）。
- `tb/sv/lcvex_cluster_tb.sv`：双核定向 SV TB。
- `sim/cocotb/test_lcvex_cluster.py`：Cocotb 层等效定向测试。
- `scripts/mc_shell_check.sh`：本地 L0/L1 检查入口。

## C1 边界 / 已知限制

1. `lcvex_core` 没有公开 event 输入或 WFI/WFE 状态输出，因此 wrapper 使用
   `difftest_wait_release` 仿真 sideband 作为 event wake，并用提交编码做
   wrapper 级 WFI/WFE 观测。这是 C1 壳层/验证路径，不宣称 ARM 架构 event 端口。
2. `lcvex_core` 的 `MPIDR_EL1` 读值仍是单核硬编码 `0x80000000`（不可改
   `lcvex_core.sv`）；本任务只在 wrapper/cluster 对外暴露 per-core `mpidr`
   输出，不声称 MRS 已区分核。
3. start/stop 使用时钟门控冻结核状态，不是 PSCI/架构电源状态，不保证
   stop 边界为“在途事务全部结束”的严格 checkpoint 语义。
4. 双核没有共享内存，因此没有跨核 data sharing/atomic/barrier 验证；这些
   留在 C2。
5. 未运行完整 Gate D；本任务只做 L0/L1（本地 lint / 定向 SV 测试）。

## 验证摘要

- `scripts/mc_shell_check.sh`（或等价命令）：
  - `git diff --check`；
  - Verilator lint：`CORE_COUNT=2` cluster + directed SV TB；
  - Verilator lint：`CORE_COUNT=1` 参数化顶层。
- 定向 SV TB 覆盖：
  - 双核初始 STOPPED、独立 start；
  - per-core `mpidr` 区分；
  - core0 先运行、core1 保持 stopped；
  - core0 WFI/event 唤醒；
  - core1 独立 WFI/IRQ 唤醒；
  - stop 冻结 core1；
  - per-core reset 清 vcpu_seq 并重新 start；
  - MC envelope `core_id/version`。
- 具体命令、退出码和结果见 `docs/tasks/evidence/T-20260829-079.json`。
- 定向 SV TB 已在 `build/mc_cluster_tb_fix6` 跑通：`LCVEX_C1_SHELL_TB PASS`。
- 本机 Verilator 生成的 Makefile 默认 `AR=x86_64-conda-linux-gnu-ar` 不存在，
  需用 `make AR=ar` 绕过；该问题已在实际构建中处理。

## 下一步

1. 集成者 review；若接受，进入 C2 双核 MSI 或按计划先补 reference-model
   /litmus 多核回放。
2. 后续若需要真正 arch event/MPIDR/PSCI，必须扩展 `lcvex_core.sv` 或另开
   串行核心任务，不能在本 C1 非一致性壳层中偷偷修改。
