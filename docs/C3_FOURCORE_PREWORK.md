# LCVEX C3 四核前置设计与任务拆分（C3-pre）

> 任务：T-20260829-089（C3-pre）
> 状态：**设计/契约拆解，不代表 4 核功能已完成**
> 日期：2026-08-29
> 基线：`7c847561d3de3edeee0f7f8937fd3929fc101ba6`
> 分支：`feature/T-20260829-089-c3-fourcore-prework`
> worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-089`
> 关联：`docs/MULTICORE_CLUSTER_CONTRACT.md`、`docs/LCVX_DIFF_MC_V2.md`、
> `docs/T-20260828-071-073-parallel-lines-plan-v2.md`、C1/C2 handoff。

## 0. 重要边界

1. 本任务只做 **C3 的前置设计、差距分析和子任务拆解**。
2. **C2 双核 MSI 尚未关闭**：当前 base 只有 C2 模块级目录 MSI 已合入，
   真实双核指令级 litmus/CAS/barrier 和完整系统验证仍未通过；因此本任务
   **禁止实现或实例化 4 核功能 RTL**。
3. 本任务未修改 `rtl/`、`tb/`、`sim/`、QEMU、checkpoint 协议或任何功能代码。
4. C3 的实际功能实现任务只有在 C2 关闭、且集成者批准相应 G-MC 依赖后才可派发。
5. 本文件中的信号名、地址、状态机、子任务粒度均为设计建议，不替代 I0/C0
   已批准契约；最终 RTL 接口以集成后冻结版本为准。

---

## 1. 结论先行

- C3 的目标是 **4 核正确性 candidate**，不是 8/16/32 核功能验收，也不是
  Linux SMP。可接受口径按 v2 计划：4 核在目录/仲裁/中断/启动/维护/压力上稳定，
  单核和双核不回归。
- C3 相比 C2，主要新增的是 **系统级控制面**：每核 GIC CPU 接口、PSCI 启停、
  SGI/IPI、SEV/WFE 路由、TLB shootdown、共享 MMIO 路由、4 核公平仲裁，以及
  MC-v2/checkpoint 的异步事件与全局序列扩展。
- C3 可先独立准备的是 **纯设计/验证口径**：MC-v2 事件矩阵、checkpoint v4
  manifest 字段、GIC/PSCI 地址与函数矩阵、4 核测试目录、资源上限和回归清单。
- C3 真正的 RTL 切片应延迟到 C2 系统接线和真实双核指令级证据闭合之后。
  建议第一片是 **把 C2 目录/仲裁从隐式 2 核泛化为 4 核参数化**，因为它最靠近
  已合入的 `lcvex_l2_cluster`，且不依赖 GIC/PSCI。

---

## 2. 现状盘点（基于只读浏览）

### 2.1 本 worktree 中已合入的多核资产

| 资产 | 文件/位置 | 现状 |
| --- | --- | --- |
| C1 双核壳层 | `rtl/lcvex_cluster_pkg.sv`、`rtl/lcvex_core_wrap.sv`、`rtl/lcvex_cluster_top.sv`、`tb/sv/lcvex_cluster_tb.sv` | per-core 私有 RAM、独立 start/stop/reset、per-core IRQ/event/timer 观测、MC envelope；不做 coherence。 |
| C2 模块级 MSI | `rtl/lcvex_l2_cluster.sv`、`rtl/lcvex_cluster_pkg.sv`、`tb/sv/lcvex_c2_cluster_tb.sv` | 目录 I/S/M、ReadShared/ReadUnique/Upgrade/WriteBack/Clean/Invalidate/Bypass、per-core probe、PoC fault/abort、round-robin；模块级 TB 已通过。 |
| 单核平台 | `rtl/lcvex_gic.sv`、`rtl/lcvex_mmio_fabric.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_catapult_soc_top.sv` | GICv2 单核模型、MMIO fabric、共享内存路由、单核 SoC。 |

### 2.2 关键代码观察

1. **`lcvex_l2_cluster.sv` 表面上 `CORE_COUNT` 参数化，实际上有两处二核假设**：
   - `probe_target <= dir_owner[cur_idx][0] ? CORE_IDX_W'(0) : CORE_IDX_W'(1);`
   - `if (dir_sharers[cur_idx][1-arb_sel]) ... probe_target <= CORE_IDX_W'(1 - arb_sel);`
   - 这说明 C3 必须先泛化 target 选择，不能直接把 `CORE_COUNT=4` 当“已支持”。
