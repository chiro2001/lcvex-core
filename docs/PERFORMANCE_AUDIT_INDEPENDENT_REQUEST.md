# LCVEX 独立外部性能审计与增强规划需求（PE-EXT）

## 目的

由独立审计 Agent 对 LCVEX 当前 core / cache / 总线 / 多核系统进行一次独立、外部视角的性能静态审计，产出一份“性能增强规划”，后续与内部 PE-A 审计结果综合，形成最终可实施性能增强计划。

## 审计对象

- Core：LCVEX AArch64 单核 in-order core（P6/P7）。
- Cache：L1I、L1D WB、L2 WB、L1 coherence、共享 L2 目录 MSI。
- 总线/内存：mem_router、AXI4、Avalon/EMIF、jitag/epcq/status 等。
- 多核：C1–C4 cluster、sysctrl/PSCI-lite、共享 RAM、目录仲裁。
- 性能测量：现有 P-line 14 个 workload 与 C4 dualcore baseline。

## 必须评估的候选方向（用户明确点）

1. 是否改为更深的流水级数？
2. 是否改为顺序多发射（如 2-wide in-order issue）？
3. 是否支持 outstanding 访存（MSHR / 多未命中处理）？
4. 其他性能方向，包括但不限于：
   - 取指宽度 / 分支预测 / 前段缓冲
   - L1/L2 多 bank、流水化、更宽 line、非阻塞
   - 写回/refill 路径优化
   - 总线加宽、突发、异步 FIFO、outstanding
   - 多核目录并行化、仲裁改进
   - 提交/backpressure 优化
   - 异常/维护路径对性能的影响

## 独立审计要求

- 站在外部/第三方审查角度，不自证“已优化”。
- 对每个候选方向给出：
  - 当前结构/证据
  - 瓶颈假设
  - 预期收益方向（IPC / 带宽 / 延迟 / 面积 / 复杂度）
  - 改动范围与风险
  - 验证/度量方法
  - 优先级：P0 / P1 / P2
  - 依赖或前置条件
- 明确哪些方向适合下一步实施，哪些应后置或不做。
- 不得修改 RTL；只读审计。
- 不得把未实现的性能收益宣称成已完成。

## 交付物

1. `docs/PERFORMANCE_ENHANCEMENT_PLAN_INDEPENDENT.md`
2. `docs/handoffs/T-20260830-035-pe-ext-audit.md`
3. `docs/tasks/evidence/T-20260830-035.json`

## 与内部 PE-A 的关系

- PE-A 也会产生 `docs/PERFORMANCE_ENHANCEMENT_PLAN.md`。
- 两份都完成后，由集成者合并成最终 `docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md`。
- 在合并前，不启动性能增强 RTL 实施。
