# T-20260902-012 FP/NEON 流水化计划审核交接

```text
task=T-20260902-012
state=done
base=d892ba7820cd6db39a1144d8d4b3236a43a11891
head=035d1eeb0d00585678d6db507301fd7b99411bd3
implementation_commit=ecf62a194b002e951287bec33a728841b0ed18d7
merge=6c2e56a10dad470b4e43487cec397a721aa570d9
branch=docs/T-20260902-012-fp-neon-pipeline-plan
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-012
sent_at=2026-09-02T23:55:07+08:00
received_at=2026-09-02T23:55:07+08:00
reported_at=2026-09-03T00:16:23+08:00
files=docs/FP_NEON_PIPELINE_PLAN.md
tests=doc-links/make-targets/diff-check:pass
blockers=none-for-plan; implementation has FP-P0 P7-2 baseline blocker
next=register FP-P0 and close the independent P7-2 baseline blocker
```

## 结果

已把原 119 行草案改为可执行的 463 行实施计划。修订基于当前 RTL、P7 协议、
性能计划和 T-20260902-010 的正式 A10 full-FP synthesis evidence，不运行构建、
锁步、Quartus 或板测。

核心结论：

- 当前 full-FP 只证明 synthesis PASS；482,334 ALM 超过器件 427,200 ALM，尚无
  fitter/STA，不能宣称 fit、Fmax 或已定位关键路径。
- 删除无仓内证据支撑的“FP 占 83% ALUT”表述，要求 FP-P0 通过 hierarchy 与
  standalone synthesis 做同 SHA 资源分解。
- 首选“单在途、阻塞式、一个共享 64-bit lane engine”，先消除 core scalar +
  NEON 四 lane 的结构复制；二 lane和吞吐流水在一 lane fit/STA 后条件式评估。
- 首版明确不做 scoreboard、年轻整数/访存绕过或多 FP 在途，避免在没有全局顺序
  退休结构时越过非 OoO 边界。
- 补齐 transaction 的 request/response/kill/reset/backpressure 契约、H/S/D 与
  2S/4S/2D/4H/8H slot 映射、FP-P0～P6 DAG、FP-O0～O6 量化门、L0～L3/FPGA
  验证矩阵、风险/回退和协作写集约束。
- 将 T-20260902-010 已记录的 P7-2 DUP/SQADD decode overlap 作为 FP-P0 blocker，
  明确禁止以“允许红项”方式带入优化签核。

## 边界与风险

- 本任务只修改计划文档和任务证据，没有修改 RTL、测试、QEMU、项目状态或路线图。
- ALM 90% hard gate、80% optimization target 是后续实施门槛，不是当前通过结果。
- 一 lane 的实际 latency、面积和 workload 退化尚未测量；必须由 FP-P0/P2/P4
  同 SHA evidence 决定，不能从结构数量线性外推。
- 完整日志、Quartus hierarchy、fit/STA 与板级结果均不在本任务范围。

## 验证

- 文档内 9 个相对链接均解析到现有文件。
- 文档列出的 12 个现有 Make target 均在 `Makefile` 中存在。
- `git diff --check` 通过。
- `python3 scripts/check_task_timestamps.py --scope live --exit-code` 返回 1：全仓已有
  24 errors / 20 warnings；`--json` 过滤 `T-20260902-012` 为 `[]`。本任务没有
  新增时间戳问题，既有历史记录未改写。
- `docs/FP_NEON_PIPELINE_PLAN.md` SHA-256：
  `a4c04a2416f2f0f11b6986ddd65a480fddf76da68cf68177884b093b2d36ef94`。

机器可读事实见
[`docs/tasks/evidence/T-20260902-012.json`](../tasks/evidence/T-20260902-012.json)。

## 集成者验收

`035d1ee` 已于 2026-09-03T00:19:08+08:00 合入 `feature/p7-final`，merge SHA
为 `6c2e56a10dad470b4e43487cec397a721aa570d9`。验收范围仅为文档计划与轻量一致性
检查，不把计划阈值当作 RTL、Quartus 或性能通过证据。
