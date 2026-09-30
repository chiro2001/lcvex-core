# T-20260919-005：fresh no-FP UCP/reset invariant profile 交接

```text
task=T-20260919-005 state=done partial=false
acceptance_status=fresh-t004-normalized-invariant-profile-pass
base=d00d566da86e034d6cf1651cdfb8ec50074ead13
implementation=4ef63a70acef32dcf140c377eb6059ff3cd5c9cd
branch=infra/T-20260919-005-b25-nofp-ucp-invariant-profile
evidence=docs/tasks/evidence/T-20260919-005.json
```

## 结论

T-004 fresh fitted clone 的完整 UCP/recovery/removal 原始报告已通过 v2 exporter 和
checker。归一化后仍是两个 unconstrained clocks、TDI/TMS/TDO `25/35/4` 条路径，
reset endpoint `624` 个；四个 reset family 为 `606/4/13/1`，所有既有 member digest
逐项不变。每份 reset 报告的 raw path 为 628，其中 4 个只是带可证明 base 的末尾
`~DUPLICATE` 物理复制；0 violation，最差 recovery/removal 为 `+1.086/+0.179 ns`。

实现只追加 T-004 的 content-addressed accepted/report profile，并更新由完整 policy
canonical JSON 计算的 fail-closed digest。删除 `provenance` 后，新旧 policy 字节等价；
T-011/T-013 历史 profile 也逐字节不变。原 fixture 保持 2/2 positive 和 27/27 negative，
两组历史实际报告均重新 export/check 通过。

## provenance 边界

T-004 使用的是新的 174-file stage-manifest schema，不伪装成旧 exporter 所要求的
canonical+alias manifest；因此 v2 profile 的 `candidate_manifest` 明确为 null。精确
candidate SHA/tree、user/generated SDC 与 source pre/post full manifest 已绑定，T-004
证据另外保存 stage-manifest 哈希。没有为方便验收而扩展 exporter schema或放宽成员合同。

## 下一步

把两文件实现和本证据串行合入 bring-up 集成线；T-004 即可完成 normalized UCP gate。
随后 assembler 仍只能从 T-004 的 fresh physical 数据库建立独立 clone，并且只能生成
易失 SOF。详细 raw report hash、fixture/replay 结果见
[`T-20260919-005.json`](../tasks/evidence/T-20260919-005.json)。
