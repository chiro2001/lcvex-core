# LCVEX C4 8/16/32 核规模前置设计与测量契约（C4-pre）

> 任务：T-20260829-100（C4-pre）
> 状态：**只读前置设计/测量契约，不代表 8/16/32 核功能完成**
> 日期：2026-08-29
> 基线：`df3c8ba5fcb75632c31fd6f780a1861a2566eac4`
> 分支：`feature/T-20260829-100-c4-scale-prework`
> worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-100`
> 关联：`docs/C3_FOURCORE_PREWORK.md`、`docs/MULTICORE_CLUSTER_CONTRACT.md`、
> `docs/T-20260828-071-073-parallel-lines-plan-v2.md`、`docs/LCVX_DIFF_MC_V2.md`。

## 0. 重要边界

1. 本任务只做 **C4 规模前置设计与测量契约**，不实现/不改 RTL。
2. 不启动 Quartus，不做物理签核，不宣称 8/16/32 核功能完成。
3. 8/16/32 核只按 v2 计划的“参数化 elaboration、有限 smoke、资源/延迟趋势、
   已知限制”口径报告；**不是 Linux SMP、板级或物理签核目标**。
4. 本文件不修改 `rtl/`、`tb/`、`sim/`、QEMU、checkpoint 协议。
5. 实际 C4 规模实现/测量应在 C3 四核正确性候选稳定后派发；当前 C2 尚未完全
   关闭，C3 也尚未实现，因此本任务只提供前置定义。

---

## 1. 结论先行

- C4 的验收不是“32 核能跑通”，而是“每个规模能可重复地产生 compile/elaboration、
  有限事务 smoke、资源/延迟趋势，并明确记录最高通过规模和退化点”。
- 推荐先从 **8 核** 开始做参数化测量，原因是 8 核目录位图仍可以用单周期组合
  逻辑处理；16/32 核若继续用全局单事务/单周期位图，面积和时序会迅速恶化。
- C4 测量应分成两层：
  - **L0/L1 参数化路径**：用 synthetic L1 client + BFM，不接完整 `lcvex_core`，
    可以快速测量目录位宽、仲裁、probe 和 PoC 的趋势。
  - **L2/系统级路径**：只有在 C3 四核相对稳定后，才把 8 核以上接到真实 core 做
    有限 smoke；完整 Linux/长跑不属于 C4 范围。
- 必须区分 **“参数化可 elaboration”** 和 **“多核功能正确”**。C4 报告只能声明前者
  及有限 smoke，不能把规模趋势写成架构合规。

---

## 2. 基于 C0/C1/C2/C3-pre 的现状与假设

### 2.1 当前基础

| 层 | 现状 | 对 C4 的含义 |
| --- | --- | --- |
| C0 契约 | 已定义 core wrapper、目录 MSI、probe/drain、CORE_COUNT=1 兼容。 | C4 沿用该接口，只在位宽/仲裁/路由上参数化。 |
| C1 壳层 | 双核非一致性，per-core 私有内存，MC envelope 雏形。 | 不是 C4 的规模基础；只提供 per-core 生命周期和事件观测参考。 |
| C2 模块/系统 | 模块级 MSI 已合入，系统接线和真实双核仍在 C2 remainder 中排查；当前 `lcvex_l2_cluster.sv` 仍有 2 核硬编码。 | C4 必须等 C3 先把目录/仲裁泛化到 4 核，才能真正讨论 8/16/32。 |
| C3-pre | 已定义 4 核所需 GIC/PSCI、IPI/SEV/WFE、TLB shootdown、共享 MMIO、公平仲裁，并建议 C3-A~C3-D 切片。 | C4 在 C3 拓扑之上增加“规模参数化”和“测量契约”，不重复设计 4 核控制面。 |

### 2.2 关键规模约束

1. **目录位图**：当前 `dir_sharers`/`dir_owner` 宽度为 `CORE_COUNT`。
   32 核时 sharer 位图为 32 bit，owner 位图仍可用 32 bit one-hot 或 `$clog2` 编码。
2. **单事务模型**：C2/C3 第一版为全局单事务。16/32 核继续全局单事务会严重限制
   每核带宽，但作为正确性/测量起点是可接受的；性能扩展应单独评估。
3. **PoC 带宽**：PoC/M1-B 是 8B beat，64B line 固定 8 beat。
   即使目录单事务，每个 refill/writeback 仍需要 8 拍；核心数增加不会改变
   PoC 带宽，只会增加请求延迟和仲裁等待。
4. **完整 core 仿真成本**：`lcvex_core` + L1/MMU 是主要 Verilator 耗时/内存来源。
   32 个完整 core 的直接 elaboration/仿真可能不可行，因此 C4 必须提供
   synthetic-client 或简化 memory model 的测量路径。

---

## 3. CORE_COUNT 参数化扩展方式

### 3.1 建议参数集

| 参数 | 建议含义 | 8/16/32 取值 |
| --- | --- | --- |
| `CORE_COUNT` | 逻辑核总数 | 8 / 16 / 32 |
| `CORE_ID_W` | core_id 位宽 | `$clog2(CORE_COUNT)`，至少 5 位 |
| `SOURCE_ID_W` | source id 位宽 | 可等于 `CORE_ID_W` 或略大 |
| `TRANSACTION_ID_W` | 每核/每事务 id | 建议 8，后续按队列深度扩展 |
| `SHARER_W` | sharer 位图宽度 | = `CORE_COUNT` |
| `OWNER_W` | owner 编码宽度 | `$clog2(CORE_COUNT)`，或保留 one-hot |
| `DIR_ENTRIES` | 目录行数 | 独立于核数，按 MEM_LINES 参数化 |
| `ARB_MODE` | 仲裁模式 | `FLAT_RR` / `TREE_RR` 预留 |
| `REQ_QUEUE_DEPTH` | 每核请求队列深度 | 1 起步；8/16 可测 2/4 |
| `PER_BANK` | 是否分 bank | false 第一版，true 作为性能扩展 |
| `POC_BEATS` | PoC beat 数/line | 固定 8 |

### 3.2 Cluster topology

建议保持 **共享 L2 + 共享目录** 的平铺拓扑到 8 核：

```text
core_wrap[0..N-1]
   |  per-core coherent req/rsp + probe
   v
