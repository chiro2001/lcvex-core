# LCVEX 多 Agent 开发工作流

日期：2026-08-26

状态：A0 规范已落地，双 Agent 试点待执行

适用范围：LCVEX 仓库、链接的 Git worktree、外部 QEMU fork 和本地/CI 验证。

本文由 `/tmp/lcvex_multi_agent_plan.md` 和当前仓库实际入口审阅后收敛而成。目标是
让实现、评审和验证尽量重叠，同时保留严格的 QEMU 差分可信度。先运行最小流程，
只有实际出现瓶颈后才增加自动化。

## 1. 结论

| 问题 | 当前决定 |
| --- | --- |
| 是否需要单独任务管理器 | **目前不需要常驻服务或独立调度进程**。主/集成 Agent 就是任务管理者；任务增多后可加一个标准库 Python `taskctl` 薄 CLI，但不是 A0 前置条件 |
| 任务事实源 | 每任务一份 `docs/tasks/active/T-*.json`，只由集成者更新；`TASKS.md` 是带日期的审计快照，不是实时看板 |
| Agent 工作区 | 每个会写文件或运行构建/测试的任务使用一个仓库外 sibling Git worktree 和唯一 topic 分支 |
| Agent 文档 | handoff 保存人读结论和风险；evidence JSON 保存精确测试事实；跨任务长期决定写 ADR |
| 资源调度 | Agent 的分析/编码并行；本机与 GamePC 重任务分别通过共享 `local`/`gamepc` 锁独占排队。持锁任务采用有证据的动态预算，不再固定为本机 50% 或 16 GiB |
| 全局验收 | Agent 跑受影响 L0–L2；集成者在合并 SHA 重跑任务要求的子集；Gate D 只在冻结 integration candidate 上运行 |

推荐当前 12 核、约 32 GiB 机器采用：**1 个集成者 + 2 个功能 Agent + 1 个只读
评审/验证 Agent**。四个 Agent 可以同时思考、审阅和编码，但本机 heavy 作业必须
先取得全局 `local` 锁，不能各自启动一套构建或 Gate D。

## 2. 最小任务模型

任务应是一个可独立验收的垂直切片。功能任务默认由同一个 owner 完成实现、定向
测试、必要文档和 handoff；不要把同一条指令的 decode、测试和 QEMU 语义拆给多个
Agent。

每个任务至少声明：

- 唯一 ID、owner、`base_sha`、branch 和 worktree；
- `depends_on`、允许修改的 `writes` 和只读 `reads`；
- 只需阅读的 `context_docs`，避免遍历全部历史 handoff；
- L0–L4 中实际需要的验证命令和 acceptance；
- handoff 和 evidence 路径。

简化状态机：

```text
proposed -> ready -> active -> review -> integrating -> done
active/review/integrating -> blocked -> ready
proposed/ready/blocked -> cancelled
```

规则：

1. 默认只有 `done` 的依赖算满足；取消依赖时由集成者显式修订 DAG。
2. 一个 Agent 同时只持有一个写任务；同一路径的 `writes` 在任务 `done/cancelled`
   前一直保留，避免待合并分支与新任务并发修改。
3. 子 Agent 不直接编辑任务 JSON、`TASKS.md`、`PROJECT_STATUS.md` 或 `ROADMAP.md`；
   它用短报告、handoff 和 evidence 向集成者提交结果。
4. A0 由集成者静态派单，不实现 TTL、heartbeat、lease/event 数据库。若出现三个
   以上写 Agent、频繁抢占或遗留任务，再实现 `scripts/taskctl.py` 的
   `claim/release/status/reconcile`；使用 JSON、`flock` 和原子替换即可，不需要服务。

Agent 短报告统一包含：

```text
task=<id> state=<active|review|blocked|done>
base=<sha> head=<sha> branch=<name> worktree=<path>
sent_at=<ISO8601+08:00> received_at=<ISO8601+08:00> reported_at=<ISO8601+08:00>
files=<summary> evidence=<path> risks=<known limits> next=<next action>
```

所有发给或收到 subagent 的消息（派单、进度、follow-up、最终报告）必须携带
Asia/Shanghai ISO-8601 时间戳；实际耗时只按 `reported_at - sent_at` 计算，
不能用模型回合时长、工具 `wall_time` 或静态意图字段替代。

## 2.1 Agent 类型与模型路由

五个稳定子域是长期导航，不等于五个常驻 Agent。实际派单按任务生命周期选择
模型，并在任务记录中保存模型、推理档位和边界。当前模型路由如下：

| Agent 类型 | 模型 | 适合工作 | 边界与成本控制 |
| --- | --- | --- | --- |
| 复杂任务 Agent | `gpt-5.6-terra[xhigh]` | 跨域架构、复杂依赖、长期方案和高难度问题拆解 | 只接有明确边界的复杂任务；不替代最终 review 或自行合并 |
| 评审 Agent | `gpt-5.6-sol[high]` | 方向性架构/协议审查、阻断风险和验收大纲 | 限制可见范围（task JSON + 指定文档/差分）；只给大方向，不给逐行实现方案 |
| 慢速实现/监控 Agent | **派单时省略 `model`**，使用平台默认 `deepseek-v4-flash[max]` | 常规实现、远程工程/环境任务、耗时验证、后台监控 | 遵守资源队列；不得自行扩大写集或修改集成热点 |
| 快速实现 Agent | `deepseek-v4-flash[max]`（**默认通道**） | 小/中型垂直实现、快速 L0/L1、在线资料调研 | 与省略 `model` 的默认通道一致；显式写出亦可 |
| 主/集成 Agent | 当前会话模型 | 派单、DAG、资源队列、串行合并、证据复跑和里程碑 | 不把评审结论直接当实现；不绕过任务 JSON 和 merge gate |

