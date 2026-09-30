# LCVEX 多核 Cluster / 一致性契约（C0）

> 任务：T-20260829-076（C0）
> 状态：owner 设计草案，等待 I0 批准
> 基线：`3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2`
> 分支：`feature/T-20260829-076-c0-cluster-contract`
>
> 本文是 **C1/C2/C3 的实现依据**，不是 RTL 实现，也不宣称完整 ARM
> 内存模型合规。本文只允许在共享 L2 上游定义目录式 MSI；AXI4 下游、
> 现有 L1/L2 probe/drain 契约和 `CORE_COUNT=1` 回归锚点保持不变。

## 1. 范围与目标

### 1.1 本契约回答的问题

- 多核系统如何参数化复制 `lcvex_core` 及其本地 L1？
- 每个核的 `core_id`、MPIDR、reset/start/stop/quiesce/kill、IRQ/timer、
  commit、内存请求和 probe 边界是什么？
- 共享 L2 上游的目录式 MSI（`I/S/M`）状态、消息、仲裁、错误回滚、
  dirty owner 和失效顺序是什么？
- 在 `CORE_COUNT=1` 时如何做到端口和行为完全兼容？
- C1/C2/C3 各自交付什么、不交付什么？

### 1.2 设计原则

1. **单核锚点**：`CORE_COUNT=1` 必须保持现有单核路径可编译、可运行，
   所有新增参数和信号不得改变既有单核顶层语义。
2. **内部目录，外部 AXI 不变**：一致性只在共享 L2 上游实现，通用内存
   下游仍为 AXI4 Full 128-bit、64B line、4-beat INCR、单 ID/单 outstanding
   的现有 profile；不引入 ACE/CHI。
3. **复用已有 hold/abort/drain**：D-L1 probe response 在 L2 未完成 dirty
   下刷前不释放；失败用 `l1_probe_rsp_abort`，checkpoint 顺序保持
   “D-L1 drain → L2 drain_to_PoC → ack”。
4. **先正确后性能**：第一版目录为单事务、单 outstanding、2 核 MSI；
   禁止用多 bank 或多 outstanding 混淆正确性验收。
5. **不宣称完整内存模型**：本文只定义项目 litmus 子集、屏障和原子在
   RTL 中的线性化/顺序边界；完整 ARM memory model 另立任务。

### 1.3 相关文档

- `docs/ARCHITECTURE.md`：核心、Cache 层次、P6/P7 现状。
- `docs/L1_L2_PROBE_CONTRACT.md`：单核 probe hold/abort 契约。
- `docs/L2_WRITEBACK.md`：L2 write-back、fault、drain 边界。
- `docs/AXI4_PROFILE.md`：下游 AXI4 不变式。
- `docs/DIFFTEST_QEMU_PLAN.md` / `docs/DIFFTEST.md`：单核 lockstep、v1 协议。
- `docs/T-20260828-071-073-parallel-lines-plan-v2.md`：C0–C6、D0、G-MC 口径。
- `docs/decisions/ADR-20260829-005-v82-profile-parallel-lines.md`：目录式 MSI
  决策、双列车边界。
- `docs/P7_FPGA_PARALLEL_PLAN.md`：未来多核预留字段。

## 2. 目标拓扑

```text
                     +----------------------+
                     | `lcvex_cluster_top`  |
                     |                      |
  core_wrap[0]       |                      |       core_wrap[CORE_COUNT-1]
 +----------------+  |                      |  +----------------+
 | lcvex_core     |  |                      |  | lcvex_core     |
 | I-L1 / D-L1    |  |                      |  | I-L1 / D-L1    |
 | per-core ctrl  |  |                      |  | per-core ctrl  |
 +----------------+  |                      |  +----------------+
        |            |                      |         |
        | mem_req/   |                      |         | mem_req/
        | rsp + IDs  |                      |         | rsp + IDs
        v            v                      v         v
 +------------------------------------------------------------+
 |       共享 L2 cluster / 目录 MSI 层（`lcvex_l2_cluster`）   |
 |   - per-core 请求仲裁                                     |
 |   - directory: I/S/M + sharer/owner + dirty               |
 |   - L2 array/write-back/refill（复用 B3/B4 语义）         |
 |   - probe fabric: ReadShared/ReadUnique/Upgrade/Invalidate |
 +------------------------------------------------------------+
        |  PoC M1-B 8B（L2 下游不变）
        v
 +------------------------------------------------------------+
 | lcvex_mem_router → RAM/MMIO → AXI4 Full → Avalon/EMIF      |
 +------------------------------------------------------------+
```

