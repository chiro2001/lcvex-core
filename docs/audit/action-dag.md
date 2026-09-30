# 外部审计 Action Items DAG

> 来源：T-20260829-105 静态审计
> 规划：按优先级分 P0/P1/P2/P3
> 正式任务：T-20260829-106 ~ T-20260829-119
> 状态更新：截至 2026-08-30，AUD-01 至 AUD-13 均已有内部任务完成/关闭；
> AUD-14 仍为外部资源阻塞。

## P0（发布门禁阻塞）
- `T-20260829-106` AUD-01：Gate D baremetal-C/toolchain 硬修复
  - ✅ 已完成（内部 evidence/handoff 记录）
  - 无依赖
  - 完成后才允许使用 Gate D 作为发布候选

## P1（正确性/可复现/FPGA 高风险）
- `T-20260829-107` AUD-02：当前 HEAD make test
  - ✅ 已完成（T-20260830-022 亦覆盖）
- `T-20260829-108` AUD-03：当前 HEAD Gate D + CORE_COUNT=1
  - ✅ 已完成（T-20260830-022 PASS）
- `T-20260829-109` AUD-04：异步 FIFO CDC / 双域复位约束
  - ✅ 内部任务已闭合；实际板级/TimeQuest 证据仍待 Gate F-BOARD
- `T-20260829-110` AUD-05：Gate D 产物持久化/取回
  - ✅ 已完成（T-20260829-110；小日志/摘要已持久化，大产物保留可重建引用）
- `T-20260829-111` AUD-06：QEMU patch 组合哈希 canonical
  - ✅ 已完成（canonical 定义与 13-patch 重生成见 T-20260830-023/AUD-13FIX）
- `T-20260829-112` AUD-07：CI difftest/nightly 前置 fail-fast
  - ✅ 已完成；GitHub 自动 CI 已按用户策略禁用，手动 workflow_dispatch 保留

## P2（治理/流程/文档，低风险）
- `T-20260829-113` AUD-08：evidence 定稿 + T-104 correction
  - ✅ 已完成
- `T-20260829-114` AUD-09：时间戳单调性/事件时间字段
  - ✅ 已完成
- `T-20260829-115` AUD-10：test registry 补全
  - ✅ 已完成（registry 明确为部分清单）
- `T-20260829-116` AUD-11：ROR 文档纠错
  - ✅ 已完成
- `T-20260830-025` EXT-01-FIX：evidence 定稿与时间戳逆序回填
  - ✅ 已闭合（EXT-01-001/002 action items marked resolved）
  - T-104/T-099 correction records 已回填，保留旧值；`scripts/check_task_timestamps.py`
    继续对历史 live 残留给出 error/warning，作为已知后续清理项。

## P3（后置/外部）
- `T-20260829-117` AUD-12：checkpoint v4 联合恢复
  - ✅ 已完成：T-20260829-117 QEMU/DUT 联合恢复 + CONTEXTIDR 对齐 PASS
- `T-20260829-118` AUD-13：QEMU fresh replay（依赖 111）
  - ✅ 已关闭：AUD-13 初查失败后由 T-20260830-023 完成 13-patch 修复
- `T-20260829-119` AUD-14：B5 full flow / DDR / 板级（依赖 109 等外部资源）
  - ⛔ proposed/open：仍受 Quartus OOM/顶层 Qsys+glue/远端资源限制，
    FPGA-F3/F4 blocked，T-067 未解除

## 执行规则
- 重型 Verilator/回归必须 cgroup <16GiB、一次一个。
- 每个任务只读已冻结审计结论，不得改写历史 handoff。
- 所有修复需以内部 handoff/evidence 证明后，才在 action-items 中更新状态。
