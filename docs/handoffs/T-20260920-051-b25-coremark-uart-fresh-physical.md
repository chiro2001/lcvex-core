# T-20260920-051：UART 背压修复 payload fresh physical

```text
task=T-20260920-051 state=done
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
branch=verify/T-20260920-051-b25-coremark-uart-fresh-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-051
remote_root=D:/Projects/fpga-altra/lcvex/build/T-20260920-051-b25-coremark-uart-fresh-physical
started_at=2026-09-27T17:21:15+08:00
finished_at=2026-09-27T17:47:35+08:00
```

## 结论

已针对 T-049 新 MIF 从全新 GamePC root 完成 Quartus 21.4 synthesis、fitter、STA 及
report-only acceptance。preflight root 不存在、EDA=0、GamePC 可用内存约 31,253 MiB、
D: free 70,654,283,776 bytes。190 个 stage 文件、50 个 QSF 引用闭合，boot payload 精确
绑定到 MIF `0743295f...610a2f`。stage manifest SHA-256
`432efd72ba627cdcbce98209b5fe1bb11b9d83c218b684779245631ed3722fc6`，archive
`5eb4835d9419fd861dc5497ba9be3dae1ef8df4dbeb324668f9d23d9253d28e3`。

所有 physical stages 通过，source pre/post manifest 均为
`86ac31c6d40b4d2db41a2885cb32c50e481fa5c328d3352d0208da2ec608d865`，差异为 0。STA 和
report-only acceptance 的 timing 结果：

- `sys_clk_25` setup/hold/recovery/removal：`+9.398/+0.018/+13.596/+0.197 ns`；
- minimum pulse width：`+0.120 ns`；全局 worst setup/hold：`+0.320/+0.000 ns`；
- FIFO payload 24/24 `Nothing to report`；CDC data-delay 20/20 无 violation，最差
  `+1.184 ns`；
- normalized UCP input/output `60/4`，clock=2；normalized recovery/removal 均 624，
  family `606/4/13/1`，endpoint digest
  `8f7b6b7238c5fda2c9049c50bb105ebd613f6c341e694eade569d20221ff7efb`，worst slack
  `+1.101/+0.181 ns`。

Synthesis Warning 16788 按 T-028 source-qualified contract 通过：tracked RTL identity=0；
唯一生成的 SLD identity 为 `ir_in_2d[2][4]`，`syn.smsg` detail/`syn.rpt` summary
各一行；normalized SOPCINFO SHA-256 为
`b127700cfe079af2b01bfc5bcfea3926d2d97d7317d79cad943658d117ff532e`；无 suppression。
Quartus fitter 使用 16/24 processors。ALM 75,804，registers 80,789，RAM 121，DSP 21，
PLL 3。

## payload identity 与安全边界

独立 ELF-derived full 64 KiB image SHA-256 为
`aa43d0b7030d3bfc7d92b426c9d296b36428654b4cbf3e4c50300f3592ebf944`。BIN 20,448 bytes，
SHA-256 `241b0ce4dface8c4a9db782b63e4ada8674f5c8b51c00f228a795e98fc1aedab`；MIF
204,942 bytes，SHA-256 `0743295f90cb75e4d21092012c723bc9da4b6d055f13d46958cbd572bd610a2f`。

最终只读扫描 PASS：EDA process=0、SOF/JIC/POF/RBF/JBC/SVF/JAM=0、source pre/post hash
相等。没有运行 assembler、`quartus_pgm`、JTAG、terminal、板卡、Flash、reset 或 power。
T-048 观测到 GamePC FTDI device count=0，当前 live FPGA identity 仍未证明；此物理 flow
不依赖 FTDI，故可独立完成。

PowerShell `Start-Process.ExitCode` 在 synthesis wrapper 仍为空并打印 bookkeeping
`SYNTHESIS_FAIL`；同次 raw Quartus stdout、0-error report/summary、严格 warning/topology
audit 与后续完整 fit/STA 均证明 synthesis 成功，没有重跑。

Evidence JSON：[`docs/tasks/evidence/T-20260920-051.json`](../tasks/evidence/T-20260920-051.json)。
完整 ignored physical bundle：`build/agents/T-20260920-051/remote-collect/t051-physical-evidence.tar.gz`，
2,109,370 bytes，SHA-256 `d663d0677bf932eef3e9d481036ca8c43d9179ac341b8a90debec5350ca6914a`。
下一步 T-052 只从此 fresh fitted database clone 后调用一次 assembler。
