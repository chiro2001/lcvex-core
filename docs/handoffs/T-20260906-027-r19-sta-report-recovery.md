# T-20260906-027：R19 STA report recovery 交接

```text
task=T-20260906-027
state=review
base=86945e1b38ef550c3de260e3efca915fc5d9e353
head=见本提交
branch=verify/T-20260906-027-r19-report-recovery
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-027
sent_at=2026-09-06T11:16:33+08:00
received_at=2026-09-06T11:16:33+08:00
reported_at=2026-09-06T11:47:40+08:00
files=docs/tasks/evidence/T-20260906-027.json,docs/handoffs/T-20260906-027-r19-sta-report-recovery.md,build/agents/T-20260906-027/**（ignored scripts/logs/reports）及远端 T-024 probe 下 t027_* report-only artifacts
evidence=docs/tasks/evidence/T-20260906-027.json
blockers=fp_rsp_hold_valid D pin 四种命名均无匹配；sys_clk_50 setup 仍为负，不构成 closure
next=以 ap_pre→pp_pre 与 pack_mid→slot_result_r 作为下一 timing batch 候选；先确认 hold-valid D 的 fitted pin 可观测命名
```

## 结论

T-024 的 R19 final fitted database 已成功复用。T-027 仅启动一次由共享
`gamepc` 锁保护的 `quartus_sta -t t027_report_recovery.tcl` report-only stage，未重跑
synthesis、fitter 或 signoff STA。wrapper exit=0，Quartus monitor 运行
`27.135 s`，峰值 private/working-set 为 `6367.1/6276.6 MiB`，
`safety_stopped=false`、`timeout=false`。远端 post-report guard 为 EDA=0、
forbidden artifact=0。

资源命令、精确时间、退出码、资源峰值、输入数据库 hash 和全部 artifact hash 见
[`T-20260906-027.json`](../tasks/evidence/T-20260906-027.json)。解析器输出
`build/agents/T-20260906-027/runtime/t027_reports_parsed.json`（SHA256
`fefa2d81644e93051fcb092f3d636110712860bf11cb04ac5d3b77ab836c3328`），报告 hash
清单为 `build/agents/T-20260906-027/runtime/t027_report_artifact_hashes.txt`
（33 entries，SHA256 `cb07f8164f2d4832c3baa01201d32815ab56b35dfdd1b791cefd0e504c71bc63`）。

## Top-50 与聚类

`sys_clk_50` setup 恰好收集 50/50 条路径，50 条均 violated，worst slack
`-2.602 ns`，best `-2.499 ns`；每行均有 startpoint、endpoint、slack 和
`Number of Logic Levels`（61 或 62）。唯一主簇为：

```text
fp_exec.scalar_unit.g_iter.ap_pre -> fp_exec.scalar_unit.g_iter.pp_pre
count=50, violated=50, worst=-2.602 ns, logic_levels={61,62}
```

## Directional 结果

所有请求均在同一 Tcl invocation 内到达终态；标准 timing reports 由本地 parser 独立
解析，结构化 0-path report 也独立校验。

| 查询 | from/to registers | paths | 结果 | worst slack / levels |
| --- | ---: | ---: | --- | --- |
| `ap_pre -> pp_pre` | 2322 / 941 | 50 | pass | -2.602 ns / 61–62 |
| `pp_pre -> pack_scan` | 941 / 1004 | 50 | pass | 7.972 ns / 11 |
| `pack_scan -> pack_pre` | 1004 / 1231 | 50 | pass | 14.823 ns / 0,2–6 |
| `pack_pre -> pack_mid` | 1231 / 1221 | 50 | pass | 3.146 ns / 16 |
| `pack_mid -> slot_result_r` | 1221 / 64 | 50 | 26 violated | -0.280 ns / 40–41 |
| `slot_result_r -> acc` | 64 / 128 | 50 | pass | 10.101 ns / 2–3 |
| `exmem_valid -> acc` | 2 / 128 | 50 | pass | 5.728 ns / 16 |
| `exmem_valid -> acc_flags` | 2 / 7 | 28 | pass | 6.478 ns / 15–16 |

十个零路径/缺失结果均有独立结构化文件：

- `idex_valid -> TX_DONE`：`from=2`、`to=0`、`paths=0`，标记
  `expected_absence_removed_tx_done`；该缺失不会终止后续查询。
- `core_kill_control -> TX_DONE`、`core_sys_commit_ready -> TX_DONE`、
  `core_sys_commit -> TX_DONE`：均显式标记同一 removed-TX_DONE expected absence。
- `core backpressure -> fp_rsp_hold_valid D`：四种 fitted pin spelling 均为 0，
  显式标记 `fp_rsp_hold_valid_D_pin_missing`；没有把 Q register 冒充 D pin。
- `slot_result_r -> acc_flags`、`memwb_wb_rd -> acc/acc_flags`、
  `exmem_wb_rd -> acc/acc_flags`：register collections 存在但 timing paths=0，
  均显式标记 `no_timing_paths`。

## 输入、guard 与边界

- 远端 probe：`D:\Projects\fpga-altra\lcvex\build\T-20260906-024-r19-timing-probe`；
  host=`192.168.101.5` / `GAMEPC`，device=`10AX115N4F40E3SG`，Quartus=`21.4.0 Build 67`。
- QPF/QSF/SDC 以及 `report.fit.rdb`、`report.sta.rdb`、final
  `timing_netlist.tdb` 的 pre/post SHA 全部相同；远端 fitted DB 未被 synthesis/fitter
  改写。
- remote pre/post EDA count 均为 0；仅观察到既有 `jtagserver.exe PID 5476`，未终止。
- 未修改 active task JSON、RTL、QEMU、QSF/SDC 或里程碑；未运行 assembler、bitstream、
  `quartus_pgm`、JTAG、烧写、上电或板测；未重试该 report stage。

## 后续建议

下一 timing batch 以 `ap_pre -> pp_pre`（top-50 唯一主锥，worst `-2.602 ns`）和
`pack_mid -> slot_result_r`（50 条中 26 条 violated，worst `-0.280 ns`）排序。当前
`sys_clk_50` setup 仍 negative，只能作为 timing observation；确认 fitted netlist 中
`fp_rsp_hold_valid` 的 D-pin 正确对象后，才可决定是否新增独立方向性查询。保持
assembler/板级门关闭。