- 每个 `core_wrap` 内含 `lcvex_core`、I-L1、D-L1、PTW 优先仲裁和本地
  checkpoint/quiesce 逻辑。
- 每个 `core_wrap` 对共享 L2 暴露一个聚合后的“簇上游”端口（I-L1 miss、
  D-L1 miss/writeback/maintenance、PTW 读共用），并携带
  `core_id/source_id/transaction_id`。
- 共享 L2 内部维护目录；L2 对每个核有一条 `probe` 通道，用于失效、
  clean、clean+invalidate 和取 dirty owner 数据。
- 共享 L2 下游仍是现有 PoC 端口（8 字节 M1-B beat）；不新增第二个
  AXI master 或 ACE/CHI 端口。

## 3. Core Wrapper / 外壳接口

### 3.1 建议模块与参数

```systemverilog
module lcvex_core_wrap #(
    parameter int           CORE_COUNT        = 1,
    parameter int           CORE_ID           = 0,
    parameter int           CORE_ID_W         = 4,
    parameter int           SOURCE_ID_W       = 4,
    parameter int           TRANSACTION_ID_W  = 8,
    parameter logic [63:0]  RESET_PC          = 64'h0000_0000_4000_0000,
    parameter logic [63:0]  MPIDR_AFF0        = 0,
    parameter bit           COHERENCE_ENABLE  = 1'b1,
    parameter int           LINE_BYTES        = 64,
    parameter int           L1_SETS           = 64,
    parameter int           L1_WAYS           = 1
) (...);
```

`CORE_COUNT` 是 cluster 级参数；`CORE_ID` 是该实例的静态编号。`MPIDR_AFF0`
默认等于 `CORE_ID`，可在实例化时覆盖以匹配 QEMU/DTB。

### 3.2 控制 / 生命周期端口

| 信号 | 方向/类型 | 说明 |
| --- | --- | --- |
| `clk` | input | 全局同频逻辑时钟；第一版不做异步时钟域。 |
| `rst_n` | input | 全局异步低有效复位；所有状态回到 reset 值。 |
| `core_id` | input `[CORE_ID_W-1:0]` | 稳定实例标识，在复位后必须恒定为实例参数；用于目录/仲裁/事件。 |
| `mpidr` | output `[31:0]` | `MPIDR_EL1` 对外只读值；默认 `{24'h0, 8'h00, 8'h00, MPIDR_AFF0}`。 |
| `core_start_pulse` | input | 从 `STOPPED/RESET` 进入 `RUNNING` 的单拍请求。 |
| `core_stop_pulse` | input | 优雅停止：停止取指/新 commit，等待本核在途内存事务结束后进入 `STOPPED`。 |
| `core_quiesce` | input level | checkpoint/电源管理：挡住新内存请求，触发 L1/L2 drain；拉低后恢复。 |
| `core_kill_pulse` | input | 调试/故障注入硬停止：立即禁止新提交，不再接受新内存请求；在途事务允许收尾，最终进入 `KILLED/FAULT` 而不是静默丢数据。 |
| `core_running` | output | 1 = 正在取指/执行。 |
| `core_stopped` | output | 1 = 已停在确定性边界，可安全 start。 |
| `core_quiesced` | output | 1 = quiesce 后所有本地 drain 完成，可进入 checkpoint。 |
| `core_fault` | output | 1 = 本核 drain/reset/内存错误导致 fault 状态；需外部处理。 |

控制语义草案（I0 需确认 pulse/level 最终形式）：

- `core_start_pulse`：只在 `STOPPED` 或 `RESET` 后有效；不接受重复 start。
- `core_stop_pulse`：与 `core_start_pulse` 互斥；停止点取**提交边界**，
  已有 in-flight 内存请求继续完成。
- `core_quiesce`：与 checkpoint 配合，是 level；在 `RUNNING` 下置位后
  进入 quiescing，完成后 `core_quiesced=1`；拉低回到 `RUNNING` 或
  `STOPPED`（视 stop 是否同时请求）。
- `core_kill_pulse`：为测试/故障注入保留；不要求事务级回滚到体系结构
  可见状态，但不得静默丢弃已被目录接受的请求。

### 3.3 每核独立 IRQ / Timer / Event

| 信号 | 方向/类型 | 说明 |
| --- | --- | --- |
| `irq` | input | 本核 GIC CPU 接口 IRQ；只影响本核异步异常入口。 |
| `timer_phys_irq` | output | 本核 Generic Timer 物理中断输出，接 GIC PPI。 |
| `timer_virt_irq` | output | 本核 Generic Timer 虚拟中断输出，接 GIC PPI。 |
| `event_in` | input | cluster 广播的 WFE/SEV 事件；置位本核本地 event register。 |
| `sev_pulse` | output | 本核执行 `SEV` 时单拍输出，由 cluster 广播给其它核。 |
| `wfi_idle` | output | 本核处于 WFI/WFE 等待；供调试/差分 sidecar 使用。 |