### 路由规则

1. **省略模型不是未知模型**：子代理调用不指定 `model` 时，明确等价于
   `deepseek-v4-flash[max]`（当前默认派单通道）。Terra、Sol 必须显式写出
   模型与 reasoning effort；DeepSeek 可省略（默认）或显式写出。
   **dsh 平台适配（ADR-20260828-004）**：dsh 的 subagent 工具无
   provider/model 参数，派单一律省略 `model`（即 dsh 默认通道）；不再通过
   subagent 指定 Terra/Sol，需要高推理档的复杂拆解/方向评审由集成者当前会话
   亲自承担，或仅在实际可用时经 workflow 编排层 `agent(prompt, {provider,
   model})` 指定（不设为默认路径）。任务 JSON 的 `model` 保留为意图记录，
   实际执行通道记录 `dsh-default`。
2. Terra 先做复杂任务的边界和依赖拆解；Sol 只审指定范围并给方向性阻断意见；
   Luna 按批准边界实现、监控和跑耗时验证；集成者负责最终 acceptance。
3. Sol 的输入默认只包含 task JSON、指定设计文档和目标 diff，不提供完整历史上下文；
   输出不包含逐行补丁或完整实现方案。需要更深综合时升级到 Terra。
4. Luna 长跑遇到架构或协议不确定性时暂停，转交 Sol/ Terra；Luna 不得自行换模型。
5. DeepSeek 为当前默认派单通道（省略 `model` 即 `deepseek-v4-flash[max]`）。
   若未来暂停或更换默认通道，由集成者在本文件与任务台账同步修订并记录。
6. 每次派单必须限制输入文档、问题范围、最大验证层级和资源预算；默认只读评审
   不产生构建/测试产物，写任务必须使用独立 sibling worktree。
7. 模型名称、reasoning effort、任务 SHA、owner 结论和 evidence 链必须写入任务
   JSON/handoff/evidence；不能只在聊天中声称使用了某模型。
8. 默认审核采用一次性 `one-pass-blocking`：只报告必须阻断的边界风险，不做重复
   深审或轮询。复杂任务完成 Terra 边界审查并无启动阻断后，允许 owner 先做写集
   受限实现；Sol 方向审查可并行进行，但协议联调、重型验证、合并和归档仍须等
   必需审核结论。只有写集、冻结契约或验收证据发生实质变化时才重新审核。
9. 每个实现/监控 subagent 的初始总执行预算默认为 **10–30 分钟**，普通任务的
   `resource.timeout_s` 不超过 1800 秒。跨通道/复杂协议任务可在 task JSON 中声明
   `budget_policy`，由集成者依据 owner 的自然里程碑报告按固定增量延长，但最大不
   超过 3600 秒；报告至少包含已改文件、已跑验证、当前阻断、实际耗时和剩余工作。
   到达当前预算时不自动中断、不把等待 timeout 当失败；若报告证明仍有稳定进展，
   集成者再延长，否则提交当前 checkpoint、handoff/evidence 和明确的
   `review`/`blocked` 状态。重型 QEMU、Quartus、Linux 和 Gate 仍进入集成者资源
   队列，不由单个 subagent 无限运行。每次发给或收到 subagent 的 progress 消息
   必须带 Asia/Shanghai ISO-8601 时间戳（`sent_at`、`received_at`、`reported_at`）；
   实际耗时只按同一时钟源的 `reported_at - dispatch_sent_at` 计算，不能用模型
   回合时长、工具 `wall_time` 或静态意图字段替代。
10. **本地重型 Verilator 编译/仿真必须先取得跨项目 `local` 独占锁**：
    `/home/chiro/projects/.resource-locks/resource-lock run local ... -- <command>`。
    持锁后不再强制 `<16 GiB`、`MemoryMax=16G` 或本机 50% 固定上限；集成者依据
    当前 `MemAvailable`、已知峰值和桌面负载选择 `--min-local-available-mib`、并行度
    及可选 cgroup，并把实际策略、峰值 RSS 和命令写入 handoff/evidence。未取得锁
    不得裸跑；同一时刻仍只有一个本机 heavy 作业，不得终止非任务进程来腾挪资源。

当前 T-20260826-002 的第一版草稿由历史默认通道产生，尚未达到 acceptance。
正式实现时采用“Terra 复杂边界拆解（必要时）→ 受限默认通道
（`deepseek-v4-flash[max]`）实现与 Sol 一次性审核并行 → 协议门后继续默认通道
→ 集成者复测”。

## 2.2 Subagent 派单与等待/轮询协议

### 2.2.0 dsh harness 工具映射（ADR-20260828-004）

