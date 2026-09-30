# T-20260829-077 D0 多核差分协议 LCVX-DIFF-MC-v2 可行性

> 结构化元数据
>
> task=T-20260829-077 state=review base=3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2 head=5ed0c555a870d0e3f0180126c925319738481b1b report_head=0c48cc28d458a2efe8d65bffa6557326e794233a branch=feature/T-20260829-077-d0-mc-diff-feasibility worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-077 sent_at=2026-08-29T01:47:44+0800 received_at=2026-08-29T01:52:00+0800 reported_at=2026-08-29T01:52:00+0800 files=docs/LCVX_DIFF_MC_V2.md,docs/handoffs/T-20260829-077-d0-mc-diff-feasibility.md,docs/tasks/evidence/T-20260829-077.json tests=git-diff-check,json-tool,read-only-qemu-source-audit blockers=QEMU-plugin-no-after-retirement,no-stock-token-scheduler,mtcgt-vs-icount-tradeoff,multicore-checkpoint-sidecar-not-implemented next=review-then-C1-with-reference-model-fallback

## 1. 结论

本 D0 完成 `LCVX-DIFF-MC-v2` 协议/可行性设计，结论为：

- **v1 保持完全兼容**：不修改现有消息类型、payload、trace 头和 checkpoint
  旧链；v2 使用新消息类型 32..42，并在 payload 内放 `lcvex_mc_envelope`
  （`version/core_id/global_seq/vcpu_seq/event_kind/commit`）。
- **QEMU 11.1.0 能区分核**：所有 vCPU 回调带 `vcpu_index`，`qemu_info_t`
  给出 `smp_vcpus/max_vcpus`。
- **QEMU 官方插件没有通用逐核 after-retirement 回调**：指令级只有
  before-instruction callback；普通 COMMIT 是“同核下一条 before 回调推导后状态”，
  不是真正退休事件。
- **单线程 RR + stock plugin 不能做逐核 token 调度**：插件阻塞会卡住唯一
  vCPU 线程；没有公开“让当前 vCPU 回到调度器”的插件 API。
- **MTTCG token scheduler 原理可行但需大量改造**：`thread=multi` 才能让每核
  独立阻塞在插件回调上；代价是不能与 `-icount` 同用，也没有真正退休回调。
- **推荐第一版走 reference-model + litmus fallback**：用 v2 事件流做每核
  reference-model 重放、定向 litmus 比较、checkpoint 恢复证据；不宣称多核
  strict lockstep 已完成。
- **checkpoint 最小扩展已给出**：每核 GPR/PSTATE/system/timer/L1、共享目录、
  GIC/IPI、全局调度 token、每核协议 pending，并建议用独立 v2 manifest 保留旧链。

## 2. 完成内容

- 新增 `docs/LCVX_DIFF_MC_V2.md`，包含：
  - v1 冻结与 v2 envelope 结构、新消息类型、v1/v2 解析规则；
  - PRE/GO/COMMIT/ACK/ASYNC/STOP 语义与“不得把 before 当 after”边界；
  - QEMU 11.1.0 插件能力矩阵和源码证据；
  - 两核最小规范序列；
  - reference-model/litmus fallback；
  - 多核 checkpoint 扩展清单；
  - 阻塞项和下一步。
- 新增本 handoff。
- 新增 `docs/tasks/evidence/T-20260829-077.json`（初版 owner evidence）。

## 3. 验证摘要

本任务为可行性/协议设计，未修改代码，不需要 L0–L2 仿真回归。已做：

- `git diff --check`：无空白错误。
- `python3 -m json.tool`：evidence JSON 格式合法。
- 只读源码审计：QEMU 11.1.0 插件 API、TCG 单线程/MTTCG 调度、本项目现有
  plugin/coordinator/checkpoint 结构；未运行共享 QEMU、未写 socket/checkpoint。

## 4. 文件列表

- `docs/LCVX_DIFF_MC_V2.md`
- `docs/handoffs/T-20260829-077-d0-mc-diff-feasibility.md`
- `docs/tasks/evidence/T-20260829-077.json`

## 5. 阻塞与限制

- QEMU stock plugin 无通用 after-retirement 回调。
- 当前 `thread=single` 下无 stock 插件手段实现逐核 token 调度。
- MTTCG token 路径可行但需新插件/协调器，且与 `-icount` 互斥、虚拟时间需另定。
- 多核 checkpoint sidecar/version 尚未实现，仅设计。
- 不宣称多核 RTL、Linux SMP、完整 ARM 内存模型已支持。

## 6. 下一步

1. 集成者 review 本 D0；若接受，C1 先以 reference-model/litmus fallback 实现
   每核提交记录与双核壳层。
2. 若后续需要真正 strict lockstep，另开串行 QEMU fork 任务增加 per-vCPU
   retirement + yield 原语。
3. 多核 checkpoint 按第 8 节独立任务实现，并保持旧链只读兼容。
