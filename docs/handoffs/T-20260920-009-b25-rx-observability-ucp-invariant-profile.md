# T-20260920-009：RX physical UCP/reset invariant profile 交接

```text
task=T-20260920-009 state=done partial=false
acceptance_status=fresh-t007-normalized-invariant-profile-pass
physical_candidate=05ea248845f0b94b226ffe554e082980d89e452c
implementation=bb00f80a89ec15a3fe8e87d22a420540293ce20b
```

## 结论

T-007 fresh fitted clone 的完整 UCP/recovery/removal 原始报告已通过 v2 exporter 与
checker。归一化结果保持原合同：两个 unconstrained clocks，TDI/TMS/TDO 分别
`25/35/4`，reset endpoint `624`，四个 family 为 `606/4/13/1`，无额外 exception 或
clock constraint。

本次每份 reset raw 报告有 627 条路径，其中 3 条是可证明存在 base endpoint 的末尾
`~DUPLICATE`；归一化成员及 digest 与历史 profile 完全一致。0 violation，最差
recovery/removal 为 `+0.903/+0.202 ns`。

## 实现与 fail-closed 控制

实现只向 policy 追加 T-007 的 exact candidate/tree、source manifest 与七份 raw report
hash，并更新完整 canonical policy digest。删除 provenance 后，normalized policy 与基线
字节等价；T-011、T-013、T-004 profile 均未改变并重新 check 通过；fixture 仍为
2/2 positive 与 27/27 negative。

初次复用 UCP Tcl 时曾把历史 producer/contract-source header 机械改为当前任务信息，
exporter 连续拒绝。最终没有放宽 exporter，而是恢复原合同 producer
`T-20260909-007` 与 source `702bd8ee`，并通过独立 measurement provenance 绑定当前
candidate `05ea2488`；只重跑了 report-only UCP 查询，没有重跑 synthesis/fitter。

下一步可定稿 T-007 physical 证据。assembler 仍须独立立项，只能从该精确 fitted DB
生成易失 SOF；JTAG/Flash/reset/power 均不属于本任务。精确证据见
[`T-20260920-009.json`](../tasks/evidence/T-20260920-009.json)。
