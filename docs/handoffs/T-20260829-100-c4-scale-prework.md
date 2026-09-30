# T-20260829-100 C4 8/16/32 核规模前置设计与测量契约（C4-pre owner handoff）

> **重要声明**：本任务只完成 C4 前置设计/测量契约，不代表 8/16/32 核功能已完成；
> C4 实际规模测量/实现需在 C3 四核正确性候选稳定后执行；当前不修改 RTL、
> 不启动 Quartus、不宣称 32 核功能/板级/物理签核完成。

```text
task=T-20260829-100 state=review base=df3c8ba5fcb75632c31fd6f780a1861a2566eac4 head=d5c1cd8db7194a0c541038ab4e01e34cc38df1b3 branch=feature/T-20260829-100-c4-scale-prework worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-100 sent_at=2026-08-29T16:39:49+0800 received_at=2026-08-29T16:39:49+0800 reported_at=2026-08-29T16:39:49+0800 files=docs/C4_SCALE_PREWORK.md,docs/handoffs/T-20260829-100-c4-scale-prework.md,docs/tasks/evidence/T-20260829-100.json tests=git-diff-check,json-tool,allowed-write-scope-check blockers=C2-not-closed,C3-not-implemented,no-real-scale-measurement,no-quartus next=review-then-C3-close-and-C4-scale-runs
```

## 1. 任务边界

- 只读前置任务，新建分支 `feature/T-20260829-100-c4-scale-prework`，基线
  `df3c8ba5fcb75632c31fd6f780a1861a2566eac4`。
- 只写：
  - `docs/C4_SCALE_PREWORK.md`
  - `docs/handoffs/T-20260829-100-c4-scale-prework.md`
  - `docs/tasks/evidence/T-20260829-100.json`
- 未修改 `rtl/`、`tb/`、`sim/`、QEMU、checkpoint 协议或任务台账。

## 2. 交付摘要

### `docs/C4_SCALE_PREWORK.md`

1. **CORE_COUNT 参数化扩展定义**：
   - cluster topology：8 核平铺共享 L2/目录；16/32 核预留 slice/tree/per-bank 扩展。
   - 目录位图：`SHARER_W=CORE_COUNT`、`OWNER_W=clog2(CORE_COUNT)`；
     8 可单周期，16/32 需关注面积/搜索延迟。
   - 仲裁树/队列：`FLAT_RR` baseline，`SLICE_TREE`、`PER_BANK` 预留；记录每核
     outstanding/队列深度。
   - 每核 MMIO/中断路由：共享 GICD + per-core GICC，SGI 位图随核数扩展，
     共享外设先固定 core0。
   - 共享 L2 带宽模型：固定 8B PoC beat，单事务/单 PoC 下 8/16/32 核只能报告
     趋势，不宣称线速。
2. **8/16/32 核验收口径**：
   - 每规模至少 compile/elaboration、有限 synthetic smoke、资源/延迟趋势表。
   - 8 核可作为规模 candidate；16 核只能按通过范围记录；32 核只作为规模目标，
     不得表达为 Linux/板级/物理签核。
3. **C4 与 C3/C5/C6 依赖边界**：
   - 依赖 C3 先完成 4 核目录/仲裁/系统/控制面；C4 可提前做模板/资源估计。
   - C5 Linux SMP 后置，C4 不以 Linux 启动为验收。
   - C6 合拢负责版本/checkpoint 升级；C4 报告只是输入。
4. **可机检测量报告模板**：
   - 提供 JSON 模板：source_sha、config、environment、compile、smoke、resource、
     trend、known_limits、verdict。
   - 提供趋势汇总表字段。
5. **风险**：
   - R-C4：IRQ/PSCI/TLBI 竞态，async event 顺序、shootdown 广播/串行化。
   - R-C5：32 核仿真资源爆炸，完整 core 构建超限、目录/仲裁组合恶化、
     全局单事务吞吐不足。
   - 均给出测量/缓解口径，不把超时视为一致性通过。

## 3. 验证摘要

| 检查 | 命令/方法 | 结果 |
| --- | --- | --- |
| 空白错误 | `git diff --check` | 通过 |
| JSON 合法 | `python3 -m json.tool docs/tasks/evidence/T-20260829-100.json` | 通过 |
| 写集边界 | `git status --short` / `git diff --name-only` | 仅 3 个允许文档 |
| RTL/非功能代码 | `git diff --stat -- rtl tb sim qemu` | 无改动 |

## 4. 文件列表

- `docs/C4_SCALE_PREWORK.md`
- `docs/handoffs/T-20260829-100-c4-scale-prework.md`
- `docs/tasks/evidence/T-20260829-100.json`

## 5. 已知限制 / blocker

1. **C2 未完全关闭**：当前 C2 remainder 仍有原子/同 line 可见性缺陷，真实双核
   指令级证据未闭合。
2. **C3 尚未实现**：四核目录/仲裁泛化、GIC/PSCI/IPI/TLB 控制面都还未落地，
   所以 8/16/32 核实际测量无从开始。
3. **本任务无真实规模测量**：只提供模板、口径和设计，不宣称任何规模通过。
4. **未启动 Quartus/板级/物理签核**：T-067 等外部条件仍与 C4 无关。
5. **32 核不是功能完成目标**：只能作为参数化/资源/延迟趋势目标。

## 6. 下一步

1. 集成者 review 本 C4-pre 文档；若接受，作为后续 C4 实际规模报告的契约输入。
2. 继续关闭 C2，再完成 C3-A/B/C/D。
3. C3 四核正确性候选稳定后，按本模板执行 8→16→32 核的
   compile/elaboration、有限 smoke 和资源/延迟测量。
4. 若 16/32 核出现资源/仲裁退化，记录上限并建议 per-bank/slice 决策，不直接
   在 C4 实现。