dsh 平台下，本规范中的平台相关概念映射如下；其余流程（任务 JSON、worktree、
写集、合并队列、文档治理）不变。

| 本规范概念 | codex 时代机制 | dsh 工具 | 备注 |
| --- | --- | --- | --- |
| 派单（fresh context） | `spawn_agent`（`fork_turns=none`） | `subagent` | 消息必须自带完整任务包 |
| 继承上下文的派单 | 显式 `fork_turns=N` | `subagent_fork` | 用于续查/复现/深入诊断 |
| follow-up / budget_note | 发消息 | `send_message` | 启动新回合，不打断运行中工作 |
| 中断 | — | `interrupt_agent` | 可中断深层后代；`max_is_hard_stop` 时使用 |
| 状态查询 | `list_agents` | `list_agents` | `scope=descendants` 查看全树；完成时 harness 自动通知 |
| 重型命令排队 | 集成者手工 | bash `run_in_background` + `job_output`/`job_kill` | **agent id 与 job id 是两套体系**，`job_output` 不识别 subagent id |
| 上下文管理 | 自动压缩 | `compress` | 见 §11 |

派单节奏：**dsh 工具模式是默认执行模式，禁止使用 bash `sleep` 轮询来调度或
等待 subagent**。subagent 落定时 harness 自动通知集成者；收到通知后核对
（`list_agents` + worktree `status/log` + handoff/evidence 产物）合并到
收件核对一步（见 §2.2.2 修订）。`sleep` 只允许用于等待外部世界（远端宿主、
物理板、人工操作），不得用于“轮询子代理是否完成”。

### 2.2.1 派单协议（Dispatch）

1. 集成者先登记任务 JSON（`phase=ready`）并提交；再从登记的 `base_sha` 创建
   唯一 topic worktree 与分支：

   ```sh
   git worktree add -b "feature/${TASK_ID}-${SLUG}" "../lcvex-wt-${TASK_ID}" "${BASE_SHA}"
   ```

2. 派发前更新任务 JSON：`phase=active`，并记录
   `dispatch.sent_at`（Asia/Shanghai ISO-8601）、`agent_name`、`model`（省略时
   记录为 `deepseek-v4-flash[max]`）、`reasoning_effort`、`worktree`；提交
   `tasks: dispatch <id>`。
3. `spawn_agent` / dsh `subagent` 调用规则：
   - `task_name` 必须唯一且语义化（小写字母/数字/下划线）；
   - `fork_turns=none`（消息自带完整任务包，不继承会话上下文）；确需历史上下文
     时显式指定正整数值（dsh 等价为 `subagent_fork`）；
   - `model` 省略（默认 `deepseek-v4-flash`），`reasoning_effort=max` 或按任务
     声明；Terra/Sol 必须显式指定（dsh 下不可指定，见 §2.1 路由规则 1 的
     dsh 适配）；
   - 消息必须包含：任务 ID/目标、worktree 与分支/base SHA、`writes`/`reads`
     边界、远程环境（如适用）、验证与 acceptance、报告格式、时间戳要求和
     禁止事项。
4. 所有发给 subagent 的消息必须带 `sent_at`；subagent 回复必须带
   `received_at` 与 `reported_at`。

### 2.2.2 等待/轮询协议（Polling）

dsh 平台修订（ADR-20260828-004）：**事件驱动取代定时轮询**。

1. subagent 完成时 harness 自动通知集成者；集成者不主动轮询等待。原轮询
   检查（`list_agents` 状态、worktree `status --short --branch`、`log
   --oneline`、handoff/evidence 产物）合并到**收到完成通知后的收件核对**
   一步执行。
2. **在 dsh 默认工具模式下，禁止使用 bash `sleep` 循环或 `while kill -0 ...`
   等方式等待/调度 subagent**；等待 subagent 只依赖 harness 自动完成通知。
   `sleep` 仅允许用于等待外部世界（远端宿主、物理板、人工操作），且必须固定
   `sleep 300` 一次整段完成，带时间戳：

   ```sh
   date '+poll sent_at=%Y-%m-%dT%H:%M:%S%z'; sleep 300; date '+poll done_at=%Y-%m-%dT%H:%M:%S%z'
   ```

3. 长任务（Linux/Quartus/Gate）用 bash 后台 job 执行
   （`run_in_background` + `job_output`），不占用 subagent 预算。
4. 预算与延长：按任务 JSON 的 `budget_policy` 判断。默认 `initial=30m`、
   自然检查点 `+15m`、`max=60m`（任务另有声明时以任务为准）。到达 `max`
   **不强制结束 owner 工作，也不自动中断**：集成者只发送一条带时间戳的
   `budget_note` 提醒（见 2.2.6），owner 继续工作，任务转为后台长跑模式；
   若 owner 在提醒后仍无产出/无进展，再要求提交 checkpoint/handoff/evidence
   并置 `review`/`blocked`。
5. 收到 FINAL_ANSWER：先核对 `result`、`head`、handoff/evidence 路径、
   时间戳与写集边界，再决定验收、合并或延长；不凭最终报告文字直接归档。
6. 中断处理：若轮询被用户中断，先清理残留 sleep 进程（`ps` 查明确 PID，
   不误杀系统进程），记录中断时间；subagent 仍 `running` 时继续按协议等待，
   不重复派发新 owner。

