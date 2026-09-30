# ADR-20260828-004：dsh harness 多 Agent 控制面与派发适配

- 状态：accepted
- 日期：2026-08-28
- 关联：ADR-20260826-001（控制面与 worktree 布局）、ADR-20260826-002（子代理模型路由 v2）、T-20260828-070（dsh 试点）
- 关联提交：`b8110f9`…`9688d44`（T-070 试点闭环）、`e40f119`/`eb9d507`（模板路由同步定稿）

## 背景

本项目原有的多 Agent 工作流（`docs/MULTI_AGENT_WORKFLOW.md`）基于 codex 平台的
`spawn_agent`/`wait_agent`/模型路由（Terra/Sol/Luna/DeepSeek 多通道）。2026-08-28
起开发在 dsh（DeepSeek harness）中进行，subagent 由 harness 管理并自动通知完成。
T-20260828-070 用最小闭环（登记 → worktree → 派单 → 报告 → 合并 → 合并 SHA 复跑 →
evidence 定稿 → 归档）验证了流程可走通，同时暴露了工具语义差异。本 ADR 固化
dsh 下的执行口径，作为对 ADR-002 模型路由在 dsh 平台的执行修订。

## 决定

1. **派单一律省略模型**。dsh 的 `subagent`/`subagent_fork` 无 provider/model 参数，
   省略即平台默认通道（`deepseek-v4-flash[max]`）。后续所有 subagent 派单
   不指定模型，也**不再声称**使用了 Terra/Sol 等特定模型；需要高推理档的
   复杂拆解/方向评审由**集成者当前会话亲自承担**（集成者即高推理档模型），
   或仅在实际可用时通过 workflow 编排层的 `agent(prompt, {provider, model})`
   指定（不设为默认路径）。任务 JSON 中的 `model` 字段保留为意图记录，
   实际执行通道写 `dsh-default`。
2. **等待/轮询改事件驱动**。dsh 在 subagent 落定时自动通知集成者，不再需要
   `sleep 300` 轮询；**dsh 工具模式为默认执行模式，禁止使用 bash `sleep`
   循环或 `while kill -0 ...` 等方式等待/调度 subagent**；原轮询步骤
   （`list_agents` + worktree `status/log` + handoff/evidence 产物检查）合并到
   **收到完成通知后的收件核对**一步。`sleep` 仅用于等待外部世界（远端宿主、
   物理板、人工操作），且必须带时间戳（`date'+poll sent_at=...'` 格式）。
3. **报告结构化 + 持久化双写**。subagent 最终报告必须是含全部元数据的
   结构化文本块（`task/state/base/head/branch/worktree/sent_at/received_at/
   reported_at/files/tests/blockers/next`）；同一元数据必须写入 handoff 头部
   与 evidence JSON。中途通知（harness 转发）不作为有效报告，以最终消息 +
   handoff/evidence 为准。
4. **evidence 提交顺序**。owner 先提交**实现**，再单独提交 **evidence/handoff**
   修订（两个提交），使 evidence 能自引用 `head_sha`；`merge_sha` 由集成者在
   合并 SHA 复跑后补全定稿。
5. **预算与中断**。`max_is_hard_stop: true` 时用 `interrupt_agent` 实现硬停；
   默认 `false` 时以报告 `reported_at - sent_at` 核算耗时，超预算且无产出则
   用 `send_message` 发 `budget_note`，不中断。重型构建/QEMU/Quartus/Linux/
   Gate 使用 bash 后台 job（`run_in_background` + `job_output`/`job_kill`），
   不占用 subagent 预算。
6. **上下文管理（DCP 主动压缩）**。集成者（主 Agent）在每个逻辑节点收尾后
   （约每 15–25 次工具调用），用 `compress` 压缩**早于最近 2 个回合**的已关闭
   区间；摘要必须写成完整技术事实（SHA、分支、worktree、失败点、结论），
   **禁止占位符**；用户指令与工具输出由工具自动原样保留。压缩边界错误
   （进入最后 2 回合/未配对区间）会被工具拒绝，属正常保护。
7. **术语映射**。`spawn_agent`→`subagent`（默认 fresh context，等价
   `fork_turns=none`）；`fork_turns=N`→`subagent_fork`；发消息/send
   →`send_message`；中断→`interrupt_agent`；状态→`list_agents`
   （`scope=descendants` 看全树）；重型命令→bash 后台 job。**agent id 与
   job id 是两套体系**：`job_output` 不识别 subagent id，反之亦然。

## 备选方案

- 在 dsh 继续用 `sleep 300` 手工轮询：可保持文档最小改动，但与 harness 通知
  机制重复，且浪费等待时间。**不采纳**。
- 为 subagent 封装模型路由层：dsh 工具无此参数，只能靠 workflow 编排层，功能
  受限且增加复杂性。**不采纳为默认路径**。

## 影响

- ADR-002 的"模型路由 v2"在 dsh 下可执行部分收敛为单通道 + 集成者亲自评审；
  历史任务记录中的 Terra/Sol/Luna 均为 codex 时代事实，不改写。
- `MULTI_AGENT_WORKFLOW.md` §2.2 轮询/派单措辞以本 ADR 为准修订。
- 后续派单消息不再包含模型声明；时间戳与双写字段成为验收前置条件。

## 验证/迁移计划

- T-070 试点：完整闭环 + 时间戳合规 + compress 主动压缩可行（40 条折叠成功，
  边界拒绝符合预期）。
- 本 ADR 合入后 L0：`python3 -m json.tool` 相关 JSON、`git diff --check`。
