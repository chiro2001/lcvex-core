# T-20260920-022：B25 RXCPU logical-immediate 综合修复批次交接

```text
task=T-20260920-022 state=done-pre-gate
base=1ce74e9c81c40812ea93a161d52cad8dda807a0d
candidate=c31b3aea754769304ab7c9a24ef2f78c8120bc2a
tree=7ea2ea1c473a7c2c2b0eafe4dfd0fdfab9273c03
```

## 结论

T-021 真板证明 `?` 的 `0x0000A43F` 已同时到达 bridge、PoC 和 core dmem tap，且
`uart_getc` 的 `TBNZ W0,#15` 进入 valid 分支；但紧随其后的
`AND W6,W0,#0xffff` 与 `AND W0,W0,#0xff` 均表现为零。此前 fresh Quartus 报告正好
在 logical-immediate automatic output `imm` 上持续产生 warning 16788。

本批次以旧 RTL fresh synthesis 重新复现 warning 16788，然后把 decoder 改为一个所有
路径完整赋值的 65-bit `{valid,mask}` 纯返回函数。实现不再使用 output/inout function
参数、`break`、变步长循环或全宽未定义移位，也没有修改 core/dmem、固件或时序约束。

冻结 candidate 的结果：

```text
old RTL fresh warning 16788 = 2
fixed RTL fresh warning 16788 = 0
Quartus synthesis = Successful / 0 errors
0x12003C06: A43F -> A43F
0x12001C00: A43F -> 003F
exhaustive encodings = 16384 (legal 11328, reserved 5056)
```

## 合并 SHA 验证

- `make compile`、`sim-sv`、microbench（2411 cycles）和 86 条 encoder：PASS；
- M20K 同步时序：`BRAM_M20K_TIMING_TB PASS`；
- RX response trace：4/4 bridge/PoC/dmem PASS；
- vendor-timed JTAG-UART focused Icarus/Verilator：PASS；
- full-SoC CAL-OK/CAL-WAIT/CAL-FAIL：`SOC_B25_ALL_PASS`；
- boot image 保持 2011 bytes，BIN/MIF SHA 分别为
  `96f1b848...9ad79` / `e6de0c38...1eaff`；
- registry 88 项及 runner consistency：PASS。

Quartus EDA writer 已生成 post-map Verilog，但 GamePC/本机缺少兼容 simulator 与
`twentynm_lcell_comb` 模型，因此没有把 netlist 生成冒充为 post-map semantic PASS。
最终真板验证仍是该综合问题的决定性验收。

## 下一步与边界

下一步只对精确 candidate `c31b3aea` 运行 detached、release-mode Gate D。Gate D 通过后
再派生一行 no-FP profile，并从零运行 fresh synthesis/fitter/STA；不得复用 T-017 DB、
T-020 SOF 或 T-021 失败候选。随后才允许新 assembler 和已授权的易失板测。

本批次未运行 full physical fitter/STA、assembler、JTAG 或板卡，也没有 Flash/JIC/EPCQ、
reset/power 行为。精确命令、报告和 hash 见
[`T-20260920-022.json`](../tasks/evidence/T-20260920-022.json)。