### 2.2.3 时间戳判断口径

- 所有 progress/final 报告统一字段：

  ```text
  task=<id> state=<active|review|blocked> base=<sha> head=<sha> branch=<name>
  worktree=<path> sent_at=<ISO8601+08:00> received_at=<ISO8601+08:00>
  reported_at=<ISO8601+08:00> files=<summary> tests=<已跑验证>
  blockers=<阻断> next=<下一步>
  ```

- 时间是否符合要求的依据：`reported_at - sent_at ≤` 当前可用预算；progress
  消息必须随实际工作推进出现，不能只靠轮询间隔推断；缺失时间戳或跨时区
  不一致时按无效报告处理并要求补充。
- dsh 补充（ADR-20260828-004）：最终报告为**结构化元数据块**（可解析的
  `key=value`/JSON），同一元数据**双写**到 handoff 头部与 evidence JSON
  （`reported_at` 等）；harness 转发的**中途通知不作为有效报告**，验收以
  最终消息 + handoff/evidence 为准。
- **两类时间字段（EXT-01-002 / AUD-09）**：
  - 事件发生时间：派发/接收/报告/运行/评审/合并等真实发生时点，字段如
    `dispatch.sent_at`、`sent_at`、`received_at`、`reported_at`、`run_at`、
    `runs[*].started_at/finished_at`、`integrator_review.received_at`、`merged_at`。
  - 台账回填时间：记录被写入/更新到台账的时点，字段如 `created_at`、
    `updated_at`、`recorded_at`、`archived_at`；仅用于说明记录何时落账，
    不用于耗时计算。
  - 强制单调性：`review >= dispatch`、`run >= dispatch`、`sent <= received <= reported`、
    `started <= finished`；任何事件时间不得晚于当前时间或承载该字段的 Git 提交时间。
  - 提交前用 `python3 scripts/check_task_timestamps.py --scope live --exit-code`
    检查；历史不一致用 correction record 保留旧值，不改写已冻结 handoff/evidence。

### 2.2.4 错误处理

- `spawn_agent` 参数解析失败（如缺 `task_name`）时重发，不重复创建 worktree；
- 远程 SSH/工具命令失败必须记录退出码与日志，不伪造结果；
- 任务被打断后恢复：先 `list_agents` + worktree status，原 agent 仍在则继续
  等待/沟通，原 agent 已终止才重新派发。

### 2.2.5 与 goal 的配合

项目级长期 goal 激活期间，轮询与派单都记录时间戳；goal `paused` 时前台处理
用户指令但不丢弃任务状态；恢复时按原任务继续，不重复登记或派发。

### 2.2.6 后台长跑与并行派单

1. 达到 `max`（或集成者决定不再阻塞等待）后，任务继续在后台运行；集成者
   不把轮询作为唯一工作，可启动新的并行任务。
2. 并行条件（缺一不可）：
   - 写集不重叠：本地 `writes` 与远端写入目录均不冲突；
   - 无共享热点：不同时修改 QEMU fork、不使用同一 worktree、socket、
     checkpoint 链或同一重型资源槽；
   - 本机 heavy 作业已取得全局 `local` 锁，并按资源快照使用已记录的动态预算；
   - 不修改对方的 worktree、任务 JSON 或里程碑文档。
3. **dsh 默认模式下，后台 subagent 不再用 `sleep` 定期轮询**：完成由 harness
   自动通知；bash 后台重型 job（Linux/Quartus/Gate 等）用
   `run_in_background` + `job_output` 读取，也不使用 `sleep` 循环等待。
   并行任务派发同样走 2.2.1（登记 active + dispatch 字段 + 提交后 spawn）；
   同一集成会话可同时持有多个 `running` 的 subagent。
4. `budget_note` 提醒格式：

   ```text
   budget_note task=<id> elapsed_min=<N> max_min=<N> sent_at=<ISO8601+08:00>
   note=已达到 max；不中断，请继续并注意时间；稳定后提交 checkpoint
   ```

5. 只有当任务 JSON 显式声明 `max_is_hard_stop: true` 时，`max` 才是硬停止；
   默认 `max_is_hard_stop: false`，达到上限仅提醒并转后台。
6. dsh 修订（ADR-20260828-004）：`max_is_hard_stop: true` 时用
   `interrupt_agent` 实现硬停（取消当前回合；已排队消息保留，可由
   `send_message` 澄清）；默认 `false` 时以报告 `reported_at - sent_at`
   核算实际耗时，超预算且无产出才发 `budget_note`。

### 2.2.7 三线并行调度原则（A/B/C）

主/集成 Agent 在调度 LCVEX 三条并行线（A 开源综合/PPA 代理、B V82 非 SVE
profile、C 多核演进）时，**默认按“尽可能并行”执行**，不是按线一条条串行排队。

1. 每个波次开始时，先扫描 A/B/C 中所有满足依赖且资源/写集允许的 ready 任务，
   一次性并行派发；只有真实依赖或计划中的汇合点才阻止派发。
