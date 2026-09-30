# T-20260920-019：T-017 UCP/reset invariant profile 交接

```text
task=T-20260920-019 state=done
base=957b00b46d7a6d61ec11419f8be1566156d9a62f
logic_commit=30e52226
received_at=2026-09-20T12:25:03+08:00
reported_at=2026-09-20T12:45:34+08:00
```

## 结论

T-017 的 fresh report-only measurement 已绑定到 normalized physical invariant
policy。仅新增 `accepted_profiles.T-20260920-017` 和
`report_profiles.T-20260920-017`，并机械更新 exporter 的 production policy digest；
UCP/reset waiver 语义、regex、cardinality、阈值和 forbidden 字段未改变。

T-017 原始 inventory 的 `candidate_manifest=null` 未被改写。T-019 生成了一个 ignored
canonical/alias candidate-manifest derivative，包含：

- candidate manifest SHA-256：`1cab668b2231695a48eb91ec8f48ff758f9eb2afa0a65ca13b4ad68d0e4322c9`；
- canonical SHA-256：`2d9c2d744d85af6db5a047c166822e8baad1eb56e68b987a17598d2a3fa3ac4b`；
- T-017 stage manifest SHA-256：`4a40486090a3711b7a15f7f5238e00efc497b0684801d41b84312b4c7fb3ae0d`；
- stage archive SHA-256：`43a67a1b0b7f0f3d50a9ea7be8df11249e6e1d0f6e3c59a53b17d61a947e87ef`；
- canonical entries=53、QSF aliases=47、stage files=174、QSF refs=50。

这使 T-017 stage 内容得到明确 hash binding，不把原始 T-017 artifact 静默改写成新的
provenance。

## 验证

- policy canonical digest：`c116e580f03b3366b15425a2ed934dc671207bf874a5660cb299520920f03acc`；
  exporter 常量与其一致；
- exporter：`PHYSICAL_WAIVER_INVARIANT_EXPORT_PASS`；
- checker：PASS，normalized UCP input=60、reset=624；
- TDI/TMS/TDO：25/35/4；
- reset families：emif_req_q=606、emif_state_q=4、timeout_count_q=13、calibration_gate=1；
- fast/slow recovery/removal violations=0，worst slack 为 +1.730/+0.206 ns；
- invariant fixture：2/2 positive PASS、27/27 negative rejected；
- Python compile：PASS。

精确 hash、命令和日志见 `docs/tasks/evidence/T-20260920-019.json`。

## 边界

未访问 GamePC，未运行 Quartus、assembler、JTAG、板卡或任何 RTL/QSF/SDC 操作。T-017
physical reports 仅作为只读输入；T-019 不重新解释或放宽任何 waiver 规则。
