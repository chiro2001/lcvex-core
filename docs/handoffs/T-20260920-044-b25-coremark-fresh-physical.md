# T-20260920-044：B25 microbench/CoreMark fresh physical 交接

```text
task=T-20260920-044 state=done
candidate=f6633e70dd4d6b2f9a6aa932daee7c7e8252ac8d
candidate_tree=49fab30e4d8d49a5af24a81a49d8cf95f2cded8c
branch=verify/T-20260920-044-b25-coremark-fresh-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-044
remote_root=D:/Projects/fpga-altra/lcvex/build/T-20260920-044-b25-coremark-fresh-physical
started_at=2026-09-21T00:18:25+08:00
finished_at=2026-09-21T00:42:34+08:00
```

## 结论

冻结的 T-042/T-043 microbench/CoreMark 候选已完成一次全新的 Quartus 21.4
`synthesis -> fitter -> STA -> report-only acceptance`，T-044 验收通过。整个远端流程由
一个 `gamepc` resource-lock 窗口包围；fresh root 预先不存在，EDA process=0，190 个
stage 文件和 50 个 QSF 引用均闭合，source pre/post manifest 完全相同。

payload 没有重建或替换：`boot.bin` 为 20,448 bytes、SHA-256
`ddb27ff2ffdfb595c3821a20af262f4e3ae95c1e680bf5530e2865bf45b6c56d`；
`boot.mif` SHA-256 为
`d56386b0714c65bab955cb91112d510b31f4290f80281f86c7feabdd6988d7d0`，解码后的完整
64 KiB BRAM image SHA-256 为
`1e691cc06094746464633929b2dea25be43c96305873bedfca82d3978c87ddb9`。

## Physical 与 warning 合同

- synthesis、fitter 和 STA 都是 Successful/0 errors；synthesis 自身耗时 `00:05:49`，
  完整 shell 阶段耗时 `00:07:09`，fitter 约 13.6 分钟；fitter/STA 报告确认使用
  24 个逻辑处理器中的 16 个；
- 25 MHz `sys_clk_25` setup/hold/recovery/removal 为
  `+9.398/+0.018/+13.596/+0.197 ns`，minimum pulse 为 `+0.120 ns`；全局最差
  setup/hold 为 `+0.320/+0.000 ns`，没有负 slack；
- FIFO payload 24/24 报告均为 `Nothing to report`；20 个 CDC data-delay 组均无
  violation，最差 slack `+1.184 ns`；
- normalized UCP input/output 为 `60/4`，clocks=2；四组 recovery/removal 的
  normalized reset 均为 624，family 为 `606/4/13/1`，endpoint digest 为
  `8f7b6b7238c5fda2c9049c50bb105ebd613f6c341e694eade569d20221ff7efb`，最差
  recovery/removal 为 `+1.101/+0.181 ns`；
- T-028 source-qualified Warning 16788 合同严格通过：tracked RTL identity=0；唯一
  generated SLD identity 为 `ir_in_2d[2][4]` / generated VHDL line 243，raw 形式恰好
  `syn.smsg` detail 一行和 `syn.rpt` summary 一行；canonical hpath 存在；normalized
  SLD topology SHA-256 为
  `b127700cfe079af2b01bfc5bcfea3926d2d97d7317d79cad943658d117ff532e`；没有
  QSF suppression、filter 或 waiver。

资源占用为 75,804 ALM、80,789 registers、121 RAM blocks、21 DSP、3 PLL。

## 安全边界与注意事项

最终只读扫描为 `T044_FINAL_READONLY_SCAN_PASS`：EDA process=0、配置产物=0、
source manifest pre/post SHA-256 均为
`533cb35732b27220a06e47f4fc5383f402cbbb4d9526f9cb2490110e15ea1f40`。本任务没有
运行 assembler，没有生成 SOF/JIC/POF/RBF/JBC/SVF/JAM，没有访问 JTAG、板卡、Flash，
也没有 reset/power 或停止未知进程。live FPGA 因此仍保持此前证明的 exact golden。

PowerShell `Start-Process.ExitCode` 在 synthesis wrapper 中仍返回空值，wrapper 因而打印
了一条 bookkeeping `SYNTHESIS_FAIL`；没有重跑 synthesis。独立 raw stdout、syn report、
summary、零 EDA 进程、T-028 warning/topology 审计以及后续 fitted DB 全部证明该阶段实际
成功。这一历史兼容性问题不会被用作成功证据，权威结果是独立 audit。

完整结构化证据见
[`docs/tasks/evidence/T-20260920-044.json`](../tasks/evidence/T-20260920-044.json)。
task-owned ignored 证据包位于
`build/agents/T-20260920-044/remote-collect/t044-physical-evidence.tar.gz`，2,109,090 bytes，
SHA-256 `b903493e1fdbad6891658d6576b93f4018336e1d0f9b8bf422d37adfee925f28`。
下一步只允许 T-045 从该已验收 remote fitted root 建立独立 clone，并调用一次 assembler
生成唯一 volatile SOF。