lcvex_l2_cluster
   |  directory + single PoC M1-B
   v
shared mem_router -> RAM / MMIO / GICD / per-GICC
```

16/32 核可以保留逻辑平铺，但物理/测量上应考虑：

- **两层仲裁树**：每 4/8 核一组 slice arbiter，slice 出口再进全局 arbiter。
- **目录分片**：按地址 bank 把目录和事务分散到多个 `lcvex_l2_cluster` 实例，
  但保持“每 line 一个 pending”的一致性；分片不改变 MSI 状态语义。
- **probe 扇出**：每个目录事务可能需要向多个 sharer 发 probe；8 核可用
  逐目标循环，16/32 核需要 probe 位图或 per-core pending 队列，避免阻塞。
- 第一版测量仍应从**单目录单事务**开始，以得到 baseline；分片/树只作为趋势项。

### 3.3 目录位图宽度

| 规模 | sharer 位图 | owner 表示 | 目录条目寄存器/组合成本 |
| --- | --- | --- | --- |
| 8 | 8 bit | 3 bit 编码或 8 bit one-hot | 小；仍可单周期组合。 |
| 16 | 16 bit | 4 bit 编码或 16 bit one-hot | 中；需关注 probe target 搜索延迟。 |
| 32 | 32 bit | 5 bit 编码或 32 bit one-hot | 大；建议 one-hot 只用于调试/不变式，核心状态用编码，必要时分 bank。 |

C4 测量必须报告：

- `dir_sharers` 和 `dir_owner` 的实际位宽/编码；
- 目录条目面积/延迟 proxy（组合逻辑深度、LUT/FF 估计或 Netlist 统计）；
- probe target 搜索的最坏循环/组合路径。

### 3.4 仲裁树 / 队列

第一阶段仍可用 **round-robin + liveness fallback**，但 C4 必须定义可切换的
`ARB_MODE`：

| 模式 | 特征 | 适用 |
| --- | --- | --- |
| `FLAT_RR` | 一个全局 round-robin，每个核最多 1 outstanding。 | 8 核 baseline；最简单、易验证。 |
| `SLICE_TREE` | 每 4/8 核一个 slice RR，slice 出口再全局 RR。 | 16/32 核减少扇入，仍保证每核 fair；需防止 slice 内部线头阻塞。 |
| `PER_BANK` | 按地址 bank 独立仲裁/目录。 | 性能扩展；会引入跨 bank 排序问题，需单独 contract。 |

C4 测量的队列配置至少记录：

- 每核输入队列深度；
- 每核最大 outstanding；
- 全局/ slice 仲裁器深度；
- 同 line 冲突是否会阻塞全部核。

### 3.5 每核 MMIO / 中断路由

- **MMIO**: 所有核共享同一个内存/MMIO 路由。每核访问 GICD/GICC 通过地址解码
  到对应设备；GICC 必须 per-core 寻址，不能所有核访问同一份。
- **中断**: 共享 GICD + 每核 GICC。8/16/32 核的核心问题是：
  - SGI/IPI 目标由 32-bit 位图表示；
  - 每核 GICC 的地址分页/offset 必须与 QEMU/DTB 对齐；
  - 共享外设中断可先固定路由到 core0，避免多目标路由复杂度。
- **PSCI**: CPU_ON/OFF 的目标 MPIDR 位宽随核数增加；cluster control 要有
  目标核位图或表，不得硬编码单核/双核。
- **TLB shootdown**: 目标集合从 4 核位图扩展到 32 核位图；第一版仍可用全表失效
  广播，若要 per-ASID/VA，需要 32 位目标位图 + 队列。

### 3.6 共享 L2 带宽模型

定义以下测量口径：

| 指标 | 定义 |
| --- | --- |
| `refill_beats` | 每次 refill 的 PoC beat 数，当前固定 8。 |
| `writeback_beats` | dirty writeback 的 beat 数，当前固定 8。 |
| `per_core_request_rate` | 单核在给定仲裁/队列下的可持续请求/周期。 |
| `cluster_throughput` | 每周期完成的 line 事务数（第一版 <= 1/8 或受状态机限制）。 |
| `probe_serialization` | 一个事务需要向多个 sharer probe 时，额外串行拍数。 |
| `saturation_core_count` | 当核数增加而 PoC 单端口不变时，吞吐不再随核数增长的拐点。 |

C4 不改 PoC，因此 32 核的带宽模型仍以 **“单 PoC + 单目录事务”** 为起点；
如果测量显示 8 核以上无法满足任何低耦合 smoke，应记录为已知退化，并建议
per-bank/分片作为后续架构决策，而非在 C4 中实现。

---

## 4. 8/16/32 核验收口径

### 4.1 总原则

每个规模至少需要：

1. **compile / elaboration**：参数化 `CORE_COUNT` 下 Verilator lint/elaboration
   或等价工具通过；记录工具版本、SHA、参数、生成文件规模。
2. **有限事务 smoke**：用 synthetic L1 client（不要求完整 `lcvex_core`）跑
   ReadShared/ReadUnique/Upgrade/WriteBack/Clean/Invalidate/Bypass 的短序列；
   记录通过与失败。
3. **资源/延迟趋势表**：RSS、编译时间、目录/仲裁/队列相关统计、事务延迟、
   probe 串行化、缓存/带宽 proxy。
4. **通过/失败规模**：明确哪些规模通过哪些测试，哪些只通过部分或无法运行；
   不得把“未运行”写成“通过”。

### 4.2 规模分级声明

| 规模 | 可接受声明 | 不可接受声明 |
| --- | --- | --- |
| 8 核 | 参数化 elaboration、有限 synthetic smoke、趋势表通过；作为 8 核规模候选。 | “8 核完整多核功能已验证”。 |
| 16 核 | 若只通过 compile/elaboration 和部分 smoke，也只能记录 “16 核 elaboration 通过，有限 smoke 部分/未通过”。 | “16 核架构合规/Linux SMP”。 |
| 32 核 | 只作为 **规模/资源趋势目标**；可以报告 “32 核能否 elaboration”，但不能宣称功能完成。 | “32 核 Linux/板级/物理签核”。 |

### 4.3 每规模建议测试内容

| 测试 | 8 | 16 | 32 | 说明 |
| --- | --- | --- | --- | --- |
| Verilator lint/elaboration | 必测 | 必测 | 尽力/记录上限 | 可能超时/内存，不能伪报。 |
| Synthetic L1 read/write/upgrade | 必测 | 必测 | 有限 | 覆盖多 sharer 失效。 |
| Multi-sharer probe 序列 | 必测 | 有限 | 有限 | 验证 probe 目标遍历。 |
| Dirty owner 迁移 | 必测 | 有限 | 有限 | 验证 M 唯一、PoC 写回。 |
| Reset/fault 注入 | 必测 | 有限 | 有限 | 确保不产生 stale response。 |
| MC-v2 envelope 每核记录 | 可选 | 可选 | 不要求 | 依赖 D0/checkpoint 工具。 |
| 完整 core 真实程序 | 不要求（C4） | 不要求 | 不要求 | 属于 C3/C5 范围。 |

---

## 5. 可机检测量报告模板

以下为建议的机器可检查模板（JSON）。每次 C4 规模运行只需填一份，字段缺失视为
“未测量”，不得默认通过。

```json
{
  "schema_version": 1,
  "report_id": "c4-scale-001",
  "task_id": "T-20260829-100",
  "source_sha": "<git commit sha>",
  "date": "YYYY-MM-DDTHH:MM:SS+0800",
  "core_count": 8,
  "config": {
    "CORE_ID_W": 4,
    "SOURCE_ID_W": 4,
    "TRANSACTION_ID_W": 8,
    "SHARER_W": 8,
    "OWNER_W": 3,
    "DIR_ENTRIES": 1024,
    "ARB_MODE": "FLAT_RR",
    "REQ_QUEUE_DEPTH": 1,
    "PER_BANK": false,
    "USE_REAL_CORE": false
  },
  "environment": {
    "tool": "verilator",
    "tool_version": "5.050",
    "os": "linux",
    "cpu_count": null,
    "memory_mb": null,
    "disk_mb": null,
    "timeout_s": null
  },
  "compile": {
    "status": "pass",
    "command": "verilator --lint-only ...",
    "exit_code": 0,
    "wall_seconds": null,
    "peak_rss_mb": null,
    "generated_files": null,
    "elaboration_error": null
  },
  "smoke": {
    "status": "pass",
    "command": "<smoke tb command>",
    "exit_code": 0,
    "wall_seconds": null,
    "peak_rss_mb": null,
    "coverage": {
      "read_shared": true,
      "read_unique": true,
      "upgrade": true,
      "writeback": true,
      "clean_invalidate": true,
      "bypass": true,
      "multi_sharer_probe": true,
      "dirty_owner_migration": true,
      "reset_fault": true
    },
    "failures": []
  },
  "resource": {
    "peak_rss_mb": null,
    "build_time_s": null,
    "sim_time_s": null,
    "peak_disk_mb": null
  },
  "trend": {
    "dir_bits": 8,
    "dir_entry_estimate": null,
    "arb_comb_depth": null,
    "probe_max_serial_beats": null,
    "refill_cycles": null,
    "writeback_cycles": null,
    "cluster_throughput_lines_per_cycle": null
  },
  "known_limits": [
    "未接入完整 core，仅 synthetic L1/BFM。",
    "未启动 Quartus/板级/物理签核。",
    "32 核仅规模目标，非功能完成。"
  ],
  "verdict": "scale-candidate"
}
```

### 5.1 趋势汇总表

建议每次 C4 测量后填写：

| 规模 | elaboration | smoke | build 时间 | peak RSS | 目录位宽 | 延迟 proxy | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 8 | pass/fail | pass/fail | s | MB | 8 | ... | candidate |
| 16 | pass/fail | partial/fail | s | MB | 16 | ... | trend-only |
| 32 | pass/fail | n/a | s | MB | 32 | ... | scale-target |

---

## 6. 与 C3 / C5 / C6 的依赖和边界

### 6.1 C4 依赖 C3

- C3 必须先完成四核目录/仲裁泛化（C3-A）、系统接线（C3-B）、控制面（C3-C）、
  TLB/checkpoint（C3-D）。否则 C4 的 8/16/32 测量没有可依赖的 `lcvex_l2_cluster`
  泛化版本。
- C4 可以提前做 **纯文档/测量模板/资源估计**，但不能跑真实 8/16/32 系统 smoke。
- C4 的规模测量不应替代 C3 的 4 核正确性候选。

### 6.2 C4 与 C5 边界

- C5 Linux SMP 在 C3/C4 稳定后另设门。C4 不做 Linux SMP，也不以 Linux 启动
  作为 8/16/32 核验收。
- C5 可能要求 32 核目标位图、GIC/IPI 路由、共享页表路径；这些必须先由 C4
  的资源/延迟报告给出可行性信号，再进入 C5。

### 6.3 C4 与 C6 边界

- C6 是 C 线合拢：与 B 线 profile/commit/memory 变更在同一候选汇合，验证
  MC-v2/checkpoint v4。C4 的规模报告是 C6 的输入之一，但 C4 不负责最终合拢。
- C6 若引入 per-bank/分片或新 sidecar，必须升级协议/checkpoint 版本，不得
  把 C4 测量结果当作架构合规。

---

## 7. 风险登记

### 7.1 R-C4：IRQ/PSCI/TLBI 竞态（高）

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| WFI/SEV、IPI 和 CPU_ON/OFF 的异步事件顺序不可重放。 | 8 核以上无法判断中断实际由谁、何时接收。 | C3 先实现每核 async event + MC-v2 `global_seq`；C4 只测 synthetic BFM 的中断路由，不测真实并发。 |
| TLBI shootdown 在全表广播下可能有很多核同时失效，造成 pending 风暴。 | 16/32 核可能长时间阻塞。 | C4 测量必须报告 shootdown 的串行/广播延迟；若超限，记录为退化并建议分片/位图。 |
| PSCI CPU_OFF 与在途内存请求/commit 边界不严格。 | 核停止后目录仍可能认为有 outstanding，导致 stale state。 | C3 先固化 quiesce/drain/stop 顺序；C4 不实现 PSCI。 |

### 7.2 R-C5：32 核仿真/资源爆炸（高）

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 32 个完整 `lcvex_core` + L1/MMU 的 Verilator 构建时间/RSS 超限。 | 无法得到可靠报告，或误把 timeout 当通过。 | C4 使用 synthetic client/简化 memory；完整 core 只做小规模。 |
| 目录位图/仲裁组合逻辑在 32 核时面积/延迟急剧恶化。 | 不能简单地“参数化即成功”。 | 报告 `dir_bits`、组合深度、面积/latency proxy；若超阈值记录退化。 |
| 32 核有限 smoke 可能因全局单事务吞吐不足而长期不结束。 | 失败/超时会被误判为功能错误。 | 明确定义最大事务数/超时；超时归为资源/吞吐限制，不是一致性失败。 |
| 磁盘/构建产物随核数增长。 | worktree 或共享盘爆满。 | 固定 build 目录、限制生成文件、每次测量后清理/汇总，不把大产物进 Git。 |

---

## 8. 本任务非目标 / 已知限制

- 不实现/实例化 8/16/32 核功能 RTL。
- 不启动 Quartus，不做时序签核，不生成 SOF/JIC。
- 不宣称 32 核 Linux、板级、物理签核或完整 ARM 内存模型。
- 不修改 `rtl/`、`tb/`、`sim/`、QEMU、checkpoint 协议。
- 当前 C2 未完全关闭、C3 尚未实现，因此 C4 的实际 8/16/32 测量在 C3 之后执行。
- 本任务只交付设计、验收口径、测量模板和风险；未来 C4 实际规模报告应以此为
  模板，并逐项记录真实数据。

## 9. 参考资料

- `docs/C3_FOURCORE_PREWORK.md`
- `docs/MULTICORE_CLUSTER_CONTRACT.md`
- `docs/LCVX_DIFF_MC_V2.md`
- `docs/L1_L2_PROBE_CONTRACT.md`、`docs/L2_WRITEBACK.md`
- `docs/T-20260828-071-073-parallel-lines-plan-v2.md`
- `docs/decisions/ADR-20260829-005-v82-profile-parallel-lines.md`
- `docs/handoffs/T-20260829-086-c2-dualcore-msi.md`、
  `T-20260829-092-c2-remainder.md`、
  `T-20260829-089-c3-fourcore-prework.md`
