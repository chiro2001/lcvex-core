# Handoff 交接文档规范

handoff 是已完成工作或可复现失败现场的历史证据，不是实时任务看板。新任务使用
`docs/handoffs/<task-id>-<slug>.md`；已有的 `001-100` 编号文件保持原样，不重排、
不覆写。流程总则见 [`docs/MULTI_AGENT_WORKFLOW.md`](../MULTI_AGENT_WORKFLOW.md)。

## 必填模板

```markdown
# Handoff <task-id>: <title>

## 元数据
- task: T-YYYYMMDD-NNN
- owner:
- date:
- base_sha:
- head_sha:
- branch:
- worktree:
- dependencies:
- qemu_release:
- qemu_commit:
- qemu_patches_sha:
- rtl_filelist_sha:
- config/toolchain:
- evidence: docs/tasks/evidence/<task-id>.json

## 目标与边界

## 实现摘要
- 改动文件：
- 未改动/明确不在范围：
- RTL 状态、异常或系统寄存器（如适用）：reset / 权限 / 提交时机

## 验证证据
| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-l0-001 | L0 | |

精确命令、source SHA、版本、seed、退出码、资源和 artifact manifest 以 evidence
JSON 为准，不在 handoff 重复维护。

## 失败现场/重现

## 已知限制与后续任务

## 集成说明
```

普通日志、波形和小 trace 放在 `build/agents/<task-id>/`；大 trace、checkpoint、
sidecar 和 RAM 镜像放在 `build/tmp/<task-id>/` 或 artifact store。最终清单提交到
`docs/tasks/evidence/<task-id>.json`；本地 gitignored 路径不是长期证据。若需纠正
文档，新增 regression task/修订 handoff 并链接旧文档，不修改已合入的历史证据。

只有手工检索成为实际瓶颈后才生成 `docs/handoffs/INDEX.md`。任务 JSON 的
`context_docs` 只列本任务真正需要的设计文档和最近交接，Agent 不应为了启动一个
任务遍历全部历史文件。
