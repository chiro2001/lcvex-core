# 任务注册表

任务注册表用于多 Agent 派单，不替代 `ROADMAP.md` 或 `PROJECT_STATUS.md`。完整规则
见 [`docs/MULTI_AGENT_WORKFLOW.md`](../MULTI_AGENT_WORKFLOW.md)。

- `active/T-*.json`：待做或进行中的任务；只由集成者创建和更新。
- `archive/T-*.json`：`done/cancelled` 任务的只读归档。
- `evidence/<task-id>.json`：机器可读的精确验证事实。
- `TASKS.md`：带日期的人读快照，不是实时看板；A0 由集成者手工维护。
- `TEMPLATE.json`：新任务模板，不是可领取任务。

`assigned_owner` 是集成者的静态分配。A0 不手工维护 heartbeat/lease 数据库：Agent
用 task ID、commit 和短报告更新进度，集成者更新持久状态并统一安排重型测试时隙。
只有手工派单成为实际瓶颈后，才增加薄 `taskctl.py`。

最小流程：

1. 集成者登记 `base_sha`、依赖、写集、context、验收和 owner；
2. 从记录的 `base_sha` 创建独立 sibling worktree；
3. owner 完成实现、测试、必要文档、handoff 和初版 evidence，报告进入 `review`；
4. 集成者合入并在 merge SHA 重跑任务要求的 L0–L2，补齐 evidence；通过后归档。

默认只有 `done` 满足依赖。同一路径的写集保留到任务 `done/cancelled`，不能在等待
review/merge 时另派给其他任务。任务进入 `review` 时 `merge_sha` 可以为空，归档前
必须由集成者补齐。状态不能只存在聊天记录中。

## dsh 平台下的派单补充约定（ADR-20260828-004）

- 派单一律省略 `model`（= dsh 默认通道 `deepseek-v4-flash[max]`）；任务 JSON 的
  `model` 保留为意图记录，实际执行通道记录 `dsh-default`。
- 报告双写：subagent 最终报告为结构化元数据块（`task/state/base/head/branch/
  worktree/sent_at/received_at/reported_at/files/tests/blockers/next`），并同步
  写入 handoff 头部与 evidence JSON；中途通知不作为有效报告。
- evidence 提交顺序：owner 先提交实现、再单独提交 evidence/handoff 修订
  （两个提交）以自引用 `head_sha`；`merge_sha` 由集成者定稿补齐。
- 等待用 harness 完成通知，不轮询；`sleep` 仅用于等待外部世界且必须带时间戳。
- 细节见 [`docs/MULTI_AGENT_WORKFLOW.md`](../MULTI_AGENT_WORKFLOW.md) §2.2 与
  ADR-004。
