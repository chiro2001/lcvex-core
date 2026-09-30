# 01 治理与流程：任务 / DAG / Subagent / 写集 / 证据链 / ADR / 暂停恢复 / cgroup

> 状态：**流程已落地并在多 Agent 试点中运行；不是常驻服务或集中自动化调度。**
> 权威文档：`docs/MULTI_AGENT_WORKFLOW.md`、`docs/GIT_WORKFLOW.md`、
> `docs/decisions/`、`docs/tasks/active/*.json`。

## 1. 现状

- 当前不引入独立任务服务/daemon。主/集成 Agent 就是任务管理者；只有手工任务
  状态成为瓶颈后，才考虑 `scripts/taskctl.py` 薄 CLI。
- 每个写任务在 `docs/tasks/active/T-*.json` 中登记：唯一 ID、owner、base_sha、
  branch、worktree、`writes`/`reads`、验证套餐、resource/budget、acceptance 和
  handoff/evidence 路径。任务状态机为：
  `proposed -> ready -> active -> review -> integrating -> done`，
  并有 `blocked`、`cancelled`。
- 当前活跃/近期任务可以按 A/B/C/D 线分类：
  - A 线（开源综合/PPA 代理）：T-074、T-080、T-081、T-083、T-087 已完成。
  - B 线（V82 非 SVE profile / 单核 ISA 闭合）：T-075、T-078、T-082、T-084、
    T-085、T-088、T-093、T-096、T-098 已完成。
  - C 线（多核演进）：T-076、T-077、T-079、T-086、T-089、T-092、T-100、T-103、
    T-20260829-095（C3 四核实现）、T-20260830-018/019（C4 8/16/32 规模测量）
    已完成；完整多核差分、Linux SMP、多核 checkpoint 仍后置。
  - F/FPGA 相关：T-099 Gate D 已 PASS；T-101/T-102 已合入；T-028-065/067
    B5/Quartus 仍 blocked/未完成。
  - 本任务 T-20260829-104 为外部审计材料准备，当前 active。

## 2. DAG 与阶段门

当前项目按 ADR-20260829-005 分为：
- **F 单核发布列车**：P6/P7 标量+FP/NEON、P7-B AXI4/写回 Cache/单核一致性、
  V82 非 SVE profile、Gate D/F-ISA/F-MEM/F-BOARD/F-RELEASE。
- **G-MC 多核演进列车**：C0–C6、多核差分（LCVX-DIFF-MC-v2）、2/4 核正确性、
  8–32 核扩展性，新建 Gate G-MC；G-MC 不反向阻塞 F。

依赖只认 `done`；并行时使用唯一 topic worktree、写集不重叠、QEMU/checkpoint 串行。
具体并行波次和汇合点见 `docs/T-20260828-071-073-parallel-lines-plan-v2.md` 和
`docs/P7_FPGA_PARALLEL_PLAN.md`。

## 3. Subagent 派单与报告规范

- 写任务/构建任务必须使用仓库外 sibling worktree：
  `/home/chiro/projects/mycpu/lcvex-wt-<task-id>`；纯只读审阅可共享快照。
- dsh harness 映射（ADR-20260828-004）：
  - 派单用 `subagent` 或 `subagent_fork`；禁止用 bash `sleep` 轮询 subagent。
  - 默认派单省略模型，等价 `deepseek-v4-flash[max]`。Terra/Sol 高推理档由集成者
    当前会话或 workflow 编排层显式承担，不设默认。
  - 完成通知由 harness 自动发送；集成者核对 worktree、handoff、evidence。
- 时间戳规范：`sent_at/received_at/reported_at` 使用 Asia/Shanghai ISO-8601，
  耗时按报告时间差计算，不用模型回合时长。
- 子 Agent 不直接修改任务 JSON、`TASKS.md`、`PROJECT_STATUS.md`、`ROADMAP.md`
  等集成者台账；只提交短报告、handoff、evidence。

### 3.1 两类时间字段与单调性检查（AUD-09 / EXT-01-002）

为消除任务时间戳逆序和“晚于承载 Git 提交”的未来时间，台账统一区分：

| 类别 | 含义 | 典型字段 |
| --- | --- | --- |
| 事件发生时间 | 流程中真实发生的时刻：派发、接收、报告、运行、评审、合并 | `dispatch.sent_at`、`sent_at`、`received_at`、`reported_at`、`run_at`、`runs[*].started_at/finished_at/ended_at`、`integrator_review.received_at`、`merged_at`、`event_at` 及所有 `*_at` 事件字段 |
| 台账回填时间 | 记录被创建/写入/更新到台账的时刻，不用于耗时计算 | `created_at`、`updated_at`、`recorded_at`、`archived_at`、`documents_written_at` |

强制规则：