2. C1/C2 的 `lcvex_core_wrap` 在 base 中仍是 C1 私有 RAM 路径；C2 系统接线
   （coherent L1 + cluster）位于同一仓库的
   `feature/T-20260829-086-c2-dualcore-msi` 分支（`e36cf4a`、`de668d3`），
   **尚未合入本 worktree**。该分支记录了 C2 系统 RTL 已接入但真实双核
   `lcvex_c2_dualcore_tb` 完整构建未完成。
3. `lcvex_core.sv` 的 `MPIDR_EL1` 仍为单核硬编码 `0x80000000`；
   `lcvex_core_wrap` 只在 wrapper 层输出 `mpidr=CORE_ID`，不改变核内 MRS 读值。
4. `lcvex_core.sv` 的异步事件是 `irq` 输入、`difftest_wait_release` 仿真旁路、
   内部 `event_reg`；没有公开的架构级 `event_in`/`event_out` 端口。
5. `tlb_invalidate` 是每核 1 周期脉冲，当前只驱动本核 MMU 整表失效；没有
   跨核广播、target 位图或 per-ASID/VA 粒度。
6. 现有 `lcvex_gic.sv` 只有一个 CPU 接口（GICC），GICD/GICv2m 为单核地址；
   没有 SGI/IPI 的路由表，也没有多 CPU 的 per-GICC 实例化。
7. PSCI 目前只在 decode 层做“单核最小返回集”：
   `CPU_ON(CPU0)` 返回 ALREADY_ON，其它 MPIDR 返回 INVALID_PARAMS；
   没有真实的核启动/停止控制面。
8. `lcvex_mem_router.sv` 是单 upstream、单 outstanding 的地址路由，MMIO 与
   RAM 共享同一条 M1-B 从端口；多核若直接复制会要求共享路由仲裁和每核 MMIO 旁路。

### 2.3 C2 未关闭的判定

`C2 双核 MSI` 的关闭标准不是“模块级 TB 通过”，而是至少：

- C2 系统接线（coherent L1 + `lcvex_l2_cluster` + `lcvex_cluster_top`）合入
  共同集成 SHA；
- 真实双核 `lcvex_c2_dualcore_tb`（或等价指令级工程）构建并运行通过；
- 双核 message passing、store/load buffering、CAS/LDXR-STXR、DMB/DSB/ISB、
  DC clean + IC invalidate + ISB、reset/fault 的定向证据闭合；
- `CORE_COUNT=1` 和 C1/C2 已知回归不破坏；
- `docs/tasks/active/T-20260829-086.json` 的状态从“integration pending”变为
  `done`/`closed`，并由集成者记录。

---

## 3. C3 所需子系统及设计要点

### 3.1 目标拓扑（建议）

```text
                lcvex_c4_system_top (C3 候选)
   +-------------------------------------------------------------+
   | core_wrap[0..3]                                             |
   |   lcvex_core + I-L1/D-L1 + per-core L1 coherent adapter    |
   |   per-core GICC / timer / event / MC commit / TLB          |
   +-----------------------------+-------------------------------+
                                 |
                  per-core coherent req / rsp + probe
                                 |
   +-------------------------------------------------------------+
   | lcvex_l2_cluster (C3 泛化)                                  |
   |   directory I/S/M, CORE_COUNT=4, sharer/owner 位图          |
   |   round-robin/fair arb, line pending, PoC 8B writeback      |
   +-----------------------------+-------------------------------+
                                 | PoC
   +-------------------------------------------------------------+
   | shared mem_router + shared RAM/MMIO/GICD/GICC*/PSCI regs    |
   +-------------------------------------------------------------+
```

### 3.2 GIC / PSCI / Timer

