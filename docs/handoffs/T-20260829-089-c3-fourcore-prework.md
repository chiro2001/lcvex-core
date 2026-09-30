# T-20260829-089 C3 四核前置设计/拆解（C3-pre owner handoff）

> **重要声明**：本任务仅完成 C3 前置设计/契约拆解，不代表 4 核功能已完成；
> **C2 双核 MSI 未关闭，C3 实际功能实现不得派发。**

```text
task=T-20260829-089 state=review base=7c847561d3de3edeee0f7f8937fd3929fc101ba6 head=c5afbc220bbdeeaff0215e16ae568c3643239f01 branch=feature/T-20260829-089-c3-fourcore-prework worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-089 sent_at=2026-08-29T08:09:33+0800 received_at=2026-08-29T08:09:33+0800 reported_at=2026-08-29T08:09:33+0800 files=docs/C3_FOURCORE_PREWORK.md,docs/handoffs/T-20260829-089-c3-fourcore-prework.md,docs/tasks/evidence/T-20260829-089.json tests=git-diff-check,json-tool,allowed-write-scope-check blockers=C2-not-closed,no-real-dualcore-instruction-level-evidence,global-seq-not-implemented,multicore-checkpoint-v4-not-implemented next=integrator-review-C2-close-then-C3-A
```

## 1. 任务边界与结论

- 本任务按用户边界只修改：
  - `docs/C3_FOURCORE_PREWORK.md`
  - `docs/handoffs/T-20260829-089-c3-fourcore-prework.md`
  - `docs/tasks/evidence/T-20260829-089.json`
- 未修改 `rtl/`、`tb/`、`sim/`、QEMU、checkpoint 协议、任务台账或其它文件。
- 交付物是一份 C3 前置设计文档，包含 C3 所需子系统、与 C2 当前接口差距、
  C2 必须关闭的点、可先独立准备项、每核异步事件/全局序列/checkpoint 扩展、
  建议 4 个低耦合切片及其验收标准，以及风险登记。
- **结论：C3 功能 RTL 不宜在当前状态开始。** 当前 base 只有 C2 模块级
  MSI 已合入，C2 系统接线（coherent L1 + cluster + real dual-core TB）仍在该
  任务分支未合入/未完成，真实双核指令级 litmus、CAS/STXR、barrier、
  DC+IC+ISB 尚无通过证据。

## 2. 交付摘要

### `docs/C3_FOURCORE_PREWORK.md`

1. **现状盘点**：C1 壳层、C2 模块级 MSI、单核 GIC/MMIO/PSCI/TLB 现状；
   指出 `rtl/lcvex_l2_cluster.sv` 存在两处隐式 2 核 target 硬编码
   （`dir_owner[0] ? 0 : 1`、`1-arb_sel`）。
2. **C3 所需子系统**：
   - GIC/PSCI/Timer：共享 GICD + per-core GICC、per-core PPI、
     PSCI 真实启停控制面、启动次序。
   - IPI/SEV/WFE：SGI 路由、SEV 广播/SEVL 本核、event register 唤醒。
   - TLB shootdown：第一版全表失效广播 + 完成确认。
   - 共享 MMIO 路由：共享 router、GICD/GICC 分址、UART 等共享外设路由。
   - 公平仲裁：4 核 round-robin/liveness，单事务正确性优先。
3. **与 C2 差距/依赖**：系统接线、GIC/PSCI、MPIDR、event 端口、TLBI、
   MMIO、MC-v2/checkpoint 的差距表。
4. **C2 必须关闭的点**：系统接线合入、真实双核构建/指令级证据、
   `CORE_COUNT=1` 回归、I0 对 MPIDR/start-stop/event/checkpoint 的决策。
5. **可先独立准备**：MC-v2 事件矩阵、checkpoint v4 字段、GIC/PSCI 函数矩阵、
   4 核测试目录、C2 硬编码审计、资源估计、仲裁公平性定义。
6. **每核异步事件/全局序列/checkpoint 扩展**：引用 LCVX-DIFF-MC-v2 v2
   envelope、v2 消息 32..42、`global_seq/vcpu_seq/event_kind` 要求、恢复顺序。
7. **建议子任务拆分（4 片）**：
   - C3-A 四核目录/仲裁参数化（推荐先做，不依赖 GIC/PSCI）。
   - C3-B 四核系统壳层与启动/共享内存接线。
   - C3-C GIC/PSCI/IPI/SEV/WFE 控制面。
   - C3-D TLB shootdown、checkpoint v4 与 4 核压力。
8. **风险登记**：C2 未关闭、async event 顺序、共享内存/中断竞态、
   checkpoint 恢复、资源上限、MPIDR/event 改核心、过度宣称等。

## 3. 验证摘要

| 检查 | 命令/方法 | 结果 |
| --- | --- | --- |
| 空白错误 | `git diff --check` | 通过 |
| JSON 合法 | `python3 -m json.tool docs/tasks/evidence/T-20260829-089.json` | 通过 |
| 写集边界 | `git status --short` / `git diff --name-only` | 仅 3 个允许文件 |
| 非功能代码 | `git diff --stat -- rtl tb sim qemu` | 无改动 |

## 4. 文件列表

- `docs/C3_FOURCORE_PREWORK.md`
- `docs/handoffs/T-20260829-089-c3-fourcore-prework.md`
- `docs/tasks/evidence/T-20260829-089.json`

## 5. 已知限制 / blocker

1. **C2 未关闭**：真实双核指令级证据缺失，C3 功能 RTL 被阻塞。
2. **C2 系统接线分支未合入本 worktree**：`e36cf4a`/`de668d3` 在
   `feature/T-20260829-086-c2-dualcore-msi`，未作为 C3 可靠基础。
3. **MC-v2 的 `global_seq` 目前只是设计**：C1 envelope 中 `global_seq=0`，
   协调器/异步事件流未实现。
4. **多核 checkpoint v4 sidecar 未实现**：本任务只设计字段和恢复顺序。
5. **MPIDR/event/TLB 接口可能需要改共享核心热点**：C3 实施前需要 I0/集成者窗口。
6. **4 核 Verilator 资源未实测**：本文只列资源风险与缓解，不宣称可运行。

## 6. 下一步

1. 集成者 review 本 C3-pre 文档；若接受，作为 C3 规划输入。
2. **先关闭 C2**：合入 C2 系统接线并完成真实双核指令级 litmus/CAS/barrier/
   DC+IC+ISB，更新任务状态。
3. C2 关闭后，按建议先派 **C3-A：四核目录/仲裁参数化**，再依次 C3-B、
   C3-C、C3-D。
4. 在派发任何 C3 RTL 前，必须先得到 I0 对 MPIDR、start/stop 与 PSCI 关系、
   event 端口、checkpoint v4 的批准。