1. 事件时间必须使用 Asia/Shanghai ISO-8601；不得晚于当前本地时间。
2. 事件时间不得晚于承载该字段的 Git 提交时间（新提交时即当前提交时间；历史记录
   以 `git blame` 定位该行引入提交）。
3. 同一任务生命周期必须满足：
   - `dispatch.sent_at <= integrator_review.received_at`（`review >= dispatch`）；
   - `dispatch.sent_at <= merged_at`（如有）；
   - `dispatch.sent_at <= runs[*].started_at`（`run >= dispatch`）；
   - `created_at <= updated_at`；
   - `sent_at <= received_at <= reported_at`（报告元数据）；
   - `runs[*].started_at <= runs[*].finished_at/ended_at`。
4. 已合入的历史记录发现不一致时，**不得改写历史 handoff/evidence 原文**；应新增
   correction record（可放在 AUD 任务的 evidence JSON 中），保留旧值、给出修正值、
   说明依据，并留给集成者按 correction 回填。
5. 新任务/新 evidence 提交前执行：

   ```sh
   python3 scripts/check_task_timestamps.py --scope live --exit-code
   ```

   该脚本对 live（proposed/active/evidence）记录检查上述规则；`--scope all` 额外
   检查 archive。历史 archive 中大量“台账回填时间晚于承载提交”属于 pre-AUD-09
   遗留，脚本以 warning 提示，不作为新记录准入错误。
- 每次派单限制输入文档、验证层级和资源预算；默认 `resource.timeout_s` 不超过
  1800 秒，复杂任务可声明 `budget_policy`。

## 4. 写集与互斥

- 任务 JSON 的 `writes` 是预约；同一路径的写集在任务 `done/cancelled` 前保留。
- `docs/domains/README.md` 给出稳定子域和热点文件；`rtl/lcvex_pkg.sv`、
  `rtl/lcvex_core.sv`、顶层 `Makefile`、Gate 脚本、QEMU patch 序列默认串行。
- 共享 QEMU fork 和 checkpoint 路径不允许跨任务可写共享；QEMU 构建/patch 重放
  由集成者串行执行。
- 远端 FPGA 任务只允许在用户指定 Quartus 工程/实验目录内写，禁止改原始
  QSF/SDC/QPF/RTL，禁止删除未知文件，禁止读取/复制 license 内容。

## 5. 证据链

仓库采用三种互补记录：

| 载体 | 内容 | 写入者/冻结规则 |
| --- | --- | --- |
| `docs/tasks/active|archive/T-*.json` | 任务事实、owner、依赖、写集、验收、状态 | 集成者 |
| `docs/handoffs/<task-id>-<slug>.md` | 人读摘要、边界、结论、风险、证据链接 | owner；合入后不改写 |
| `docs/tasks/evidence/<task-id>.json` | 精确命令、source SHA、seed、工具版本、退出码、资源、artifact | owner 创建；集成者补 merge_sha 复跑后定稿 |

证据 JSON 是机器事实源；handoff 只引用 run/artifact ID，不重复整份数据。
大型 trace/波形/RAM/checkpoint 不进 Git，只记录持久 URI/SHA256/retention。

## 6. ADR

| ADR | 主题 | 状态 |
| --- | --- | --- |
| ADR-20260826-001 | 多 Agent 控制面与 worktree 布局 | accepted |
| ADR-20260826-002 | 子代理模型路由 v2 | accepted |
| ADR-20260827-003 | P7 与 Catapult 双轨、AXI4、一致性边界 | accepted |
| ADR-20260828-004 | dsh harness 多 Agent 控制面与派发适配 | accepted |
| ADR-20260829-005 | V82 非 SVE profile 与 A/B/C 并行路线执行口径 | accepted |

## 7. 暂停 / 恢复

- 任务可 `blocked -> ready`、`active/review/integrating -> blocked` 后再恢复；
  例如 C3/C4 曾按用户指令暂停，随后又恢复。
- 集成者负责在任务 JSON 中记录状态变化；子 Agent 不能自行改变任务状态。
- 预算默认到上限不硬中断（除非 `max_is_hard_stop: true`），转为后台长跑或
  提交 checkpoint/blocked。
- C3 四核实现与 C4 8/16/32 规模测量已完成并合入；历史上曾“待 C2 闭合/安静窗口”
  后再恢复，当前该前置已经满足。

## 8. cgroup / 资源限制

- 本地重型 Verilator 编译/仿真必须使用 cgroup 限制物理内存 < 16 GiB，优先
  `systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- <command>`。
- 重型构建一次一个，`-j 1` 或入口支持的受限并发；不能多个重型 Verilator 并发。
- 本机合计默认不超过 50% CPU/内存预算，CI 上限 75%；`scripts/test_planner.sh`
  只是建议器，不是原子 reservation。
- 证据 JSON 需要记录实际限制方法、峰值 RSS、cpuset 和资源数据。