说明：每个核的 timer 计数、IRQ 屏蔽和 `DAIF` 状态均独立；C1 仅验证
“独立”，C2 仍不实现 IPI/SEV cluster 广播之外的中断系统。

### 3.4 Commit 接口（多核 envelope）

单核 `lcvex_pkg::commit_packet_t` 保持完全不变。多核在外层增加 envelope，
不得把 `core_id` 塞进现有字段：

```systemverilog
typedef enum logic [2:0] {
  MC_EV_COMMIT = 0,
  MC_EV_ASYNC_IRQ = 1,
  MC_EV_WFI = 2,
  MC_EV_WFE = 3,
  MC_EV_STOP = 4,
  MC_EV_FAULT = 5
} lcvex_mc_event_t;

typedef struct packed {
  logic [3:0]              version;    // LCVX-DIFF-MC v2 version，初始=2
  logic [CORE_ID_W-1:0]    core_id;
  logic [63:0]             global_seq; // 由 MC-v2 协调器分配/RTL可选记录
  logic [31:0]             vcpu_seq;   // 本核局部退休序号
  lcvex_mc_event_t         event_kind;
  lcvex_pkg::commit_packet_t commit;   // 原单核 payload 不动
} lcvex_mc_commit_t;
```

RTL 侧信号：

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `mc_commit_valid` | output | 本核本周期有一条事件/提交。 |
| `mc_commit_ready` | input | 消费者可接收；低时 `mc_commit` 保持。 |
| `mc_commit` | output | 完整 envelope。 |

`CORE_COUNT=1` 时允许 wrapper 只输出原 `commit_packet_t`（兼容模式）；
新增 envelope 可旁路不启用。MC-v2 二进制格式由 D0 定义，本文只冻结逻辑
字段和版本语义。

### 3.5 内存请求接口（每个 core_wrap 到 cluster）

第一版沿用现有 M1-B `valid/ready` 和 `lcvex_pkg::mem_req_t/mem_rsp_t`
结构体，ID 使用独立 sideband，避免改坏单核 `mem_req_t` 布局。

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `mem_req_valid` | output | 本核有一条簇上游请求。 |
| `mem_req_ready` | input | cluster 可接收；低时请求保持。 |
| `mem_req` | output | `addr/we/strb/wdata/maint/bypass`，与现有字段一致。 |
| `mem_source_id` | output | 本核 source 编号；`CORE_COUNT=1` 恒为 0。 |
| `mem_transaction_id` | output | 本核事务 id；用于响应回配。 |
| `mem_rsp_valid` | input | cluster 返回响应。 |
| `mem_rsp_ready` | output | 本核可消费；低时 cluster 保持响应。 |
| `mem_rsp` | input | `rdata/fault`，与现有字段一致。 |
| `mem_rsp_source_id` | input | 必须等于请求 id，否则视为协议错误。 |
| `mem_rsp_transaction_id` | input | 必须与请求配对。 |

每个 core_wrap 内部仍保留现有三路 `imem/dmem/ptw` 到本地 I-L1/D-L1 的
接口；只有当本地 L1 miss、writeback、maintenance 或 bypass 时才向 cluster
发出一个聚合请求。当前每个核保持单 outstanding；C2 不扩展到每核多
outstanding。

### 3.6 Probe / Snoop 接口（L2 → 每个 core_wrap）

复用现有 D-L1 probe 端口形状并扩展为 per-core 实例：

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `probe_req_valid` | input | L2 对本核的 probe 请求。 |
| `probe_req_ready` | output | 本核可接受；D-L1 忙时不接受。 |
| `probe_req_addr` | input | line-aligned PA。 |
| `probe_req_cmd` | input `[1:0]` | 0=lookup,1=clean,2=invalidate,3=clean+invalidate。 |
| `probe_req_source_id` / `probe_req_transaction_id` | input | 目录事务身份。 |
| `probe_rsp_valid` | output | 本核 probe 响应。 |
| `probe_rsp_ready` | input | L2 消费；低时响应保持。 |
| `probe_rsp_fault` | output | 本核无法完成（例如地址/状态错误）。 |
| `probe_rsp_line_valid` | output | 本核是否有该 line。 |
| `probe_rsp_dirty` | output | 是否 dirty。 |
| `probe_rsp_data` | output | 完整 64B raw line。 |
| `probe_rsp_addr/source_id/transaction_id` | output | 回显。 |
| `probe_rsp_abort` | input | L2 已消费 dirty data 但下刷失败时的失败提交控制。 |