| 子系统 | C3 设计问题 | 建议 |
| --- | --- | --- |
| GIC | 需要共享 GICD + 每核 GICC；当前单核 GIC 模型只有一套 GICC。 | 保留 GICD 共享；按 `CORE_COUNT` 实例化 per-core GICC，每核 `irq` 来自各自 GICC。地址映射需冻结（例如 GICC 分页或 per-CPU offset）。 |
| PPI | 每核 Generic Timer 已由 `lcvex_core` 输出 `timer_phys_irq`/`timer_virt_irq`。 | 每核分别接 own GICC PPI，不共享；PPI 编号需与 QEMU/DTB 对齐。 |
| PSCI | 当前 decode 返回静态值；C3 需要真正控制多核 start/stop。 | 设计独立 `lcvex_psci`/cluster control：HVC CPU_ON 写入目标核 start/entry，CPU_OFF 触发停止；返回码由控制面产生，不再由 decode 静态伪造。 |
| 启动次序 | 上电后 core0 运行，core1..3 保持 STOPPED；PSCI CPU_ON 启动目标核。 | 由 cluster control 管理 `core_start_pulse`、复位向量、entry PC 和 per-core 状态；禁止所有核默认 AUTO_START。 |
| 电源状态 | C1 的 start/stop 是时钟门控，不是 PSCI/架构电源状态。 | C3 至少区分 RUNNING/STOPPED/QUIESCED/FAULT；CPU_OFF 与 quiesce 的停止点需在 commit 边界和内存事务 drain 后。 |

### 3.3 IPI / SEV / WFE

| 子系统 | C3 设计问题 | 建议 |
| --- | --- | --- |
| SGI/IPI | 需要把某个核的写 GICD_SGIR 映射到目标核 GICC 的 pending。 | 共享 GICD 中维护 per-core pending/active；目标核 GICC 产生 `irq`。SGI 路由必须与每核 `core_id` 对应。 |
| SEV | ARM SEV 向同 cluster 其它 PE 广播 event；SEVL 只置本核 event。 | C1 目前把所有 `sev_pulse` 广播到所有其它核；C3 需保留该语义并纳入 per-core event register；不能用 SGI 代替 SEV（事件不是中断）。 |
| WFE | 每核 event register 由自身 SEV 或广播 SEV、IRQ 唤醒。 | 应通过真实 event 端口或 wrapper 事件观测接入；目前 C1 用 `difftest_wait_release` 仿真旁路，C3 需明确改为架构级或至少 wrapper 级稳定接口。 |
| 异步事件提交 | 中断/唤醒需要进入 MC-v2 `ASYNC`/`WAIT` 事件流。 | 每核 `event_kind` 必须区分为 `COMMIT/ASYNC_IRQ/WFI/WFE/STOP/FAULT`，并按 `global_seq` 排序。 |

### 3.4 TLB shootdown

| 问题 | 建议 |
| --- | --- |
| 当前 MMU 只接受 per-core 全表失效脉冲 `tlb_invalidate`。 | C3 第一版可限制为“TLBI 只广播全表失效”，要求软件对每个受影响核执行相同维护；若后续需要 per-ASID/VA，再扩展为带 tag/shootdown 位图的协议。 |
| 跨核可见性 | 写页表后，其他核的 TLB 可能缓存旧映射。 | 由发起核执行 TLBI 后通过 cluster control 向目标核发送 invalidation 向量；每核需在 quiesce/事件边界接受并清 TLB。 |
| 与屏障/维护顺序 | 必须保证页表写入先完成，再 TLBI，再 ISB/事件确认。 | TLBI 事件应有明确顺序：完成本地/远程 TLB 失效后，发起核才能认为 shootdown 完成；禁止把 IPI 发送本身当作完成。 |
| checkpoint | TLB 状态目前不在 L1/目录 sidecar 中。 | C3 checkpoint 至少记录每核 TLB 全表失效 epoch 或整个 TLB tag；恢复后必须重放未完成的 shootdown。 |

### 3.5 共享 MMIO 路由

