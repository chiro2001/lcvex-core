# 架构与流程决策（ADR）

这里记录跨子域、会影响后续实现或验证口径的长期决定；单任务实现细节放在
handoff，当前里程碑放在 `PROJECT_STATUS.md`。文件名使用
`ADR-YYYYMMDD-NNN-<slug>.md`，合入后不改写结论，修订时新增 ADR 并链接旧版本。

最小字段：状态（proposed/accepted/superseded）、背景、决定、备选方案、影响、
验证/迁移计划、关联任务和关联提交。

## 当前决策

- [ADR-20260826-001：多 Agent 控制面与 Worktree 布局](ADR-20260826-001-multi-agent-control-plane.md)
- [ADR-20260826-002：子代理模型路由 v2](ADR-20260826-002-agent-model-routing-v2.md)
- [ADR-20260827-003：P7 与 Catapult 上板双轨、AXI4 和一致性边界](ADR-20260827-003-p7-fpga-parallel-axi4.md)
- [ADR-20260828-004：dsh harness 多 Agent 控制面与派发适配](ADR-20260828-004-dsh-control-plane.md)
- [ADR-20260829-005：V82 非 SVE profile 与 T-071～T-073 并行路线执行口径](ADR-20260829-005-v82-profile-parallel-lines.md)