`probe_rsp_ready` 的 hold 规则与
[`L1_L2_PROBE_CONTRACT.md`](L1_L2_PROBE_CONTRACT.md) 完全一致：L2 在
dirty response 的全部写回 beat 成功前不得释放 ready；失败时用
`probe_rsp_abort=1`，D-L1 保留原 metadata。

### 3.7 Checkpoint / drain sideband

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `checkpoint_quiesce` | input | 与 `core_quiesce` 配合，阻止新请求并启动 drain。 |
| `l1_drain_done` | output | 本核 D-L1 所有 dirty line 已写入 L2。 |
| `l1_drain_fault` | output | 本核 drain 失败。 |
| `cluster_drain_req_valid/ready` | cluster ↔ wrapper | shared L2 的 drain_to_PoC 请求。 |
| `cluster_drain_ack_valid/ready/fault` | cluster ↔ wrapper | drain 完成/失败。 |

全局顺序固定：

```text
checkpoint_quiesce
  → 每个 core_wrap 停止新的 core/PTW 请求
  → 每个 D-L1 下刷本地 dirty line（l1_drain_done）
  → 共享 L2 drain_to_PoC（全部 dirty 下刷）
  → cluster_drain_ack_valid（成功）或 fault
```

## 4. 共享 L2 目录式 MSI

### 4.1 行状态：L1 侧

| 状态 | 含义 | 允许操作 |
| --- | --- | --- |
| `I` | 本核无该 line 的 valid 副本 | 可 ReadShared/ReadUnique |
| `S` | 本核有 clean shared 副本 | 可读；可 Upgrade 为 M |
| `M` | 本核有唯一 owner，通常 dirty | 可读/写；必须响应 probe/写回 |

C2 第一版不使用 `E`（exclusive clean）和 `O`（owned）。MESI-lite 扩展点
见 §4.6，但不作为 C2 验收。

### 4.2 目录状态

目录条目保存的是 **哪些核持有副本、谁拥有 dirty**，不是 L1 的完整数据：

| 字段 | 宽度/类型 | 说明 |
| --- | --- | --- |
| `valid` | 1 | 该 L2 set/way 目录项有效。 |
| `state` | 2 | `I`（无副本）/`S`（一个或多个 sharer）/`M`（唯一 owner）。 |
| `sharers` | `[CORE_COUNT-1:0]` | S 状态下哪些核有副本。 |
| `owner` | `$clog2(CORE_COUNT)` | M 状态下唯一 owner。 |
| `dirty` | 1 | L2 中该 line 是否已被 owner 修改；M 时一般=1。 |
| `pending` | 1 | 该 line 有在途目录事务（仲裁锁）。 |

目录不变式（C2 必须）：

1. `M ⇒ (owner one-hot) && (sharers == 1<<owner) && dirty==1`；
2. `S ⇒ sharers != 0 && owner invalid && dirty==0`；
3. `I ⇒ sharers==0 && owner invalid && dirty==0`；
4. 每个 line 最多一个在途目录事务；`pending=1` 时不可接受新的同 line
   请求。
5. 任何 fault/abort 不得令目录产生新的 M owner；已成功 invalidate 的
   L1 属于“保守多余失效”，不得被当成协议违规。

### 4.3 请求 / 消息

| 请求 | 发起方 | 目录动作 | 典型返回 |
| --- | --- | --- | --- |
| `ReadShared` | 核 miss 读 | 若 I 从 L2/PoC 取数；若 S 直接加 sharer；若 M 先 clean 或 invalidate owner 拿数据，再使原 owner 降为 S/I 并把请求者加入 S | 数据；新状态 S |
| `ReadUnique` | 核 miss 写 / 独占读 | 若 I 取数并置唯一 owner；若 S 失效所有其它 sharer；若 M 由他人持有时失效原 owner 并取数 | 数据；请求者 M |
| `Upgrade` | 核已在 S 要写 | 失效所有其它 sharer；若都成功则请求者升 M | 无需数据（或可选 ack） |
| `WriteBack` | M owner 替换/clean | 吸收 dirty 数据到 L2/PoC；owner 降为 I 或 S | ack/fault |
| `Clean` | 维护/降级 | 清 dirty；M → S/I | ack/fault |
| `Clean+Invalidate` | 维护/替换 | 先 clean 再失效；M → I | ack/fault |
| `Invalidate` | 失效 | 清 L1 valid；M → I | ack/fault |
| `Bypass` | Device/MMIO | 不分配、不建目录，直接到 PoC | 普通响应 |