| 问题 | 建议 |
| --- | --- |
| 每核 MMU/核心都有 MMIO 窗口；多核不能每个核私有一份 UART/GICD。 | C3 在 cluster PoC 下游保持单一共享 `lcvex_mem_router`；cacheable 内存走目录，MMIO/device 走 bypass。 |
| GICD 与 GICC 地址 | GICD 是共享设备，GICC 是 per-core CPU 接口。 | 地址路由需要按 `core_id` 或接口实例把 GICC 访问送到对应 CPU 接口；不能所有核访问同一个 GICC 寄存器文件。 |
| UART/PL011 等共享外设 | 中断是共享外设到某一核（通常 core0）或可配置路由。 | 先固定共享外设中断路由到 core0；后续再扩展路由/亲和性。 |
| MMIO 响应一致 | C3 全局单事务目录可能把 MMIO 与 cacheable 请求串行化。 | 第一版可承受；性能优化（per-bank/非阻塞 MMIO）必须另立性能任务，不混入正确性验收。 |

### 3.6 公平仲裁

| 问题 | 建议 |
| --- | --- |
| C2 当前是单事务 round-robin，且 target 选择有 2 核硬编码。 | C3 先保持全局单事务、单 outstanding，把 round-robin 指针和 liveness fallback 泛化为 `CORE_COUNT` 位图；不接受 starvation。 |
| 公平性是否等于架构顺序 | 不是。仲裁顺序只是可重放调度，不等于 ARM 内存模型。 | 用受控交错集合与 deterministic token 记录；不把仲裁指针当作架构顺序。 |
| 4 核性能 | 全局单事务可能严重限制并行。 | 先正确性候选；per-bank 或每核队列作为 C4/性能扩展，不属 C3 验收。 |

---

## 4. 与 C2 当前接口的差距

| 维度 | C2 当前（base 或其未合入系统分支） | C3 需要 | 依赖/优先级 |
| --- | --- | --- | --- |
| 核数 | 模块级 `CORE_COUNT` 参数存在，但状态机内隐式 2 核的 target 计算。 | 4 核目录位图、owner/sharer 4 位、多 probe target 选择。 | 必须先做；低耦合。 |
| 系统接线 | base 无 coherent L1 接线；C2 分支有部分但仍未完成真实双核。 | 4 个 coherent L1 接入 cluster/top。 | 依赖 C2 关闭。 |
| GIC | 单 GICC；无多核 pending 路由。 | 共享 GICD + per-core GICC + SGI/IPI 路由。 | 依赖系统接线；中高阶。 |
| PSCI | decode 静态返回；无真实控制面。 | cluster PSCI 控制、CPU_ON/OFF、启动向量、停止/复位。 | 依赖生命周期接口；中高阶。 |
| Timer | per-core timer 已存在。 | 每核 PPI 直连各自 GICC；虚拟 timer 口径确定。 | 依赖 GIC。 |
| MPIDR | wrapper 输出 per-core `mpidr`，核内 MRS 仍硬编码。 | 要么改 `lcvex_core` 支持 MPIDR 参数，要么明确由软件/差分侧规避。 | I0 决策；影响所有核。 |
| SEV/WFE | C1 有 SEV 广播仿真路径，无架构 event 端口。 | 真实 event 输入/输出或 wrapper 级稳定事件。 | 与 GIC/IPI 一起。 |
| TLB | 每核全表失效脉冲；无跨核。 | TLBI 广播/目标失效 + 顺序确认。 | 依赖系统接线；可后置。 |
| MMIO 路由 | 单核单 upstream；多核未共享。 | 共享 router + GICD/GICC 分派。 | 依赖系统接线。 |
| MC-v2 | C1 envelope 已有字段，但 `global_seq=0`，无异步事件协调。 | 每核 `global_seq/vcpu_seq/event_kind` 可观察；ASYNC/WAIT 事件进入 v2 流。 | 与 GIC/SEV 联动。 |
| Checkpoint | C1 drain 输出 tie-off；无 v2 多核 sidecar。 | 每核 + 共享状态 v4 manifest，恢复顺序固定。 | 后置但需提前定字段。 |

---

## 5. C2 未关闭前不能做的事情

