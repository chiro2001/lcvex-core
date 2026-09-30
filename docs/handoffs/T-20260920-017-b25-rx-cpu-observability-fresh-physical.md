# T-20260920-017：B25 RX CPU observability fresh physical 交接

```text
task=T-20260920-017 state=done
candidate=e91d20f15244e425fefaadeca8654fdfa1ebebc6
tree=0f4110efbb8fbbc4ea51c147f6ff89e6cb27e2c7
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-017-b25-rx-cpu-observability-fresh-physical
```

## 结论

T017 的 fresh no-FP RX observability physical flow 已完成：synthesis、fitter、STA、
overall/FIFO/data-delay 和 normalized UCP/reset 全部通过。该结论只覆盖报告绑定的
T017 candidate，不等价于 assembler、SOF、JTAG 或板级 bring-up。

## Fresh 输入与 Quartus

- boot.bin 2011 bytes；BIN/HEX/MIF hash 分别为
  `96f1b8484b30c33adac0a1562b897647a1f937cd4ac64539bad687538d19ad79`、
  `e6649fb2a0a162a2e2bc1d213a4c116d0769c853309ff859ac60739e050f0c8a`、
  `e6de0c384489e6a31dc519b20f41cbefa8f3145e0f14872ecf39a9df1e11eaff`；
- fresh stage 为 174 files，platform/support/RTL/root 分解 `50/29/47/48`，QSF refs=50；
- synthesis Successful/0 errors，235 warnings，约 7m10s，24 detected/16 maximum；
- fitter Successful/0 errors，12 warnings，74,710 ALM、80,745 registers、121 RAM、21 DSP、
  3 PLL；
- STA Successful/0 errors，2 warnings；`sys_clk_25` setup/hold/recovery/removal 为
  `+8.628/+0.017/+0.521/+0.170 ns`（signoff report summary 保留的 overall 代表值为
  setup `+8.628`、hold `+0.017`、recovery `+13.578`、removal `+0.153`，后者来自
  50-path signoff queries）。

PowerShell wrapper 的 blank `Process.ExitCode` 只影响早期 marker，不影响上述独立
Quartus report/summary：三个 stage 均由 `Successful/0 errors` 报告复核。

## Custom acceptance v3

v3 日志 marker 为 `T017_ACCEPTANCE_V3_PASS`：

- source pre/post manifest 完全一致，hash
  `1ce45a9e54266dfb09993b97a3e4132f15b05a4670f691e7a671eadb7dc45e19`；
- fitted clone baseline 与 source 一致；clone post 仅有 14 个允许的 Quartus/query 变化，
  `clone_bad_diff=0`；配置产物 `SOF/POF/JIC/RBF/JBC/SVF/JAM=0`；
- FIFO payload 为 6 families × 2 models = 24/24，全部 `Nothing to report`；
- CDC data-delay 为 4 corners × 5 routes = 20/20，0 violation，最差 slack `+1.250 ns`，
  datapath-only bound `2.000 ns`；
- overall query setup/hold/recovery/removal/min-pulse 为
  `+8.628/+0.017/+13.578/+0.153/+0.120 ns`，0 violation，exception/clock-constraint
  集合为空。

UCP/reset 使用 v2 exporter/checker 的独立 measurement profile。为保留冻结的 T-007
contract producer lineage，输入 summary 只在本地 analysis 目录生成了 header-normalized
派生副本；原始 T017 `t007_summary.tsv` 未改写。checker 结果为：

- normalized unconstrained input paths=60，TDI/TMS/TDO=`25/35/4`；
- reset normalized paths=624，family=`606/4/13/1`；raw 每份 634、duplicate 10；
- fast/slow recovery/removal 四份报告 0 violation，最差 recovery/removal=`+1.730/+0.206 ns`；
- `PHYSICAL_WAIVER_INVARIANT_CHECK_PASS`。

对应证据见 [`T-20260920-017.json`](../tasks/evidence/T-20260920-017.json)，本地生成的
inventory 为 `build/agents/T-20260920-017/analysis/t017-invariant-inventory.json`。

## 最终远端只读扫描与边界

最终 `gamepc` lock 内只读扫描通过：EDA=0，物理空闲 `42626.5 MiB`，D 盘剩余
`68188196864` bytes；目标 root 1331 files、output_files=26、acceptance-v3 runtime
659 files、配置 artifact=0。历史拼写错误旁支
`T-20260920-017-b25-rx-observability-fresh-physical` 存在但为空（0 files、0 config
artifact）。扫描后 `local FREE / gamepc FREE`。

全程未运行 assembler，未生成 SOF/POF/JIC/RBF/JBC/SVF/JAM，未执行 quartus_pgm、JTAG、
Flash/EPCQ、reset 或 power-cycle，也未停止未知进程。远端 root 和失败/成功现场均保留，
没有清理用户文件。

## 后续

T017 可作为 report-only no-FP physical candidate 集成。若继续板级工作，应另行登记并
使用用户已经授权的直接命令：

```powershell
D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe -c "JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]" -d 1 -i 0
```

该串口交互不应回写 T017 physical acceptance，也不应隐式触发配置、Flash、reset 或
power 动作。