第一版全部请求仍走现有 `mem_req.maint`/`bypass`/地址字段；新增的
“命令类型”由 cluster wrapper 或目录内部根据 `we/maint/bypass` 映射，
不要求现在修改 `lcvex_pkg::mem_req_t`。

### 4.4 目录事务状态机草案

```text
        ┌──────────────┐
        │  DIR_IDLE    │◄──────────────┐
        └──────┬───────┘               │
        accept request (line lock)      │
               ▼                        │
   ┌───────────────────────────┐        │
   │ DIR_DECODE                 │        │
   │  I/S/M + requested op      │        │
   └──┬──────────┬──────────┬───┘        │
      │          │          │            │
   ReadShared ReadUnique Upgrade/WB     │
      │          │          │            │
      ▼          ▼          ▼            │
 DIR_FILL  DIR_PROBE_ALL  DIR_PROBE_OWNER│
      │          │          │            │
      ▼          ▼          ▼            │
 DIR_WB_TO_POC (if dirty returned)       │
      │          │          │            │
      ▼          ▼          ▼            │
 DIR_COMMIT_STATE ── DIR_RSP ────────────┘
      │
      ▼ fault/abort
 DIR_ERROR/RETRY
```

关键规则：

- `pending` 在请求被接受时置位，在 `DIR_RSP` 握手或 `DIR_ERROR`
  返回 idle 时清零。
- 目录状态只允许在“所有必要 probe 成功 + 必要写回成功”后修改。
- 若任何 probe 返回 fault，当前请求向请求者返回 `fault`，目录状态不变；
  已被失效的 L1 保持无效，目录的 sharer 位允许保守地仍为 1（后续 probe
  会hit miss 并清除），但不允许产生新的 M owner。
- Dirty owner 响应：L2 先把完整 64B raw line 锁存到独立 buffer，再向
  PoC 写回；全部 beat 成功后才允许释放 `probe_rsp_ready`。任一 beat
  fault 时置 `probe_rsp_abort=1`，D-L1 保留原 metadata，目录不提交。

### 4.5 仲裁

第一版为“一个共享 L2 事务”模型：

- 每个 core_wrap 的簇上游请求进入一个单口仲裁；
- 仲裁器按固定 round-robin 选择，每个核最多一个未完成请求；
- 被选中的请求与目录 `DIR_IDLE` 握手后才算被接受；未选中时
  `mem_req_ready=0`；
- 已接受的请求不能被打断，直到响应握手或 fault 返回；
- 同一 line 的第二请求即使来自不同核也必须等待前一个事务完成；
- C3 可扩展为 per-bank 仲裁或每核队列，但不得改变 C2 单事务正确性模型。

仲裁公平性只用于可重放，不声明为架构内存顺序。

### 4.6 MESI-lite 扩展点（非 C2 默认）

在目录状态字段与 L1 状态中预留 `E`（exclusive clean）和可选 `O`
（owned, not dirty）编码：

- `E`：唯一 owner、clean，可免费升级为 M；
- `O`：MOESI 中可能有 sharer 的 dirty owner，需要额外 owner 语义；
- 若未来需要，C2 的 `ReadUnique` 可将“clean 独占”实现为 E，但仍须先
  通过 I/S/M 测试；
- C0 不要求实现 E/O；只是说明目录字段不应把 `state` 宽度焊死为 2 bit。

## 5. CORE_COUNT=1 兼容性

### 5.1 兼容模式

当 `CORE_COUNT=1` 时，cluster 实例应退化为现有单核 coherent wrapper
的行为：

| 项目 | 单核现有行为 | 多核参数化后 CORE_COUNT=1 必须保持 |
| --- | --- | --- |
| core 实例数 | 1 | 1 |
| `core_id/source_id` | 固定 0 | 固定 0 |
| MPIDR | 当前未显式暴露 | 可输出 `MPIDR=0`（默认 Aff0=0），不影响现有代码 |
| I-L1/D-L1/L2 | 单核闭环 | 同一组模块或等价兼容 wrapper |
| probe | L2→D-L1 单客户端 | 同一通道，sharer/owner 位宽 1 |
| checkpoint | quiesce→L1 drain→L2 drain→ack | 完全同一顺序 |
| 下游 PoC/AXI4 | M1-B → router → AXI4 | 完全不变 |
| commit | 原 `commit_packet_t` | 原包或 MC envelope 中 core_id=0，payload 不变 |
| start/stop/quiesce/kill | 现有顶层无 start/stop；只用 quiesce | 新增控制默认为“常开/不使能”，不得改变自然上电执行 |