以下都是 **C3 实际功能实现前置条件**，在 C2 关闭前不得派发：

1. 不得在任何 worktree 中实例化 `CORE_COUNT=4` 的完整功能 cluster 并宣称通过。
2. 不得修改 `rtl/lcvex_core.sv` 的 MPIDR、event、TLBI 接口来“先支持 4 核”，
   除非有独立的串行核心接口窗口和 I0 批准。
3. 不得把 C2 分支的未完成系统接线当作 C3 基础；必须等其合入并复跑。
4. 不得修改共享 QEMU/checkpoint 协议以实现 MC-v2 多核事件流。
5. 不得写“Linux SMP 已支持”或“完整 ARM memory model 已验证”。

---

## 6. 可先独立准备的事项

这些事项不依赖 C2 最终闭合，可以在 C3 前以文档/测试计划/只读分析推进：

| 事项 | 可产出 | 备注 |
| --- | --- | --- |
| MC-v2 事件矩阵 | 每核 `COMMIT/ASYNC_IRQ/WFI/WFE/STOP/FAULT` 与 v2 消息 32..42 的映射表；`global_seq` 分配规则。 | 引用 `docs/LCVX_DIFF_MC_V2.md`，不修改共享 QEMU。 |
| Checkpoint v4 字段清单 | 每核 arch/timer/L1/GICC/proto、共享 L2/目录/GICD/scheduler token；版本、hash、恢复顺序。 | 可先在文档中冻结设计。 |
| GIC/PSCI 函数矩阵 | PSCI_VERSION/FEATURES/CPU_ON/CPU_OFF/AFFINITY_INFO/SYSTEM_OFF/RESET 的返回码和副作用；每核 GICC 地址。 | 对齐 QEMU virt/DTB。 |
| 4 核测试目录 | 启动次序、SGI/IPI、SEV/WFE、timer PPI、TLBI、MMIO 共享、压力测试清单。 | 不运行重型构建，只登记计划。 |
| C2 硬编码审计 | 扫描 `lcvex_l2_cluster`/`core_wrap` 中所有 `1-`、`[0]`、`[1]` 等 2 核假设。 | 为第一片泛化切片提供输入。 |
| 资源上限 | 4 个完整 `lcvex_core` + L1 + cluster 的 Verilator 编译/运行内存与时间估计；决定是否使用简化 model。 | 避免在 C3 功能任务中才首次发现资源爆炸。 |
| 仲裁/公平性定义 | round-robin/liveness 属性、单事务模型、允许的调度交错集合。 | 与 C2 现有 SVA 风格一致。 |

---

## 7. 每核异步事件、全局序列与 checkpoint 扩展

### 7.1 引用版本化 envelope

C3 必须围绕 `docs/LCVX_DIFF_MC_V2.md` 的 v2 envelope，而不是自行发明：

- `lcvex_mc_envelope` 字段：`version=2`、`core_id`、`global_seq`、`vcpu_seq`、
  `event_kind`、`flags=0`；`commit` 复用 v1 `lcvex_commit`。
- v2 新消息类型 32..42：`MC_INIT/PRE/GO/COMMIT/ACK/ASYNC/WAIT/WAIT_RESUME/STOP/DISCON/EXIT`。
- v2 事件边界：`PRE` 是执行前，`COMMIT` 只能代表退休后（或下一条同核
  before-callback 推导），`ASYNC` 覆盖 IRQ/FIQ/WFI 唤醒，`WAIT/WAIT_RESUME`
  覆盖 WFI/WFE/WFxT 真实 idle。

### 7.2 C3 对异步事件顺序的要求

1. **每核独立 `vcpu_seq`** 必须严格单调；一个核的 `vcpu_seq` 不因其他核
   事件改变。
2. **全局 `global_seq`** 由协调器/回放器分配；RTL 可通过侧带输出 `global_seq=0`
   表示“尚未接协调器”，但 C3 验收不得把 0 当作有效全序。
3. 每个异步事件（IRQ 进入、WFI/WFE idle、SEV/IPI 唤醒）应生成 `ASYNC` 或
   `WAIT/WAIT_RESUME` 事件，并且事件对架构状态的影响必须在 `global_seq`
   上有唯一线性化点。
