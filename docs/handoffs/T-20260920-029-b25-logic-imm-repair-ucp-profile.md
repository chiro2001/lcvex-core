# T-20260920-029：T-027 fresh UCP/reset production invariant profile 交接

```text
task=T-20260920-029 state=review base=3992e66b204a7f9c0ce5d838d0dbe96c81fa7a02 implementation_head=05ad2b2e2058a51168ae8863129dca6bb1960dea evidence_parent=01b1106f373837402286919496d4b16304bfe674 owner=ucp_t029 branch=infra/T-20260920-029-b25-logic-imm-repair-ucp-profile worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-029 sent_at=2026-09-20T16:42:59+08:00 received_at=2026-09-20T16:42:59+08:00 reported_at=2026-09-20T17:05:00+08:00 files=policy/exporter/evidence/handoff tests=exporter-checker-fixture-pycompile blockers=none next=integration-review-and-merge
```

## 结论

T-027 candidate `2a1cd5c59fc27f0a6d947c58f5b24b194d4dd13b` / tree
`e5e94ab175f6847d727901576a8f12958efc1100` 已绑定到 production normalized
invariant policy。policy 仅新增：

- `provenance.accepted_profiles.T-20260920-027`；
- `provenance.report_profiles.T-20260920-027`；
- exporter 的 production policy digest 机械更新为
  `b437b56554e6ea4b57ede797a956fe11ee2e9bf92a2a31149e7ca9d3a8bea8b3`。

删除新增 profile 后，policy 与 base 的其余 JSON 内容 byte-identical。profile 绑定
174 stage files、50 QSF references、stage manifest/archive、candidate SHA/tree、
Quartus Prime Pro 21.4.0 Build 67、device `10AX115N4F40E3SG`、user/generated
SDC 以及 source pre/post manifest。

task-owned ignored 派生物为：

- candidate manifest：`build/agents/T-20260920-029/analysis/t027-candidate-manifest.json`，
  SHA-256 `ce9da04bb4edb22014f7d9506bcb54ddfadc3961071fc0a46446f88a3356314f`，
  canonical entries=53、QSF aliases=47；
- measurement provenance：`build/agents/T-20260920-029/analysis/t027-measurement.json`，
  SHA-256 `a4f772830fa8c25c807aa01e53e7db08e627c71fc7455231201d8fbd026bfb58`；
- exported inventory：`build/agents/T-20260920-029/analysis/t027-invariant-inventory.json`，
  SHA-256 `8a494d62200f994c5b1ed78bbe6b5ddbbfb606bcfa9f9ea8085d2ab0b6bc06ef`。

T-027 原始 measurement/evidence 未改写。原始运行 summary 的 hash
`32666688163eb12f314420267d756c92cb74805075b3c93f89c887e4e9a14d32` 单独保留；正式
exporter 按 T-019 模式消费只读 T-007 contract summary，hash 为
`6e9162d7c6672258c22ff7e49f35c29e1066fdf8e7847df162a783a9f1dfe938`。

## 测量与验证

- normalized UCP input=60，reset=624；TDI/TMS/TDO=25/35/4；
- reset families=`emif_req_q=606`、`emif_state_q=4`、`timeout_count_q=13`、
  `calibration_gate=1`；endpoint digest=`8f7b6b7238c5fda2c9049c50bb105ebd613f6c341e694eade569d20221ff7efb`；
- fast/slow recovery/removal violations=0，worst slack 为 `+1.388/+0.238 ns`；
- exporter：`PHYSICAL_WAIVER_INVARIANT_EXPORT_PASS`；checker：`PASS normalized_ucp=60 normalized_reset=624`；
- fixture matrix：`build/agents/T-20260920-029/invariant-fixture/matrix.json`，2/2 positive PASS，27/27 negative rejected；Python compile 与 `git diff --check` PASS。

精确输入 hash、命令、日志 hash 和语义差分结论见
[`docs/tasks/evidence/T-20260920-029.json`](../tasks/evidence/T-20260920-029.json)。

## 边界与风险

T-027 synthesis 的 vendor-generated warning 16788 仍是 acceptance blocker；本任务未
豁免、过滤或抑制它。未访问 GamePC，未运行 Quartus/assembler/JTAG/板卡/flash/reset-power，
未修改 RTL、firmware、QSF、SDC 或 test expected。可合并前由集成者在合并 SHA 复跑轻量
policy/exporter/checker/fixture 子集。