2. 必须串行/阻塞的情形仅限：
   - **真实依赖**：例如 A1 依赖 A0、B1 依赖 B0、B2/B3 依赖 B1、C1 依赖 C0/D0、
     C2 依赖 C1 与 B1 的 memory/commit 契约。
   - **计划汇合点/门**：G0/G1/I0、波次合入口、共享 `core/pkg/commit/memory`
     热点窗口、QEMU 全局串行队列、detached Gate D、F/G-MC candidate。
   - **写集或资源冲突**：同一 worktree、同一共享热点、QEMU/socket/checkpoint、
     同一重型资源槽，或未取得相应 `local`/`gamepc` 共享锁。
3. 某一条线遇到 blocker 时，只要该 blocker 不是其它线的共享依赖，就继续调度
   其它线的独立任务，并保留该线的 blocked 记录；不要因为单线暂停而全局停摆。
4. 并行仍须满足通用并行条件：唯一 topic worktree、写集不重叠、不修改他人
   worktree/任务 JSON/里程碑、不共享可写 QEMU/checkpoint。
5. 最终汇入按计划中的 G2/G3/G4/G5 或 F/G-MC 分列车验收，不能把并行开发等同于
   跳过合并门或跨 SHA 拼接绿色证据。

### 2.2.8 时序收敛批次流水线（Timing Batch）

时序闭合不再默认使用“取 top-1 → 改一处 RTL → 完整仿真 → 完整 Quartus → 再取
top-1”的单线程循环。只要最新 post-fit/STA 提供至少两个可分离的组合锥，默认按
以下批次流水执行；若报告只有一个主导共享锥，则退回单 lane，不为凑数量拆任务。

```text
STA(N-1) -> top-N 聚类 -> lane A/B/C 并行实现 -> batch(N) candidate
                                                    |
                                                    v
                                      合并 SHA 一次 L0-L2
                                                    |
                                                    v
                                      单路 Quartus physical(N)
                                                    |
                         +--------------------------+-----------------+
                         |                                            |
                  下一批分析/原型                              新 top-N 定稿
                  （speculative）                         -> 选择/丢弃/rebase
```

批次步骤和门如下：

1. **冻结测量输入**：physical task 必须记录 source SHA、QSF/SDC/IP manifest、器件/
   seed、每个失败时钟的 top-N（默认至少 20 条）、TNS、endpoint 数、logic level、
   startpoint/endpoint 和共享节点。先按共享组合锥、端点族、模块和根因聚类；同一锥的
   十条路径只算一个候选 lane，不能当十个独立优化机会。
2. **选 2–3 个 cone lane**：优先选择互不依赖、覆盖 endpoint/TNS 较多且有真实
   寄存边界的路径族。batch 父任务登记冻结 base、`member_tasks`、合入顺序、联合测试
   矩阵和 physical 门；每个 lane 登记 `cone_id`、精确 `write_regions`、预计 latency/
   reset/kill/commit 变化、测试增量和单提交回退点。
3. **并行实现，候选前不跑重型仿真**：lane 在各自 sibling worktree 编写 RTL、
   定向测试和文档，只运行 `git diff --check`、生成器 dry-run 或明确登记的轻量静态
   检查。lane 的 `review` 表示“可进入 batch”，不表示功能已验收或任务 `done`。
4. **先汇入临时 candidate**：集成者在独立 `batch/<id>` 分支和 worktree 按登记
   顺序合入 2–3 个 lane；这就是“仿真前合入”的唯一含义。不得直接合入长期
   `feature/*`，更不得进入 `main`。公共 typedef/端口/enum、latency 表和联合测试
   入口由 integration lane 在此阶段串行修改。
5. **合并 SHA 只跑一次联合验证**：在 batch candidate 上运行各 lane acceptance
   声明的 L0–L2 集合并集，所有受影响 L2 都必须通过，不能只抽“代表性”子集；
   重型 Verilator 仍单路并先取得 `local` 锁，内存/CPU/cgroup/并行度按当时资源
   快照决定并记录。失败时保留合并现场，按独立 lane commit 做 revert/bisect；
   不能修改参考结果、跳过比较或把不同 SHA 的绿项拼成 batch 证据。
6. **功能绿后进入长期集成和一次 physical**：联合 L0–L2 全绿后，长期
   `feature/*` 必须以 `--ff-only` 晋级到精确 candidate SHA，再从该 SHA 创建独立
   physical worktree/probe。若长期分支已前进而无法 fast-forward，集成者必须在新
   HEAD 重建 batch candidate，并对新 SHA 重新运行联合 L0–L2；不能用 tree 看似相同
   或 cherry-pick 后的新 SHA 继承旧证据。随后串行 synthesis→fitter→signoff，报告
   逐个回答旧 cone 是否离开 top-N、出现了什么新 top，以及各 lane 的面积/寄存器/
   latency 代价。
7. **流水重叠**：本地联合仿真可与已冻结的远端 physical 重叠；远端 physical(N)
   运行时，可对 N−1 报告中尚未选择的路径做只读分析和原型。此类任务必须标记
   `speculative_base`，不得进入 batch(N+1)。收到 physical(N) 后重新聚类；路径已
   消失、根因改变或依赖新共享节点的原型直接丢弃或 rebase 后重审。