4. 目录/MSI 事务的可见顺序（如 dirty owner 写回、Upgrade 失效）是内存
   线性化点；C3 的 event/IRQ 不得绕过目录直接改共享内存。
5. 禁止把“仲裁器先选中某核”解释为“该核事件先发生”；仲裁只解决资源竞争，
   不定义架构顺序。

### 7.3 C3 每核状态与 checkpoint 最小扩展

按 D0 第 8 节，C3 的 checkpoint 至少应包括：

| 类别 | 内容 |
| --- | --- |
| 每核架构 | GPR/SP/PSTATE/DAIF/EL/PC/next_pc/NZCV/ELR/SPSR、系统寄存器、exclusive monitor。 |
| 每核 timer | CNTPCT/CNTVCT 基准、CNTP/CNTV CVAL/CTL、CNTFRQ、offset/WFxT 超时。 |
| 每核 L1 | I/D-L1 tag/state/valid/dirty/data、victim/替换状态。 |
| 共享 L2/目录 | line metadata、MSI/I/S/M 状态、dirty owner、pending probe/transaction、quiesce/drain 状态。 |
| GIC/IPI/event | 每核 GICC、共享 GICD、SGI pending、IPI/event 位图、当前 IRQ 优先级。 |
| 全局调度 | 当前 token/仲裁指针、`global_seq` 水位、每核 `vcpu_seq` 水位。 |
| 每核协议 pending | 未完成 PRE/COMMIT/ASYNC/WAIT 列表、store 队列。 |

恢复顺序（建议，需与 C6 确认）：

```text
停发新请求/冻结 token
→ 恢复共享 L2/目录与内存一致性视图
→ 恢复每核 L1 metadata/data
→ 恢复每核架构/timer/exclusive
→ 恢复 GIC/IPI/event
→ 恢复每核协议 pending 和 global/vcpu 水位
→ 从对应 global_seq 下一事件继续
```

任何缺失 per-core sidecar、版本不匹配或 hash 不符，都必须拒绝恢复，不能
用 reset 值冒充成功。

---

## 8. C3 建议子任务拆分

> 共 4 片，按低耦合和推荐顺序排列。每片都是独立垂直切片，验收证据必须绑定
> 同一 SHA；在 C2 关闭前仅登记/规划，不派实现。

### 8.1 切片 C3-A：四核目录/仲裁参数化（推荐先做）

**范围**

- 把 `lcvex_l2_cluster` 从“模块级 C2 MSI”泛化为 `CORE_COUNT=4`：
  - 去掉 `dir_owner[0] ? 0 : 1`、`1-arb_sel` 等 2 核硬编码；
  - 定义 per-core probe target 选择函数：按 owner/sharer 位图循环；
  - round-robin 指针和 liveness fallback 支持任意 `CORE_COUNT`；
  - 目录 SVA 扩展到 4 核位宽（M owner one-hot、S sharers 非零等）。
- 保持 `CORE_COUNT=1/2` 行为不变，`CORE_COUNT=4` 只做模块级合成 L1 client
  验证，不接真实 4 核。
- 不修改 `lcvex_core.sv`、不接 GIC/PSCI。

**验收标准**

- `verilator --lint-only`：`CORE_COUNT=1/2/4` 均通过。
- 定向 SV TB：4 个 synthetic L1 client 覆盖 ReadShared 多 sharer、
  ReadUnique/Upgrade 多目标失效、dirty owner 唯一、bypass、PoC fault/abort。
- 目录 SVA 在 4 核下通过；`CORE_COUNT=1/2` 原 C2/C1 模块级回归不破坏。
- 不宣称真实 4 核指令级一致性。

**为何先做**：纯协议/仲裁泛化，紧挨现有已合入模块，不依赖 GIC/PSCI/TLB，
且它的失败会阻塞所有后续 C3 切片。

### 8.2 切片 C3-B：四核系统壳层与启动/共享内存接线

**范围**

