# T-20260920-027：B25 logical-immediate repair fresh physical 交接

```text
task=T-20260920-027 state=done-with-acceptance-blocker
candidate=2a1cd5c59fc27f0a6d947c58f5b24b194d4dd13b
tree=e5e94ab175f6847d727901576a8f12958efc1100
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-027-b25-logic-imm-repair-fresh-physical
```

## 结论

T-027 已从不存在的 task-owned GamePC root 完成 174-file/50-QSF fresh stage，执行了
Quartus 21.4 synthesis、fitter、STA、overall、FIFO payload、data-delay 和 raw
UCP/reset report-only measurement。fitter、STA、custom timing 和 normalized UCP/reset
均通过；但 synthesis 仍有一个未过滤的 warning 16788，因此不能宣称 T-027 完整验收通过。

唯一 warning 位于 Quartus 生成的 SLD JTAG hub：

```text
Warning (16788): Net "ir_in_2d[2][4]" does not have a driver
alt_sld_fab_0_altera_sld_jtag_hub_1920_oerl7dy.vhd(243)
```

它不是 `lcvex_decode.sv` 的 logical-immediate warning；`lcvex_decode.sv` SHA 为
`5e92ee65a817a55a7dc14f7cdb5066dc3f82510fc794a6aea129fb45b87da1df`。任务要求 warning
16788 必须为零，故该项明确标记为 acceptance blocker；全程没有过滤、waive、message
suppression 或修改 vendor-generated source。

## Fresh 输入与物理结果

- profile/tree：`2a1cd5c5` / `e5e94ab1`；boot.bin 2011 bytes；BIN/HEX/MIF SHA 分别为
  `96f1b848...9ad79`、`e6649fb2...f0c8a`、`e6de0c38...1eaff`；
- stage manifest/archive SHA 分别为
  `ad7643fd...d1e4f` / `ccf37034...b9bd8d2`；174 files、50 QSF refs；
- synthesis：Successful/0 errors，234 warnings，warning 16788=1；Quartus 使用
  16/24 processors；
- fitter：Successful/0 errors；75,818 ALM、80,743 registers、121 RAM、21 DSP、3 PLL；
- STA：Successful/0 errors；`sys_clk_25` setup/hold/recovery/removal 为
  `+7.481/+0.017/+13.549/+0.178 ns`，minimum pulse `+0.120 ns`，0 violations；
- FIFO payload：24/24 report，全部 `Nothing to report`；
- data-delay：4 corners × 5 routes = 20/20，0 violations，最差 slack `+1.020 ns`；
- source pre/post manifest：均为
  `4bfb8f25201c467f01ac3a5b3725cc847908b869f78d1dbaea19e0e8f6fc1f06`；
- final scan：1328 files、output_files=26、acceptance-v3=659、config artifact=0、EDA=0。

## UCP/reset 归一化测量

raw report 没有被改写。raw 数量为 input paths `61`、reset recovery/removal `638/638`；
按既有 invariant normalization 规则，TDI duplicate=1，reset duplicate=`14/14`，得到
normalized UCP input paths `60`、normalized reset paths `624`，family=`606/4/13/1`，
recovery/removal `+1.388/+0.238 ns`，violations=0。normalized endpoint digest 与
现有 policy 完全一致：

```text
UCP TDI  fb9f5c0375f8098a5cc19d745e9ad02fb7f24685fb04eff674ea3b44247fac28
UCP TMS  c0d76e9d19fef125943068a108c2d3697c98a0362bdf7811f84993067ba91006
UCP TDO  9d5f27730dc9ec2754c7fb79b41bb4cc4e492152001c1e22e5f3acab92210c99
reset    8f7b6b7238c5fda2c9049c50bb105ebd613f6c341e694eade569d20221ff7efb
```

T-027 没有修改 tracked invariant policy/exporter，也没有把该 profile 加入 production
whitelist；完整 report-only measurement 保存在 task-local ignored analysis 目录，摘要
见 [`T-20260920-027.json`](../tasks/evidence/T-20260920-027.json)。

## 安全边界与后续

所有 GamePC 动作持有 `gamepc` 锁；未运行 assembler，没有生成 SOF/POF/JIC/RBF/JBC/SVF/JAM，
没有 JTAG/板卡配置、Flash/EPCQ、reset、power-cycle，也没有停止未知进程。后续若要使
T-027 成为可接受 physical candidate，需单独处理 vendor SLD warning 的合法 RTL/QSF
根因并重新建立 fresh physical root；不得通过 waiver/filter 伪造零 warning。