### 5.2 兼容检查点

1. 现有 `lcvex_catapult_soc_top` / `lcvex_catapult_soc_coh` 不因本契约
   被修改；多核实现为新增模块，单核路径继续用原文件或经薄适配层。
2. `CORE_COUNT=1` 的 cluster 实例必须能够通过现有 L1/L2 独立回归
   （`lcvex_l1_coherence`、L2 probe 套件）的端口级替换。
3. 不修改 `rtl/lcvex_pkg.sv` 的 `mem_req_t/mem_rsp_t/commit_packet_t`
   现有字段；多核 ID/命令使用 sideband 或 envelope。
4. 不新增 ACE/CHI 端口，不改变 AXI4/EMIF 下游。
5. `CORE_COUNT=1` 下所有新增控制信号有默认值：start=1、stop=0、
   quiesce=0、kill=0，使未接线的单核顶层照常运行。

## 6. 时序 / 状态机细节

### 6.1 Reset 值

| 对象 | Reset 值 |
| --- | --- |
| core wrapper state | `STOPPED`（或等价的 `RESET` 后非运行态） |
| `core_running/core_stopped/core_quiesced/core_fault` | 0/1/0/0（按定义） |
| per-core I/D-L1 valid/dirty/tag | 0/0/0 |
| per-core transaction/source/response registers | 0 |
| 目录 entry valid/state/sharer/owner/dirty/pending | 0/`I`/0/0/0/0 |
| 仲裁器 round-robin pointer | 0 |
| commit envelope | 所有字段 0，valid=0 |
| 低有效异步复位 | 所有状态/握手指针清 0 |

数据 RAM 依赖 valid=0 不可见，不要求复位时清零。

### 6.2 Backpressure

- 所有 `valid/ready` 通道均为**无丢弃**协议：valid 且 ready 未握手时，
  payload 必须保持。
- 共享 L2 一次只接受一个上游请求；`mem_req_ready` 低可无限期回压。
- probe response 的 `ready` 只有 dirty 下刷完成后才可拉高（现有规则）；
  fault/abort 路径同样先决定再释放。
- `mc_commit_ready` 低时 core 保持提交；多核下每核独立 backpressure。
- `checkpoint_quiesce` 置位后，core_wrap 在本地请求交界停止接受新请求；
  已接受请求可以继续完成，但不能产生新的可观察提交之外的副作用。

### 6.3 kill 语义

Kill 是测试/故障注入边界，不是架构指令：

1. `core_kill_pulse` 后 wrapper 停止取指，不再发出新 imem/dmem/ptw
   request，不再产生新的 commit；
2. 已在 L2 目录中的请求继续完成或按现有 fault 路径返回；不允许目录
   在执行中遗忘 pending；
3. 若请求已接受但最终 fault，wrapper 进入 `FAULT` 而非 `STOPPED`；
4. 若 kill 发生在核心提交边界，允许已经 valid 的 commit 完成；
5. kill 不用于 checkpoint；checkpoint 必须走 `quiesce` + drain + ack。

### 6.4 SVA 断言草案

以下为 C1/C2 应实现/扩展的断言草案，最终以 SV 文件为准：

```systemverilog
// 1) 请求必有响应，不得丢弃
property p_req_no_drop;
  @(posedge clk) disable iff (!rst_n)
  req_valid && req_ready |-> ##[0:$] rsp_valid;
endproperty

// 2) 响应身份必须匹配
property p_rsp_id_match;
  @(posedge clk) disable iff (!rst_n)
  rsp_valid |-> (rsp_source_id == last_source_id) &&
               (rsp_transaction_id == last_transaction_id);
endproperty

// 3) 目录 dirty 唯一
property p_dir_m_unique;
  @(posedge clk) disable iff (!rst_n)
  dir_state == M |-> ($onehot(dir_owner)) &&
                   (dir_sharers == (1 << dir_owner)) &&
                   dir_dirty;
endproperty

// 4) probe 未握手前不得改变 L1 metadata
property p_probe_hold_metadata;
  @(posedge clk) disable iff (!rst_n)
  l1_probe_req_valid && l1_probe_req_ready |->
    (l1_probe_rsp_valid ? !l1_probe_rsp_ready : 1'b1)
    until (l1_probe_rsp_valid && l1_probe_rsp_ready && !l1_probe_rsp_abort);
endproperty

// 5) quiesce 后不得接受新请求 / 不得有未授权 commit
property p_quiesce_no_new_req;
  @(posedge clk) disable iff (!rst_n)
  checkpoint_quiesce |-> !mem_req_accept_after_quiesce;
endproperty

property p_quiesce_no_commit_until_drain_done;
  @(posedge clk) disable iff (!rst_n)
  checkpoint_quiesce && !l1_drain_done |-> !new_commit_valid;
endproperty

// 6) active 目录事务期间同一 line 不允许第二次 accept
property p_line_pending_exclusive;
  @(posedge clk) disable iff (!rst_n)
  dir_pending |-> !same_line_accept;
endproperty
```

