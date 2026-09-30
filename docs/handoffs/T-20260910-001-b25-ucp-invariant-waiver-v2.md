# T-20260910-001：B25 UCP invariant waiver v2 交接

```text
task=T-20260910-001 state=implementation-complete acceptance_status=pass-local-fixture-and-actual-t011-t013
base=5702905425dfd149b791a7895a88ea453f8ad5a5 implementation_head=c908140f95dc373de67b044513697fb4122ae7b2
branch=infra/T-20260910-001-b25-ucp-invariant-v2
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260910-001
sent_at=2026-09-10T00:45:02+08:00 takeover_received_at=2026-09-10T09:52:50+08:00
reported_at=2026-09-10T10:47:02+08:00 timezone=Asia/Shanghai
evidence=docs/tasks/evidence/T-20260910-001.json
```

## 结论

新增 v2 policy/exporter/checker 后，T-011 的 raw `63/627` 与 T-013 fresh 的 raw
`61/626` 在同一合同下均通过。两者去除严格受限的 fitter terminal
`~DUPLICATE` 后，完整 endpoint 集合完全相同：TDI/TMS/TDO 为 `25/35/4`，reset
为 624，reset family 为 `606/4/13/1`。因此 T-013 的 cardinality drift 已被证明是
routability duplication 选择变化，不是功能 endpoint 丢失。

旧 v1 policy/checker/exporter/fixtures 全部保持原字节哈希，历史 T-010/T-011 仍可按
原合同重放；没有把固定 `627` 偷改成 `626`。v2 使用完整规范化成员列表及 canonical
SHA-256，而不是只比较数量。

## Fail-closed 边界

只有 internal endpoint 末尾精确一次 `~DUPLICATE` 可以归一化，而且同 report 必须
存在 unmarked base。port/from/clock marker、大小写/编号变体、缺 base、重复 duplicate
全部拒绝。UCP 的 clocks、ports、directions、空 Clock 字段、每个 endpoint 的唯一
vendor hierarchy class 仍严格闭合；JTAG period/create_clock、reset false-path 和任何
额外 exception 均拒绝。

四份 fast/slow recovery/removal report 必须得到完全相同的 624 项集合；source、
launch/latch clock、corner、header/summary/detail 自洽、每条详细 slack 和 0 violation
逐项验证。物理 duplicate 的 slack/corner 可以因布局不同而变化，但每条 raw timing
row 仍独立验收，不能靠归一化隐藏负 slack。

measurement provenance 不再只信手填字符串。exporter 实际读取并哈希 user SDC、
generated EMIF SDC、source pre/post manifest、T-013 candidate manifest 和七份 raw
reports；checker 将这些内容绑定到 T-011/T-013 各自的 reviewed profile。另一个内容
相同但未登记 raw hash 的 T-013 clone 会被拒绝，不允许跨 snapshot 拼装证据。

## 验证

- synthetic old/new duplicate selection：2/2 export+check PASS；
- 27 个 raw/inventory/policy 负例：27/27 rejected；
- actual T-011：export+check PASS；
- actual T-013：export+check PASS；
- mixed snapshot 和 unprofiled clone：拒绝且不生成 output；
- `py_compile`、`git diff --check`：PASS。

本任务只有本地轻量解析，没有连接 GamePC 或运行 Quartus；没有修改 RTL、SDC、QSF、
manifest，也没有 assembler、bitstream、JTAG、板卡或 Flash 行为。下一步由集成者合入
T-20260910-002 证据修正和本任务，在合并 SHA 复跑 fixture 与 actual T-013
export/check，然后才能解除 T-013 UCP blocker。