- 在 C2 系统接线（coherent L1 + `lcvex_l2_cluster` + `lcvex_cluster_top`）
  合入并稳定后，把 `CORE_COUNT` 扩到 4。
- 接入 4 个 `lcvex_core_wrap` 的 coherent 路径、共享 PoC、共享 `lcvex_mem_ram`、
  共享地址路由。
- 实现启动次序：core0 默认启动，core1..3 保持 STOPPED；提供 per-core
  `start/stop/reset` 控制，最好与 PSCI 控制面解耦成可独立验证的接口。
- 每核独立 `MPIDR` 观测；若核内 MRS 仍硬编码，则明确为已知限制，不冒充架构正确。

**验收标准**

- `CORE_COUNT=4` 可 elaboration/编译；`CORE_COUNT=1/2` 回归。
- 4 核可分别启动/停止/复位；per-core commit envelope 可区分。
- 共享 RAM 上的 4 核 message-passing（不依赖中断）通过；每个核看到一致数据。
- 不宣称 GIC/IPI/PSCI/TLB 已实现。

**依赖**：C2 系统接线关闭；C3-A 完成。

### 8.3 切片 C3-C：GIC/PSCI/IPI/SEV/WFE 控制面

**范围**

- 多核 GIC：共享 GICD + per-core GICC；per-core timer PPI 接入；
  SGI 路由写入目标核 GICC pending；GICC 输出 `irq` 给对应核。
- PSCI 控制面：替代 decode 静态返回；CPU_ON/OFF、AFFINITY_INFO、FEATURES、
  SYSTEM_OFF/RESET 的差分边界。
- SEV/WFE：保留 C1 SEV 广播，增加 per-core event 吞入/唤醒；最好提供架构级
  event 端口或稳定的 wrapper 事件替代仿真旁路。
- 异步事件进入 MC-v2：每个 IRQ/WFI/WFE/SEV 相关提交打 `event_kind`；
  `global_seq` 由协调器或测试台赋值。

**验收标准**

- 4 核定向测试：core1 由 core0 写 GICD_SGIR 触发 IRQ；core1 从 WFI/WFE 唤醒。
- 每核 timer PPI 只影响本核；非目标核不收到该中断。
- PSCI CPU_ON 能启动目标核，CPU_OFF 能在提交边界停止，返回码与 QEMU
  参考矩阵一致（或明确记录为允许差异）。
- SEV 广播/SEVL 本核事件行为有定向测试。
- MC-v2 事件流中能区分 `ASYNC_IRQ/WFI/WFE` 且 vcpu_seq 正确。

**依赖**：C3-B；C0 中 MPIDR/start-stop 问题先由 I0 定案。

### 8.4 切片 C3-D：TLB shootdown、checkpoint v4 与 4 核压力

**范围**

- TLB shootdown：定义并实现 TLBI 广播/目标失效，以及 shootdown 完成确认。
  第一版可只做全表失效；per-ASID/VA 后置。
- Checkpoint v4：按第 7.3 节扩展每核/共享 sidecar 和 manifest；恢复顺序验证。
- 4 核长压力：混合 memory copy、message passing、IPI、timer、DC/IC 维护、
  随机 reset/fault 注入；记录资源/时间。

**验收标准**

- TLBI 后其他核不再使用旧 TLB 映射；shootdown 完成前发起核不提前返回。
- checkpoint 保存/恢复后 4 核从同一 `global_seq` 继续，GIC/IPI/event、
  L1/目录、schedule token 全部一致。
- 4 核压力窗口无丢失提交、无目录 dirty 冲突、无 stale response。
- 运行环境（Verilator build 内存/时间）和资源上限有记录。

**依赖**：C3-B/C3-C；建议最后做，因为它验证的是系统整体。

---

## 9. 风险登记

