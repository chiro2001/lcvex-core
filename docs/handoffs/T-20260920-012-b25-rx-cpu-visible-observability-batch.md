# T-20260920-012：RX CPU-visible observability batch 交接

```text
task=T-20260920-012 state=done partial=false
source=84715ac674366e9fa26556d97d197599731de832
acceptance=combined focused + vendor response trace + full-SoC PASS
```

## 结论

硬件与 firmware 两条互斥 lane 已在同一 batch candidate 合并验证。新增逻辑仅观察
CPU-originated JTAG DATA read，不驱动任何 functional ready/valid、request、response
或架构状态。只读 status 窗口现可报告 bridge、PoC、core dmem 三层 sticky raw
response、事件/fault 计数和 TX accepted-write；monitor 则用每行小于 64 字节的
`RXDBG/RXPATH/RXCPU` 页面报告 getc、dispatch 和 putc 状态。

clean r4 vendor-timed trace 对 `? / p / d / Z` 得到：

```text
bridge = PoC = dmem
?  0x0000A43F
p  0x0000A470
d  0x0000A464
Z  0x0000A45A
count = 4/4/4, fault = 0
```

`0xA400|byte` 是 generated Quartus JTAG-UART DATA word 的完整受控场景值，包含
RVALID、TX-not-full 和 AC；不是 stale 数据。firmware 在 mask byte 前保留完整 raw
low16，所以第四次有效 getc 的 packed 值为 `0004A464`。

既有 vendor focused Icarus/Verilator、status ABI、CAL-OK/CAL-WAIT/CAL-FAIL
full-SoC 全部通过；CAL-WAIT 场景在输入前完成 262,144 次空 DATA 轮询和
2,359,306 次提交，最终 `SOC_B25_ALL_PASS`。2011-byte boot image contract 和
test registry 87 项也通过。

## 边界与下一步

本批没有运行 Quartus/GamePC/JTAG，也没有任何 Flash、reset 或 power 行为。仿真中
未复现 bridge→core 响应丢失，因此不允许猜测性修 datapath。下一步必须以冻结 source
SHA 依次完成 Gate D、fresh synthesis/fitter/STA、assembler；随后只用新生成且哈希
绑定的 SOF 做一次易失板测。真板页面将直接区分：

- `RXPATH` 三层何处首次缺失或变值；
- `RXCPU` 是否 getc/dispatch，及 putc 是成功写入还是有限等待丢弃；
- 硬件 TX accepted-write 是否与 firmware store 对应。

完整命令、四次诊断迭代和 artifact hash 见
[`T-20260920-012.json`](../tasks/evidence/T-20260920-012.json)。
