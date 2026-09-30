# T-20260905-001：时序收敛批次流水线交接

```text
task=T-20260905-001 state=done base=0f8802fd360ff031728075b3b6b218f2ba10ffcd head=8e6a41f44523bfaea0f7b8bf7388502277a6344b branch=feature/p7-final worktree=/home/chiro/projects/mycpu/lcvex sent_at=2026-09-05T00:28:54+08:00 received_at=2026-09-05T00:28:54+08:00 reported_at=2026-09-05T00:50:50+08:00 files=AGENTS.md,docs/MULTI_AGENT_WORKFLOW.md,docs/FP_NEON_PIPELINE_PLAN.md,docs/decisions/ADR-20260905-006-timing-closure-batch-pipeline.md tests=文档diff/JSON/timestamp定向检查 blockers=none next=从T-058新top-N开始首个Timing Batch
```

## 结论

时序收敛默认由逐条串行 round 改为 Timing Batch：每次 STA 先把 top-N 按共享组合
锥、端点族和模块聚类，再选择最多三个独立 cone lane 并行实现。lane 不各自占用
重型仿真槽，而是先汇入可丢弃的 `batch/*` candidate；该合并 SHA 运行所有 member
acceptance 声明的 L0–L2 并集，通过后才以 `--ff-only` 晋级长期 feature 分支，并
只运行一次远端 physical。

同文件并行只允许 batch 父任务持有整文件、成员声明互斥 `write_regions`；公共
声明、接口、状态机骨架、latency 表和测试入口由 integration lane 串行处理。无法
证明互斥或影响同一寄存器边界/组合锥时退回单 lane。

本地 Verilator/QEMU/Gate/Linux 与远端 Quartus 分为两个资源槽，各自槽内串行、
路径隔离时可互相重叠。physical 等待期间可以做下一批只读分析和 speculative
原型，但必须等新 STA 重新聚类，旧路径消失时丢弃或 rebase 重审。

只读评审指出并已修正三个阻断：旧 §9 的单重型队列冲突、可能漏测的“代表性 L2”、
以及 candidate 与长期 feature 的 SHA 漂移。详细决策和验证事实见 evidence 与
ADR-20260905-006。
