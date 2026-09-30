task=T-20260909-012 state=review base=fd318a6a620d5b585406088e9714a60a1e34f87e head=4e10351efad4381a8298c8b3ebd02c1c31f9ba89 branch=infra/T-20260909-012-b25-physical-inventory-exporter worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-012 sent_at=2026-09-09T13:33:51+08:00 received_at=2026-09-09T13:33:51+08:00 reported_at=2026-09-09T14:18:01+08:00 correction_at=2026-09-09T14:18:01+08:00 pre_correction_head=c888ad310037b7bb0a034ceab1b276ad5308ab03
files=fpga/catapult_a10/tools/export_physical_waiver_inventory.py, fpga/catapult_a10/tools/run_physical_inventory_exporter_fixture.py, docs/tasks/evidence/T-20260909-012.json
tests_rerun=synthetic positive/checker PASS; 13/13 negative PASS; T-007 actual export/checker PASS; T-011 actual export/checker PASS; py_compile PASS; git diff --check PASS
blockers=none
next=integrator cherry-pick 4e10351e and the evidence-only follow-up commit; rerun exporter/checker on the frozen candidate

correction=交叉审查 NEEDS_CHANGES 已修复：UCP Clock 字段强制为空并拒绝 period/create_clock；timing 表尾分隔线后 numeric path 拒绝；未知 UCP summary 行拒绝；证据命令使用明确绝对路径

# T-20260909-012 交接

## 结论

已实现一个只使用 Python 标准库的 hermetic、fail-closed exporter。它读取 T-007 风格的 machine-readable `t007_summary.tsv`、两份原始 UCP 报告和四份 recovery/removal `report_timing` 报告，输出 T-010 要求的精确 `lcvex-physical-ucp-recovery-removal-v1` inventory。

所有 UCP 计数、端口 path-group 计数、层级 witness 和 recovery/removal worst slack 都从报告行推导。summary 的冻结源 SHA、报告登记、path/path_detail 行、setup/hold 一致性、重复键、连续索引和 raw-report 对应关系均在输出前检查。policy 合同被严格校验，观察值若偏离 T-010 合同则不写 output。

TimeQuest 对 `altera_reserved_tdi -> altera_reserved_tdo` 的 loopback 只给出 port-only endpoint；工具仅在该精确 `_tdi`/`_tdo` 结构且 output 仅有一个 policy group 时使用 policy-derived fallback，并要求其余 hierarchy witness 直接来自 raw rows。任意 user hierarchy、额外 unconstrained clock/port、歧义匹配或多余 fallback 均失败。

## 验证结果

- synthetic fixture 位于 ignored 的 `build/agents/T-20260909-012/physical-inventory-fixture-correction-final/`：正例 export 和 T-010 checker 均 PASS；13 个 fault case（缺报告、缺 UCP 行、缺 summary 行、malformed summary、重复 summary key、重复 UCP key、额外 UCP clock、额外 UCP port、timing count drift、source SHA mismatch、Clock period/create_clock、未知 UCP summary 行、timing 尾部分隔线后 path）全部以 exit 1 拒绝。
- 原始 T-007 snapshot：export PASS；生成 inventory 通过 `check_physical_waivers.py`，得到 2 clocks、TDI/TMS/TDO 为 26/37/4 paths，fast/slow recovery/removal 为 627 paths、0 violation、WNS +1.202/+0.191 ns。
- T-011 merged-SDC report-only snapshot（集成者授权只读）：export PASS；生成 inventory 通过 `check_physical_waivers.py`，上述计数/slack 相同，输出 hash 与 T-007 输出相同。
- correction rerun：上述 synthetic、T-007 和 T-011 三条正例路径均使用修正后的 `4e10351efad4381a8298c8b3ebd02c1c31f9ba89` 重跑；新增 Clock period/create_clock、timing 尾部 path、未知 UCP summary 行三项负例，13/13 均按预期 exit 1。
- 实际快照路径已固定为 `/home/chiro/projects/mycpu/lcvex-wt-T-20260909-007/build/agents/T-007/runtime/remote_final5` 与 `/home/chiro/projects/mycpu/lcvex-wt-T-20260907-037/build/agents/T-20260909-011/runtime/remote/final/ucp_reset`，可直接重放。
- 未运行 Quartus、QDB、GamePC、网络、JTAG、assembler、板卡或 Flash；本任务是 local light，不使用 resource lock。

## 风险与限制

- exporter 绑定冻结 source SHA `702bd8ee5295efe8a2ad9e094d6c12471a1d3089` 和 T-010 policy；新的 physical source 必须显式建立新 policy/任务合同，不应复用旧 inventory。
- T-007/T-011 raw report grammar 是 Quartus 21.4 生成的 semicolon table；若未来 Quartus 改变列布局，工具会拒绝而不是猜测字段。
- 工具不访问 QDB，也不替代最终 physical rerun；集成者仍需在合并 SHA 上重跑 exporter、checker 以及后续 physical sign-off。
