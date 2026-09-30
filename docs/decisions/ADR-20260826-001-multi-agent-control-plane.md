# ADR-20260826-001：多 Agent 最小控制面与 Worktree 布局

- 状态：accepted
- 日期：2026-08-26
- 关联规范：[`docs/MULTI_AGENT_WORKFLOW.md`](../MULTI_AGENT_WORKFLOW.md)
- 起草基线：`feature/p6-system-reg-shim`，parent `61245ff`

## 背景

仓库已有单 runner 内的并行锁步和资源建议器；worktree 可隔离仓库相对产物，但
同一 worktree 固定路径、外部 QEMU、全机资源和任务/文档热点仍需统一协调。

## 决定

1. 当前由集成者静态派单和维护重型测试队列，不引入常驻服务、网络数据库或
   GitHub Issues。只有手工流程成为实际瓶颈后才增加标准库 Python `taskctl` 薄 CLI。
2. Git 中每任务一份 JSON 持久定义/状态，`TASKS.md` 是带时间戳的审计快照；A0
   不手工模拟 TTL/heartbeat/lease 数据库。
3. 每个写任务一个仓库外 Git worktree。QEMU 路径参数化前使用
   `/home/chiro/projects/mycpu/lcvex-wt-<task-id>` 直接 sibling；参数化后才允许更深
   目录。纯只读审阅可共享指定快照。
4. 不同 worktree 已隔离仓库相对产物；外部 QEMU、同一 worktree 固定目录和全机
   资源仍需串行/排队。本机总体上限保持 50%，CI 75%。
5. 文档分为 task、不可变 handoff、机器可读 evidence、ADR 和里程碑 snapshot；
   `PROJECT_STATUS.md`/`ROADMAP.md` 由集成者批量更新。
6. Agent 跑受影响 L0–L2，集成者在合并 SHA 重跑所需子集；L3 Gate D 和 L4
   nightly/长跑属于 integration wave/milestone。
7. Agent 类型采用成本受控的模型路由：评审显式使用 `gpt-5.6-sol[xhigh]`，快速
   实现显式使用 `deepseek-v4-flash[max]`，慢速实现/长跑监控省略 `model` 参数并
   使用平台默认 `gpt-5.6-luna[xhigh]`。模型、推理档位和任务边界必须进入任务
   JSON/evidence；省略模型表示默认 Luna，不表示未选择模型。

## 备选方案

- 单一共享 worktree：源和产物冲突风险不可接受。
- 每个 Agent 完整 clone：隔离充分，但浪费对象库、同步和磁盘成本。
- GitHub Issues/常驻调度服务：当前单机规模下运维成本高于收益。
- 单一手写 `TASKS.md`：在并行分支中会成为新的合并热点。

## 影响与迁移

先按 A0 静态双 Agent 试点。A1 只处理实测冲突：必要时增加全局 test-slot、薄
taskctl 或真实共享路径参数；A2 再按度量决定测试 registry、QEMU worktree、缓存或
更复杂调度。Agent 数量本身不是服务化理由。