### 6.5 常见序列

#### 6.5.1 ReadShared / ReadUnique / Upgrade

```text
CoreA: ReadShared X (miss)
  L2 DIR: I -> (fill from PoC) -> S{sharers={A}}
  CoreA: data
CoreB: ReadShared X
  L2 DIR: S -> add B -> S{sharers={A,B}}
  CoreB: data
CoreA: Upgrade X (write)
  L2 DIR: probe invalidate B
    B: probe_rsp (line_valid=1, dirty=0)
  L2 DIR: B invalid; A -> M{owner=A, dirty=1}
  CoreA: write proceeds
CoreC(C2 two-core; only A/B)
```

#### 6.5.2 Store-buffering（litmus 子集）

```text
Core0                 Core1
ST X=1                ST Y=1
DMB (or DSB)          DMB (or DSB)
LD Y                  LD X
```

- 允许结果：`(LD Y==0 && LD X==0)` 在弱内存模型下是允许的；
- 在 C2 中，每个 store 在 L1 命中时可先提交，目录/屏障负责后续可见性；
- `DMB` 保证本核先序 Store 对后序 Load 的本地顺序；
- `DSB` 在 wrapper 内等待本核已提交的 Store 在目录/ PoC 完成；
- 不允许据此宣称“完整 ARM memory model”；litmus 子集、允许集合和
  linearization point 由 D0/独立 memory-model 任务定义。

#### 6.5.3 Load-buffering

```text
Core0                 Core1
LD Y                  LD X
DMB                   DMB
ST X=1                ST Y=1
```

同样只做可重放序列，不提前给完整架构结论。

#### 6.5.4 CAS / LDXR–STXR

```text
CoreA: LDXR X   (本地 exclusive monitor 记录 X 的地址和值)
CoreB: ST X=2   (目录使 CoreA 的 X 失效，并清除/失效本地 monitor)
CoreA: STXR X, new
   - monitor 已被失效 => STXR 失败，写 1 到状态寄存器
   - 目录不产生部分更新
```

- 每核一个 exclusive monitor；收到该地址的 invalidate/clean+invalidate
  probe 时必须使监视器失效；
- `STXR` 成功还要求目录/内存当前值与 monitor 记录值按访问宽度匹配；
- C2 只实现单核顺序模型下的独占语义，不声称 ARM 全局 exclusive monitor
  的完整实现。

#### 6.5.5 Barrier 与 self-modifying code

```text
CoreA: ST (code/data)
       DC CVAU/CIVAC   (clean to PoC)
       DSB
       IC IALLU/IVAU   (invalidate I-L1)
       ISB             (flush pipeline; next fetch sees new insn)
```

- C2 支持本地核的 clean+invalidate+ISB 可观察；
- 多核 self-modifying code 需要**每个**执行核自行执行 IC invalidate +
  ISB，或由 C3 的 IPI/TLBI 机制协调；
- 本文不把 DC/IC 维护跨核自动广播写成已完成。

## 7. C1 / C2 / C3 边界与依赖

### 7.1 C1：双核壳层（不含 coherence）

| 项目 | C1 范围 |
| --- | --- |
| 参数化 | `CORE_COUNT=2`，复制 core_wrap |
| 本地状态 | 每核独立 reset、core_id、IRQ、timer、commit、WFI/WFE |
| Cache/coherence | 可关 cache、旁路到独立地址区间，或共用 L2 但**不打开目录 MSI** |
| 验证 | 2 核 elaboration、独立程序、per-core commit 记录、core_id 可区分 |
| 明确不做 | 跨核 probe、目录状态、cache 一致性、原子跨核、barrier 强序 |
| 依赖 | C0 契约、D0 MC-v2 可行性（用于提交记录） |

C1 出口：`CORE_COUNT=1` 全回归不回归；2 核 shell 能独立 start/stop/
reset/irq，且不宣称 coherence。

### 7.2 C2：双核 MSI