同文件并行是受限例外，不是默认放宽写集：batch 父任务先持有整个文件写权，成员
lane 只持有 `file::module/generate/function/state` 形式的 `write_regions`。区域不得
重叠，也不得触碰公共声明、接口、全文件格式化或大范围重命名；任何越界 diff 都
退回。若两个改动会改变同一状态机、同一寄存器边界或同一 endpoint cone，它们必须
合成一个 lane 串行完成。

每批最多三个 lane，并设置以下停止条件：没有最新匹配 SHA 的 timing 报告；无法
证明 write region 独立；预计累计 latency/寄存器面积没有上限；联合 L0–L2 任一未通过；
或 physical manifest 与 batch SHA 不符。setup/hold/recovery/removal/min-pulse、DDR
和 Metastability 未全部通过时，assembler/SOF 门保持关闭。

## 3. Git worktree

### 3.1 目录位置

A2 尚未统一所有 QEMU 路径前，LCVEX worktree 使用项目父目录下的直接 sibling：

```text
/home/chiro/projects/mycpu/lcvex/                    # integration root
/home/chiro/projects/mycpu/lcvex-wt-T-20260826-001/ # 一个写任务
/home/chiro/projects/mycpu/qemu/                     # 当前共享、只读的 QEMU 基线
```

直接 sibling 可让现有 `$REPO/../qemu` 仍解析到真实 fork。不要把 worktree 放进
LCVEX tracked tree。若设置 `$LCVEX_WORKTREE_ROOT`，A0/A1 必须 canonicalize 后确认
它就是 `/home/chiro/projects/mycpu`；完成 QEMU 路径参数化后才允许更深布局。

纯只读审阅 Agent 可以共享集成者指定的 SHA 或 dirty diff 快照，不必额外创建
worktree；它不得运行生成器、构建、测试或任何写文件命令。一旦需要修改或产生
验证产物，就进入独立 worktree。

### 3.2 创建、集成和清理

集成者先记录源码 `base_sha`，登记并提交任务记录，再明确从这个已记录的源码 SHA
创建 topic worktree；任务注册提交本身不算 Agent 改动：

```sh
test -z "$(git status --porcelain)" || exit 1
BASE_SHA="$(git rev-parse HEAD)"
TASK_ID="T-20260826-001"
TASK_SLUG="short-slug"
# 集成者把上面的 base_sha、预定 branch/worktree 写入任务记录并提交。
git worktree add -b "feature/${TASK_ID}-${TASK_SLUG}" \
  "../lcvex-wt-${TASK_ID}" "$BASE_SHA"
```

完成顺序：Agent 提交小而单一的改动、handoff 和 evidence → 集成者检查写集和
证据 → owner 在自己的 worktree 按需 rebase，或集成者 cherry-pick/显式 merge →
在合并 SHA 验证 → 更新任务状态 → 保存失败现场/长期产物 → 删除 worktree。

不要在别人的 worktree 执行 reset/rebase/清理。失败现场确认前不得删除 worktree。
topic 分支默认只保存在本机共享 Git 对象库；长任务、跨主机协作或需要远端备份时，
由集成者批准推送。未推送分支本身不是长期证据，commit SHA 和必要 artifact 仍要记录。

### 3.3 QEMU 边界

A0/A1 试点不并行修改 QEMU fork。当前 `build-qemu.sh`、`toolcheck.sh` 和 patch 重放
脚本尚不能完整识别 `.git` 为文件的 QEMU linked worktree，部分 runner 也仍硬编码
QEMU/plugin 路径。因此：

- 并行任务只读复用已校验的 QEMU binary/header；
- QEMU 构建、patch 重放和会写外部 fork 的 CI 入口由集成者串行执行；
- 需要修改 QEMU 时先作为单独串行任务完成，并把结果导出到固定 release 上可重放的
  `qemu/patches/`；
- 后续若要并行 QEMU 任务，再统一 `QEMU_ROOT/QEMU_BUILD_ROOT/QEMU_BIN/
  QEMU_PLUGIN`，并用 `git -C <dir> rev-parse` 识别普通 clone 和 linked worktree。

## 4. 构建、运行和资源

Git worktree 会隔离不同 worktree 内的仓库相对源码和未跟踪产物，包括
`obj_dir*`、仓库内 `build/` 和本 worktree 的 plugin。它不会隔离：

- 同一 worktree 内同时写同一个固定目录的两个作业；
- 外部 QEMU fork/build、显式共享 root 或可写 cache；
- 全机 CPU、内存、磁盘和 Unix socket 命名空间。

因此 A0 不必先参数化全仓固定路径。当前规则是：

1. 一个写任务一个 worktree；每个 worktree 同时只跑一个会写固定目录的作业。
2. 只使用入口已经支持的 `SIM_BUILD/SOCK/DUMP/COORD_LOG/QEMU_LOG/QEMU_BIN`
   override；不要设置未接线变量后声称隔离成功。
3. 所有重型作业向集成者申请时隙，并通过
   `/home/chiro/projects/.resource-locks/resource-lock` 原子取得资源。本机 heavy
   使用 `local`，远端 Quartus 使用 `gamepc`，同时需要时使用 `local,gamepc`；
   本机并行度与可选 cgroup 依据取得锁后的资源快照动态决定，Linux 长跑和 Gate D
   仍默认单路。
