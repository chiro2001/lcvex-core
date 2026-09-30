# 06 多核与一致性现状

> 状态：**C2 双核目录式 MSI 已完成；C3 四核功能实现已合入并通过定向/完整四核
> 矩阵；C4 8/16/32 核规模趋势测量已完成；Linux SMP 和完整多核差分仍未完成。**
> 依据：`docs/MULTICORE_CLUSTER_CONTRACT.md`、`docs/C3_FOURCORE_PREWORK.md`、
> `docs/C4_SCALE_PREWORK.md`、`docs/C4_DUALCORE_BASELINE.md`、
> `docs/LCVX_DIFF_MC_V2.md`、T-20260829-095/T-20260830-018/T-20260830-019。

## 1. 当前分级

| 级别 | 状态 |
| --- | --- |
| C0 多核契约 | 完成（文档/接口/事务草案） |
| D0 多核差分可行性 | 完成（LCVX-DIFF-MC-v2 设计） |
| C1 双核壳层 | 完成（参数化复制，默认 COHERENCE_ENABLE=0） |
| C2 双核目录式 MSI | 完成（模块级 + 系统接线 + 真实双核 message passing + 原子/屏障/reset 定向） |
| C3-pre 四核前置 | 完成（设计/拆解） |
| C3 四核功能 | **完成（功能矩阵/PASS，merge `fccb674`）**：参数化目录/仲裁、4 核 shared-memory message-passing、sysctrl（GIC/PSCI-lite、SGI/SEV、启动/停止/reset）、timer 定向；已知无 TLB shootdown、多核 checkpoint、Linux SMP |
| C4-pre 规模契约 | 完成 |
| C4 双核 baseline | 完成（只读测量） |
| C4 8/16/32 核 | **规模/趋势测量完成（T-20260830-018/019）**：8 核 default-FP cluster lint/elab + synthetic smoke PASS；16/32 核 no-FP cluster、目录和 synthetic smoke PASS；16 核 default-FP 未完成、32 核未测；不是完整功能/合规 |
| Linux SMP | **后置**（非当前 F/多核交付前提） |

## 2. 目录式 MSI 实现

- 共享 L2 上游目录，`lcvex_l2_cluster.sv` 维护每 line 的 `I/S/M` 状态，
  支持 `ReadShared/ReadUnique/Upgrade/WriteBack/Clean/Clean+Invalidate/
  Invalidate/Bypass`。
- 数据源为 PoC 或 dirty owner probe 返回值；PoC 保持现有 M1-B 8B 端口。
- `M` 不变式：owner 唯一、sharers==owner、dirty=1；`S`：sharers!=0、owner=0、
  dirty=0；`I`：全零。模块内有行级不变式 SVA。
- 每核有独立 `core_wrap` 和 coherence 端口；`COHERENCE_ENABLE=1` 时
  `lcvex_cluster_top` 实例化共享 `lcvex_l2_cluster` 和共享 RAM。
- C2 真实双核 message-passing TB 已通过：两核读到 flag=0x5a；原子失败/成功、
  barrier/maintenance、reset/fault 定向也已通过。

## 3. CORE_COUNT 参数化

- `lcvex_cluster_top` 有 `CORE_COUNT` 参数并通过 `generate` 复制每核；
  C3 已移除隐式 2 核目标硬编码并支持 4 核；C4 进一步验证 8/16/32 参数化。
- 目录位图宽度：`SHARER_W=CORE_COUNT`；当前 RTL 中 `OWNER_W` 仍为一热位图
  （8/16/32 核时分别为 8/16/32 bit），不是压缩编码。
- C3/C4 测量确认：`lcvex_l2_cluster` 模块级 lint/elab 在 8/16/32 均快速通过；
  `cluster_top` no-FP 在 16/32 通过；默认 FP 在 8 核通过，16 核未完成。
- `CORE_COUNT=1` 是回归锚点；T-20260830-022 已专门重跑 `CORE_COUNT=1`
  cluster/l2_cluster lint PASS，F 单核路径不依赖 cluster coherence。

## 4. 单事务 / 单 outstanding 局限

- 当前 C2 每核单 outstanding、全局单事务；仲裁为 `FLAT_RR` + liveness fallback。
- 单事务意味着同一时刻只能有一个 line-level coherence 事务，探测只能单目标。
- 这不是完整多核性能/并发架构；8/16/32 核只能做资源/趋势测量，不能宣称线速。
- C4-scale 文档给出 `SLICE_TREE`、`PER_BANK` 作为未来扩展预留，但未实现。

## 5. C4 baseline 数据（部分）

来源 `docs/C4_DUALCORE_BASELINE.md` / `fpga/opensynth/c4_dualcore_baseline.json`，
基线 SHA `2a697bb922e6e7af353d399b2f0e6f6bb26d150c`：

| 测量 | 值 |
| --- | --- |
| Verilator | 5.050 |
| CORE_COUNT | 2 |
| COHERENCE_ENABLE | 1 |
| L1MSI build | 24.046s / 434.5MB max RSS |
| DUALCORE build | 371.038s / 3364MB max RSS |
| L1MSI smoke | 0.018s / 28 PASS |
| DUALCORE smoke | 0.020s / 51 commits / PASS |
| dir_sharers / dir_owner | 2 bit / 2 bit |
| ARB_MODE | FLAT_RR |
| PoC | 64-bit beat, 8 beats/line |

边界：该测量期间存在无关的 C3 Verilator 构建并发，不是绝对安静窗口；只代表
C2/CORE_COUNT=2 只读 baseline，不代表 4/8/16/32 核完成。

## 6. ACE/CHI/SVE 边界

- 设计明确**不引入 ACE/CHI**；下游保持 AXI4/Avalon 边界，上游用共享 L2
  目录式 MSI（MESI-lite 扩展点在 C0 契约中预留，但非默认）。
- 不实现 coherent DMA、E/O 状态、硬件 MESI/MOESI 完整模型。
- SVE/SVE2/SME 不在本轮范围；SVE 相关仅 Linux probe shim。

## 7. 当前风险

- C2 系统级证据是定向 TB，不是完整 QEMU 多核锁步；多核差分协议仍为设计。
- 全局序列/`global_seq` 目前是设计，`C1 envelope` 中 global_seq=0；多核异步事件
  （IRQ/PSCI/TLBI）顺序未进入真实差分。
- 多核 checkpoint v4 字段设计存在，但完整多核恢复未实现。
- `core_fault` 在 wrapper 中恒为 0，full-core fault 注入未做正向验证。
- running reset/restart 场景仍有 assert 风险，当前只验证 stop→reset→保持 stopped。
- `CORE_COUNT=1` 回归已在 T-20260830-022 重跑通过（cluster/l2_cluster lint）；
  完整 fourcore 系统级 TB 仍非 Gate D 必选，已由 C3 功能矩阵与 8 核 smoke 覆盖。
- 16/32 核默认 FP 完整 cluster 构建仍未通过窗口/资源验证；这是多核性能/规模
  进一步工作的明确限制。
