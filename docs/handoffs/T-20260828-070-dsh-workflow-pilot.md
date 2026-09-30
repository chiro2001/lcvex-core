# T-20260828-070 同步任务模板到当前模型路由（owner handoff）

状态：**owner L0 完成**，等待集成者在合并 SHA 复核并归档。

## 实现摘要

- `docs/tasks/TEMPLATE.json` 两处 `model_selection`（顶层与 `monitor`）由
  “平台默认 gpt-5.6-luna[max]” 改为 “派单时省略 `model`；当前项目默认
  `deepseek-v4-flash[max]`”，与 `docs/MULTI_AGENT_WORKFLOW.md` 2.1 节
  “Agent 类型与模型路由”表和路由规则第 1 条一致（2026-08-28 起默认派单通道
  为 `deepseek-v4-flash[max]`）。
- 删除与现行路由矛盾的 `disabled_profiles: ["deepseek-v4-flash[max]"]` 字段
  （该字段唯二出现处为 TEMPLATE 与 archive 任务；无脚本/工具链引用，
  其他模板字段不依赖它）。
- 复核 `complex_planner`（`gpt-5.6-terra` / `xhigh`）与 `review`
  （`gpt-5.6-sol` / `high`）字段，与 2.1 节表一致，未改动。
- 复核 `agent_type` 文本（`slow-implementation-monitor`、`complex-task`、
  `architecture-review`）与 2.1 节类型名一致，未改动。

## 边界

- 只改 `docs/tasks/TEMPLATE.json` 的模型路由相关字段；未触碰任何
  `docs/tasks/active/*`、archive、`TASKS.md`、`PROJECT_STATUS.md`、
  `ROADMAP.md`、QEMU fork、RTL、Makefile。
- 不改路由策略本身（ADR 层面不在本任务范围）。
- 保留模板内既有的 `monitor.scope` 缩进风格未动（非本任务字段，不做无关格式化）。

## 验证

- `python3 -m json.tool docs/tasks/TEMPLATE.json`：合法 JSON。
- `git diff --check`：无 whitespace 错误。
- `grep -n "luna" docs/tasks/TEMPLATE.json`：无输出（旧默认通道引用已清除）。
- 人工复核：`model`/`model_selection`/`disabled_profiles` 与
  `MULTI_AGENT_WORKFLOW.md` 2.1 节表 + 路由规则第 1 条无矛盾。

## Evidence

命令、exit code 见 `docs/tasks/evidence/T-20260828-070.json`（owner 初版，
合并 SHA 复跑由集成者定稿）。

## 风险 / 注意

- 模板是后续新任务 JSON 的母版；此后新建任务应保持“派单时省略 `model` =
  `deepseek-v4-flash[max]`”写法，禁用字段不要再从旧 archive 复制回来。
- archive 任务中的旧 `disabled_profiles` 与 “gpt-5.6-luna[max]” 记录为历史
  事实，不改写；若未来切换默认通道，由集成者同步 2.1 节与 TEMPLATE。