| 项目 | C2 范围 |
| --- | --- |
| 共享资源 | 共享 L2 目录，`CORE_COUNT=2` |
| 协议 | MSI `I/S/M`，ReadShared/ReadUnique/Upgrade/WriteBack/Clean/Invalidate |
| L1 动作 | per-core D-L1 probe/失效/clean+invalidate、dirty owner 下刷 |
| 原子/屏障 | 单核 exclusive monitor、CAS/LDXR-STXR、DMB/DSB/ISB 本地序列 |
| 验证 | message passing、store/load buffering、CAS、barrier、clean+invalidate+ISB、随机延迟、reset/fault |
| 明确不做 | E/O、4 核扩展、IPI/SEV 广播、TLB shootdown、Linux SMP |

C2 出口：上述 litmus/原子/维护序列在确定性调度和受控扰动集合全绿；
目录不变式 SVA 通过；`CORE_COUNT=1` 不回归。

### 7.3 C3：四核系统

| 项目 | C3 范围 |
| --- | --- |
| 规模 | `CORE_COUNT=4`，目录位图/仲裁扩展到 4 核候选 |
| 系统 | GIC/PSCI、per-core timer、IPI/SEV/WFE 广播、启停次序 |
| 一致性 | 多 sharer 失效、多核 maintenance、TLB shootdown 有序化 |
| 验证 | 4 核裸机同步/IRQ/maintenance/长期压力；单核/双核不回归 |
| 明确不做 | 完整 Linux SMP、8+ 核功能验收、外部 coherent DMA |

C3 依赖 C2 的目录和 probe 正确性；若 C2 失败，不进入 C3 功能测试。

## 8. 留给 I0 批准的问题清单

1. **MPIDR 映射**：是否固定 `Aff0=core_id`、`Aff1=cluster_id=0`？QEMU
   `-smp`/DTB 是否使用同一映射？
2. **start/stop 电平/脉冲**：使用 `core_start_pulse/core_stop_pulse` 还是
   level-enable？是否与 PSCI `CPU_ON/CPU_OFF` 共用？
3. **每核 timer/GIC**：C2 是否只接 `timer_phys_irq` 到各自 PPI？虚拟 timer
   和 event 接口在 C2 是否需要真实 GIC 模型？
4. **MC-v2 envelope**：`version/core_id/global_seq/vcpu_seq/event_kind`
   的最终二进制布局由 D0 决定；C0 是否允许 RTL 侧只输出 `core_id + payload`
   而不输出 global_seq？
5. **目录 single-outstanding**：2 核是否接受全局单事务（会显著限制并行）？
   还是 C2 就要求 per-bank/pipelined？
6. **ReadUnique 返回状态**：MSI 默认 M 是否要求“ReadUnique 后立即 dirty”，
   还是允许 clean exclusive（即 E）作为扩展点？
7. **exclusive monitor 失效粒度**：是否任何 probe 到该 line 都失效本地
   monitor，还是只对 invalidate/clean+invalidate 失效？
8. **kill 行为**：是否允许 kill 时在途请求继续完成？是否需要独立的
   abort request 通道？
9. **I-L1 跨核一致性**：数据写后是否要求自动失效其它核 I-L1？还是要软件
   IC maintenance + IPI？
10. **checkpoint v4**：每核 L1 metadata/data、目录状态、GIC/timer/event
    进入 manifest v4 的字段和恢复顺序是否由 C0 锁？
11. **DMA**：继续明确 non-coherent；若未来需要，另建 ACE/CHI 或 snoop
    bridge 任务，不在 C2 隐式实现。
12. **C1 cache 策略**：C1 是“旁路缓存”还是“独立 L2 不共享”，以哪个作为
    默认双核 shell？

## 9. 验收自查（C0 文档）

- [x] 有 core wrapper 端口表、控制/IRQ/timer/commit/mem/probe 接口。
- [x] 有目录式 MSI 状态、消息、仲裁、错误回滚、dirty owner、probe 失效。
- [x] 有 `CORE_COUNT=1` 兼容声明和检查点。
- [x] 有 reset 值、backpressure、kill、SVA 草案。
- [x] 有 store/load buffering、CAS/LDXR-STXR、barrier、clean+invalidate+ISB
      序列草案。
- [x] 有 C1/C2/C3 边界、依赖和待 I0 批准问题。
- [ ] RTL 未实现；下一节点为 C1/D0。

## 10. 非目标 / 已知限制

- 不实现多核 RTL；不修改 `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv`、
  commit/memory/QEMU。
- 不引入 ACE/CHI，不改变 AXI4/Avalon/EMIF。
- 不宣称完整 ARM memory model、Linux SMP 或 coherent DMA。
- 32 核只作为未来参数化/资源目标，不属于 C0/C1/C2 验收。
