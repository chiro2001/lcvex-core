# T-20260830-042 CKPT-PROTO handoff

```text
task=T-20260830-042 state=review
base=0f4b4a18970219e719674edd6cb3ff91d4c7ac38 head=fb0c5f1dad81b6d822f1885aac19024c8a960177 content_sha=9e7f373e816e71fd92e8d81afc344df33230b56b
branch=feature/T-20260830-042-checkpoint-protocol worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-042
sent_at=2026-08-30T16:15:06+08:00 received_at=2026-08-30T16:16:40+08:00 reported_at=2026-08-30T16:49:52+08:00
followup_sent_at=2026-08-30T16:44:45+08:00 followup_received_at=2026-08-30T16:45:39+08:00 followup_reported_at=2026-08-30T16:49:52+08:00
files=docs/CHECKPOINT_PROTOCOL.md; docs/handoffs/T-20260830-042-checkpoint-protocol.md; docs/tasks/evidence/T-20260830-042.json
tests=docs-only/no-build + git diff --check
evidence=docs/tasks/evidence/T-20260830-042.json
blockers=P2 实际 lockstep capture 未接 B4 quiesce/drain；F3a 尚缺端到端 epoch/UID/stale quarantine、pipeline drain、I-L1 gate 和 timeout
next=集成者验收后解除 F3a checkpoint 文档门；实现 bridge/epoch/drain/timeout 前不得解除实现门
```

## 摘要

本任务只完成文档闭合，未修改 RTL/TB/sim/scripts/Makefile，也未运行生成器、构建、
仿真、QEMU 或 Quartus。新增的
[CHECKPOINT_PROTOCOL.md](../CHECKPOINT_PROTOCOL.md) 将当前实现和后续门分开标记：

- B4 standalone `lcvex_l1_coherence`/`lcvex_catapult_soc_coh` 的
  `checkpoint_quiesce → D-L1 dirty drain → L2/PoC drain → checkpoint_ack`、
  response/ack hold、probe abort 和 fault negative 被记录为 implemented；
- P2 `CKPT_REQ/CKPT_READY`、RAM/arch/sys v4/timer/GIC/MMIO/FP sidecar、strict
  pending/final manifest、parent/source/tool/hash/seq provenance 被记录为当前
  工具实现；
- P2 实际 `soc_tb` 没有 quiesce/drain 接口，C1/C2 没有完整 checkpoint envelope，
  也没有统一 epoch/UID/stale quarantine、pipeline drain watchdog 或每 checkpoint
  的 final marker/ACK 原子闭环，均明确列为 gap/blocker；
- MSHR、store buffer、F1 fetch FIFO 不进入 sidecar；未来只能保存前 drain、restore
  后 invalidate/quarantine。F1 local fetch epoch、F3a transaction epoch/age、G5
  synchronous RAM 和 C2 multi-core identity 的交叉门已列出。

## 边界与风险

1. 硬件 `checkpoint_ack_valid` 只代表稳定的 drain 边界，不单独代表已发布 artifact；
   sidecar/manifest fault 必须终止最终发布，不能将早先 drain ack 宣称为完整成功。
2. 当前 P2 协调器在一个 COMMIT 窗口内保存 QEMU sidecar 并等待 ACK，但
   `run_lockstep_step.sh` 在整个运行结束后才 `finalize-manifest`；这不会接受
   pending 链为恢复输入，但不满足每 checkpoint 的 final marker 原子顺序。
3. 当前 restore 会 reset/flush core pipeline、注入 sys/timer/FP、再直接写 GIC 和
   C++ MMIO，并以 INIT 校验 arch 摘要；arch/sys 交叉 payload、cache/TLB empty
   ack 和 epoch bump 尚未实现。
4. Timer 当前固定 `CNTFRQ=1 GHz` 且 `CNTVOFF/CNTPOFF=0`；FP 仅 canonical
   A76/V/16B profile；SVE Z vector 不保存；GIC 仅单核前 96 IRQ envelope。
5. 现有历史 checkpoint joint smoke 的 PASS 保留为 handoff/evidence 引用，不是
   本任务当前 SHA 的新测试结果。

## 证据和后续

精确只读命令、源 SHA、文件清单、状态标签和未运行测试事实见
[`docs/tasks/evidence/T-20260830-042.json`](../tasks/evidence/T-20260830-042.json)。
`content_sha` 表示包含技术文档的内容提交；evidence 自身不能预写承载它的最终
commit，故最终 metadata commit 的 branch tip 以 owner FINAL 的 `head` 为准；
本 handoff/evidence 的 `head` 与 `content_sha` 均固定指向技术内容提交
`ea70321cfdfd1d02364cddefa1da2744f2e302a5`，不冒充最终 tip。

本次最终时间戳回填由 metadata follow-up 承载；旧 `reported_at=2026-08-30T16:42:40+08:00`
及第二次回填值 `2026-08-30T16:46:16+08:00` 均保留为 correction 事实。集成者按
harness 实际收件时间纠正为 `2026-08-30T16:49:52+08:00`；该时间晚于 owner 最终
提交 `fb0c5f1` 的 `2026-08-30T16:49:01+08:00`。最终 owner branch tip 为
`fb0c5f1dad81b6d822f1885aac19024c8a960177`，包含技术修正的 content commit 为
`9e7f373e816e71fd92e8d81afc344df33230b56b`。

本次 follow-up 修正了主文档第 3/5 行尾随空格，并将严格序列中的
`TRANSACTION/PoC_DRAIN` 改为 `CORE_PTW_TRANSPORT_INFLIGHT_DRAIN`，明确该阶段
只排空已接受 core/PTW/arb/router/delay/RAM response，不提前执行 cache dirty
到 PoC；dirty 顺序仍固定为 `D_L1_DIRTY_DRAIN → L2_POC_DRAIN`。