| ID | 风险 | 级别 | 说明/缓解 |
| --- | --- | --- | --- |
| R-C3-1 | C2 未关闭就进入 C3 | 阻断 | C2 系统接线和真实双核证据未闭合；C3 RTL 派单必须等待。 |
| R-C3-2 | `lcvex_l2_cluster` 2 核硬编码导致 4 核误报 | 高 | 先做 C3-A 泛化并以 4 核合成 client + SVA 验收；不把 `CORE_COUNT` 参数出现当作完成。 |
| R-C3-3 | 异步事件顺序与内存线性化不一致 | 阻断 | 每个 ASYNC/WAIT/中断必须有 `global_seq` 和目录/MMIO 线性化点；禁止用仲裁顺序或 QEMU host 顺序冒充。 |
| R-C3-4 | 共享内存/中断竞态 | 高 | IPI 与内存写、SGI 与 PPI、WFE 与 SEV 需要受控交错集合；第一版用单事务串行化降低竞态面。 |
| R-C3-5 | checkpoint 恢复遗漏每核状态 | 高 | 先定 v4 字段和恢复顺序；缺失 sidecar/版本/hash 拒绝恢复；不复用旧链。 |
| R-C3-6 | MPIDR/event 接口需改核心 | 高 | 可能需要修改 `lcvex_core.sv`，这是共享热点；必须经 I0 和集成者串行窗口，不能在 C3 切片偷改。 |
| R-C3-7 | PSCI/系统复位语义模糊 | 高 | SYSTEM_OFF/RESET 在现有差分中作为窗口终止；C3 若实现真实控制面，需要单独定义观察/恢复边界。 |
| R-C3-8 | TLB shootdown 粒度/顺序 | 中高 | 第一版全表失效并显式确认；per-ASID/VA 后置，不混入 C3 验收。 |
| R-C3-9 | 共享 MMIO/GIC 地址与 QEMU/DTB 不一致 | 高 | 先冻结地址映射和 per-GICC 分页；GIC/PSCI 矩阵与 QEMU 11.1.0 virt 对齐。 |
| R-C3-10 | 4 核 Verilator/仿真资源爆炸 | 高 | 先做资源 estimate；必要时用简化 memory/L1 模型跑 L0/L1，重型构建由集成者排队。 |
| R-C3-11 | 完整 ARM memory model 被过度宣称 | 阻断 | 只声明项目 litmus 子集和目录线性化点；不由 C3 宣称架构合规。 |
| R-C3-12 | 外部 coherent DMA 隐式引入 | 高 | 保持 non-coherent DMA/board 外设；若有需要另建 ACE/CHI/snoop bridge 任务。 |

---

## 10. 非目标 / 已知限制

- 本任务不是 4 核功能实现，不产出 4 核 RTL、TB、QEMU 或 checkpoint 代码。
- 不实现 8/16/32 核功能；不宣称 Linux SMP 已支持。
- 不修改共享 `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv`、filelist、Makefile、
  QEMU、checkpoint 协议。
- 不引入 ACE/CHI、E/O、coherent DMA 或完整 ARM memory model。
- C3 仍以“4 核正确性 candidate”为口径；任何 4 核长跑或板级证据都不能替代
  C2 关闭和集成者 G-MC 门。

## 11. 参考资料

- `docs/MULTICORE_CLUSTER_CONTRACT.md`：C0 契约、C1/C2/C3 边界、I0 问题。
- `docs/LCVX_DIFF_MC_V2.md`：D0 可行性、v2 envelope、事件边界、checkpoint 扩展。
- `docs/L1_L2_PROBE_CONTRACT.md`、`docs/L2_WRITEBACK.md`：probe/drain 契约。
- `docs/T-20260828-071-073-parallel-lines-plan-v2.md`：C0–C6、门、风险。
- `docs/handoffs/T-20260829-079-c1-dualcore-shell.md`、`T-20260829-086-c2-dualcore-msi.md`。
- `docs/decisions/ADR-20260829-005-v82-profile-parallel-lines.md`。
- 只读浏览：`rtl/lcvex_cluster_pkg.sv`、`rtl/lcvex_core_wrap.sv`、
  `rtl/lcvex_cluster_top.sv`、`rtl/lcvex_l2_cluster.sv`、`rtl/lcvex_gic.sv`、
  `rtl/lcvex_mmio_fabric.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_core.sv`、
  `rtl/lcvex_mmu.sv`、`sim/difftest/` 相关入口。
