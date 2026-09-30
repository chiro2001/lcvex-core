# ADR-20260826-002：子代理模型路由 v2

- 状态：accepted
- 日期：2026-08-26
- 关联规范：[`docs/MULTI_AGENT_WORKFLOW.md`](../MULTI_AGENT_WORKFLOW.md)
- supersedes：ADR-20260826-001 中关于模型路由的旧约定

## 背景

初版模型分工只有评审、快速实现和慢速实现三类，无法区分复杂跨域方案与普通长跑
任务。联通测试表明 Terra 可以完成受控的跨文档依赖综合；用户同时要求暂时停用
DeepSeek，并重新平衡高成本审核与耗时实现。

## 决定

1. **Terra `[xhigh]`** 用于复杂跨域方案、依赖拆解和高难度问题；不替代最终审核，
   不自行修改集成热点或合并分支。
2. **Luna `[max]`** 用于耗时任务、长编译、checkpoint/Linux 监控和相对简单编码。
   派单时省略 `model`，并显式设置 `reasoning_effort=max`，选择默认 Luna 通道。
3. **Sol `[high]`** 用于方向性审核。输入限制为 task JSON、指定文档和目标 diff；
   输出只包含大方向、阻断风险和验收建议，不给逐行实现方案。
4. **DeepSeek 暂停**：用户重新启用前不创建新的 DeepSeek 任务；历史证据和已归档
   任务不改写。
5. 主/集成 Agent 负责 Terra → Sol → Luna 的顺序、资源队列和最终复测；模型名称、
   reasoning effort 和可见范围必须记录在任务 JSON/evidence。

## 迁移

当前活动任务 T-20260826-002 改为默认 Luna[max] 实现；必要时先由 Terra 做复杂边界
拆解，再由 Sol[high] 做受限审核。已有 Luna 草稿保留为失败现场，未通过审核前不得
合并。任务模板默认使用 Luna[max]，并把 Terra 设为可选复杂规划器。
