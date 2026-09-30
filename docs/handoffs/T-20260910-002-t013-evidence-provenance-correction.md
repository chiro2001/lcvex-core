# T-20260910-002：T-013 evidence/provenance 修正交接

```text
task=T-20260910-002 state=done acceptance_status=pass-documentary-correction-only
base=5702905425dfd149b791a7895a88ea453f8ad5a5 correction_head=ff1811c7ea09a2a4e45fec3e0bdf654059923e6f
branch=verify/T-20260910-002-t013-evidence-correction
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260910-002
sent_at=2026-09-10T00:45:02+08:00 takeover_received_at=2026-09-10T09:52:50+08:00
reported_at=2026-09-10T09:59:33+08:00 timezone=Asia/Shanghai
evidence=docs/tasks/evidence/T-20260910-002.json
```

## 结论

T-013 的证据身份和 artifact 元数据已经自洽。被测候选仍是 `d2f5cfdd...`，owner
证据提交是 `72712675...`，主线首次接收提交是 `c1484c43...`；三者已分开记录。
唯一错误的既有 size 字段是 `data_delay_summary.tsv` 的 `5134`，实际为 `5320`
bytes，原 SHA-256 正确，20/20 data-delay PASS 结论没有变化。

`final-acceptance-summary.json` 的 `metastability=[]` 是聚合器漏采。权威 standard STA
报告仍明确给出四个 corner、27 chains、最短 2 registers、0 timing-violation
chains；修正只声明证据优先级，没有向聚合文件填造数据。

TMS duplicate 名称也已直接复核 raw report：T-011 独有 `state[13]~DUPLICATE` 与
`hub_mode_reg[0]~DUPLICATE`，T-013 独有 `state[15]~DUPLICATE`。现有 diagnostic
JSON 与 raw report 一致，但正式不变量合同仍应从 raw report 独立计算完整集合。

## 验证与边界

25 个文档引用的 path/size/hash 全部重新计算，0 mismatch；JSON、diff 和本任务涉及
文档的 timestamp audit 均通过。全仓 timestamp 工具仍报告历史既有记录，本任务没有
改写那些文件。

本任务没有修改 RTL、SDC、QSF、manifest、policy/checker/exporter，也没有连接
GamePC、运行 Quartus、assembler、JTAG 或板卡操作。本任务完成时 T-013 仍保持
`blocked-ucp-cardinality-drift`；随后 T-20260910-001 已在合并 SHA 上用 v2 invariant
policy 对 fresh raw reports 完成 export/check，T-013 已最终转为 `done`。