4. `scripts/test_planner.sh` 只是建议器，没有原子 reservation；跨项目最终互斥以
   `resource-lock` 为准。返回 75 时等待，不能降级为裸跑；未来只有需要同机运行
   多个受限 heavy 作业时才增加容量令牌，不建设通用调度服务。
5. 普通日志/小 trace 放各 worktree 的 `build/agents/<task-id>/`，大 RAM、checkpoint
   和 trace 放 `build/tmp/<task-id>/` 或外部 artifact root。不要把大文件或长期隐式
   输入放系统 `/tmp`；短小、自动清理的系统 tempfile 可以使用。历史只读
   `/tmp/Image-t80000` 是兼容例外，新任务显式传 `IMAGE`。
6. 锁步 socket 路径必须小于 108 字节；长运行可显式使用仓库外的短 `RUN_ROOT`。

只有在需要同一 worktree 多作业并发、统一产物收集或更深 worktree 布局时，再完成
路径接口：`BUILD_ROOT` 为 task 产物根，`RUN_ROOT` 为单次运行根，
`SIM_BUILD=$RUN_ROOT/sim`，QEMU 路径使用绝对值。未设置时继续兼容现有单 Agent
默认。先参数化真实共享路径和最常用入口，不做一次性全仓改造。

## 5. 验证和合并队列

| 层 | 内容 | 责任人 |
| --- | --- | --- |
| L0 | microbench：Verilator-only 裸机 C 快速行为测试 | Agent |
| L1 | 受影响的 SV/Cocotb 单元测试、SVA/lint | Agent |
| L2 | 受影响的 `hard_*` 定向 QEMU 锁步差分 | Agent；集成者在合并 SHA 复跑 |
| L3 | 完整 Gate D 和覆盖记账 | 集成者在冻结 candidate 的 detached gate worktree |
| L4 | 多 seed、随机延迟、patch 重放、长 Linux/nightly | 集成者或 CI |

合并队列：

1. 检查依赖、写集、base/head SHA、handoff 和 evidence；
2. 普通任务按队列逐个合入；时序 batch 先把 2–3 个已审 lane 合入独立 candidate，
   在合并 SHA 运行验证并按 §2.2.8 处理失败。两类流程都不能让未验证提交进入长期
   `feature/*` 或跨 SHA 复用绿色结论；
3. 普通任务通过后即可 `done`；只有 acceptance 明确要求时才等待 L3/L4；
4. 每 2–4 个低耦合任务形成一个 integration wave。进入 `main` 或阶段门前，从冻结
   SHA 创建 detached gate worktree 跑 L3；L4 留给 nightly/长跑；
5. 后续 Gate/nightly 发现已归档任务的回归时，新建 regression task，不改写历史
   handoff/evidence。

任何失败都保留指令编码、反汇编、执行前状态、RTL/QEMU 状态、最近提交和重现
命令。不得关闭断言、跳过差分项或修改参考结果来提高吞吐。

## 6. Agent 文档治理

| 文档 | 内容 | 写入者 |
| --- | --- | --- |
| `docs/tasks/active|archive/T-*.json` | 下一步工作、owner、依赖、写集、验收和持久状态 | 集成者 |
| `docs/tasks/TASKS.md` | 带日期的人读快照 | 集成者；未来可由薄 CLI 生成 |
| `docs/tasks/evidence/<id>.json` | 精确命令、source SHA、版本、seed、退出码、资源和 artifact hash | owner 创建；集成者补合并 SHA 复跑后定稿 |
| `docs/handoffs/<id>-<slug>.md` | 人读实现摘要、边界、结论、风险和 evidence 链接 | owner；合入后不改写 |
| `docs/decisions/ADR-*.md` | 跨任务、长期有效的架构/流程决定 | 决策 owner/集成者 |
| `PROJECT_STATUS.md`、`ROADMAP.md` | 当前里程碑快照 | 集成者按批次更新 |

同一事实不双写：精确测试命令和 artifact manifest 以 evidence JSON 为准，handoff
只引用 run/artifact ID 并解释结论。完整 log、trace、波形和 RAM 不进 Git。进入
`review` 时 evidence 的 `merge_sha` 可以为空；集成者完成合并提交复跑后补齐，任务
`done` 后冻结。纠错时新建 regression task/修订 handoff，不覆盖历史。

## 7. 项目结构优化顺序

当前并行瓶颈主要是热点所有权、共享 QEMU/机器资源和重复测试清单，不是顶层目录
本身。按以下顺序优化：

1. **先运行 worktree + 静态派单试点**，不机械拆 `lcvex_core.sv`、
   `lcvex_decode.sv` 或 `lcvex_pkg.sv`。
2. **收敛重复测试清单**：把 runner 中重复的 `hard_*`、`MAX_INSNS`、配置和 tag
   逐步移到按 `isa/mmu/cache/mmio/system` 分类的 registry。
3. **按需拆 Make include**：路径和 registry 稳定后，把机械目标移到
   `mk/sv.mk`、`mk/cocotb.mk`、`mk/difftest.mk`、`mk/gates.mk`；不更换构建系统。
4. **最后才拆大型源码**：只有系统寄存器、异常/提交控制、编码器或 checkpoint
   已有稳定接口和独立测试时才拆；结构重排与功能修改分开提交。

