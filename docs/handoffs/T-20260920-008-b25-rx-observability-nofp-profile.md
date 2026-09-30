# T-20260920-008：RX 可观测性 no-FP 组合 profile 交接

```text
task=T-20260920-008 state=done partial=false
acceptance_status=content-addressed-profile-and-affected-l0-l2-pass
base=85992f53c850091a466836e7fd4424dde6000484
profile=05ea248845f0b94b226ffe554e082980d89e452c
tree=23e4c5158732e90439a0d426c5eca8371d296f1a
```

## 结论

T-007 上传前的 fail-closed 检查发现 `85992f53` 实际仍以 full-FP 为默认配置，因而没有
把它误报为 no-FP。T-008 从该精确 Gate-D 候选派生，仅把 Catapult board top 的
`A64_FP_SIMD` 默认值由 `1'b1` 改为 `1'b0`；除此之外没有任何 tracked 差异。

新的 profile SHA 为 `05ea2488`，tree 为 `23e4c515`。core/SoC no-FP lint、消费默认值的
整板 skeleton lint、synthesis-selector、M20K 同步时序以及厂商时序 JTAG-UART focused
测试均通过。boot 仍是 1204 bytes，BIN/MIF 分别为 `7d8cf878…0322d4` 与
`491f30c4…655c90`。

## full-SoC 证据复用边界

`local` 槽被 pypto-x 合法持有，尝试按协议返回 75，未绕锁。这里没有等待后机械重复
T-005：唯一变化的 board-top 文件不在 `filelist_soc.f` 中；T-005 source `8f25c8e1`
到本 profile 的全部 SoC/boot 输入及两个 runner 均逐字节相同。T-005 已用
`-GA64_FP_SIMD=0` 对这套精确输入完成 CAL-OK/WAIT/FAIL、262,144 次空读取、2,359,302
次提交，并通过周期/动态 RXDBG、status、PONG 与 echo。因此该结果构成严格的组合证据，
而新变化的 board-top 默认值由本任务 platform lint 覆盖。

该 profile 只用于标量 bring-up，不替代 full-FP/P7 release。下一步将 T-007 快进到
`05ea2488`，按新 manifest 运行 fresh synthesis、fitter、STA 与 custom physical gates；
仍禁止 assembler、JTAG、Flash、reset 和 power 操作。精确证据见
[`T-20260920-008.json`](../tasks/evidence/T-20260920-008.json)。