目录 owner 是导航信息，实际修改权仍由任务 `writes` 决定。目标不是“一 Agent 一
永久目录”，而是每个任务在临时 worktree 中交付完整垂直切片。

## 8. 落地顺序

### A0：现在

- 合入本规范、任务/evidence/handoff/ADR 模板；
- 选择两个写集不重叠、且不修改 QEMU fork 的小任务，在两个 direct sibling
  worktree 试点；
- 集成者静态派单，重型测试人工排队；记录实际冲突、等待时间和资源峰值。

### A1：只解决试点暴露的问题

- 以共享 `resource-lock` 代替仓内私有 `test-slot`，根据实际排队数据再决定是否增加容量令牌；
- 参数化试点实际碰到的共享路径，并做两个 worktree 的碰撞回归；
- 只有手工任务状态成为瓶颈时，才实现薄 `taskctl.py`；不引入 daemon、数据库或
  GitHub Issues 作为本地事实源。

### A2：度量证明有收益后

- 建测试 registry 和 path→test 映射，按 integration wave 自动选 L0–L2；
- 按需拆 Make include、统一 QEMU path、支持 QEMU linked worktree；
- 根据实际 wall/RSS/磁盘数据再决定缓存、更复杂的资源令牌或跨主机协调服务。

## 9. P7 / Catapult 双轨应用

P7阶段采用两个长命集成分支：`feature/p7-fp-neon`与
`feature/fpga-catapult-a10`。它们共享批准后的协议/规划基线，但每个具体写任务
仍须使用唯一topic branch和direct sibling worktree；长命分支只由集成者串行合入。

- P7-0/P7-1可与B0-Platform/B1-AXI4/B2-EMIF并行，后者不得写QEMU fork、
  `rtl/lcvex_core.sv`或`rtl/lcvex_pkg.sv`；
- P7-2持有vector memory和`core/pkg/soc_tb`热点时，B3-L2-WB只允许模块级写集；
- B4-L1-Coherence须等待P7-2完成后再取得核心访存/maintenance写集；
- QEMU fork 修改和构建仍走全局串行门；Verilator/QEMU 锁步、Gate D 与 Linux
  长跑取得共享 `local` 锁并串行，Quartus full compile 取得共享 `gamepc` 锁并串行。
  输入/产物隔离且分别持锁时，本地槽与远端槽可以重叠；
- `feature/p7-final`仅用于最终冻结候选，不作为两个Agent共享开发分支。

任务DAG、标准AXI4边界和阶段门见
[P7_FPGA_PARALLEL_PLAN.md](P7_FPGA_PARALLEL_PLAN.md)。

## 10. 禁止事项

- 两个写 Agent 共享一个 worktree、分支、socket、可写 QEMU build 或 checkpoint 链；
- 子 Agent 修改任务索引、里程碑热点或别人的 worktree；
- 未取得 `local` 锁就启动本机 heavy 作业，或在可变 Agent worktree 后台跑 Gate D；
- 为追求并行机械拆耦合 RTL，或关闭断言、减少差分比较；
- 没有 task ID、commit、验证证据和已知限制就声称任务完成；
- 使用 `wait_agent` 控制等待/轮询，或把 300 秒轮询拆成多次短 sleep；
- **dsh 默认模式：使用 bash `sleep` 循环或 `while kill -0 ...` 轮询 subagent
  是否完成**（只能等 harness 完成通知；`sleep` 仅限外部世界整段等待）；
- 任何 subagent 消息缺失 `sent_at`/`received_at`/`reported_at` 仍被当作有效报告；
- 在 subagent 仍 `running` 时重复派发同一任务或重建同一 worktree；
- 到达 `max` 就强制结束/中断 subagent（除非任务 JSON 显式声明
  `max_is_hard_stop: true`；默认只提醒并转后台长跑）；
- dsh 平台：用 `job_output` 查询 subagent id、或用 `list_agents` 查询 bash
  后台 job id（agent/job 两套 id 体系）；
- dsh 平台：compress 压缩含未完成工具配对或进入最近 2 回合的区间（工具会
  拒绝，属正常保护）；压缩摘要写成占位符（必须写完整技术事实）。

## 11. dsh harness 上下文管理（DCP 主动压缩）

dsh 平台下主/集成 Agent 负责主动压缩上下文（ADR-20260828-004）：

- **节奏**：每个逻辑节点收尾后（约每 15–25 次工具调用）压缩一次**早于最近
  2 个回合**的已关闭区间；不让上下文膨胀到历史细节挤占当前工作。
- **边界**：只选工具调用对完整配对、已关闭（无进行中工作）的区间；工具拒绝
  进入最后 2 回合或未配对区间的请求。
- **摘要质量**：按 handoff 标准写摘要——包括 SHA、分支、worktree、关键事实、
  失败点、结论；用户指令与受保护工具输出由工具自动原样保留，不省略；
  **禁止占位符摘要**（信息会丢失，仅能靠仓库/日志兜底恢复）。
- 压缩产生的 checkpoint 是新的上下文边界引用（`<dcp-message-id>bN</dcp-message-id>`），
  后续引用其内容时以摘要为准。
