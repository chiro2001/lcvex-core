# T-20260906-031：R20 A10 physical verification 交接

```text
task=T-20260906-031
state=review
base=1e244d2a733d53ceeaa8267754fd1672fe81c171
head=见本提交（证据提交前 HEAD 为 1e244d2a）
branch=verify/T-20260906-031-r20-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-031
sent_at=2026-09-06T13:09:06+08:00
received_at=2026-09-06T13:09:06+08:00
reported_at=2026-09-06T18:51:51+08:00
files=docs/tasks/evidence/T-20260906-031.json,docs/handoffs/T-20260906-031-r20-quartus-physical.md,build/agents/T-20260906-031/**（ignored prep/runtime）,D:/Projects/fpga-altra/lcvex/build/T-20260906-031-r20-timing-probe
stages=synthesis -> fitter -> sta_signoff -> nonfatal custom reports
resource_lock=gamepc；四阶段均 resource-lock；busy_return_75=false；final=FREE
blockers=sys_clk_50 setup 未闭合；新 top-50 为 div_pre_hi -> it_fin_mid_hi
next=以 div_pre_hi -> it_fin_mid_hi 新 top-N 规划下一 timing batch；保持 assembler/SOF/JTAG/上电门关闭
evidence=docs/tasks/evidence/T-20260906-031.json
```

## 结论

R20 candidate 固定为 `12eb36fb8e1b10382d67a7b8a87f160e27c4fc98`，R19→R20 physical
输入差异严格只有 `rtl/lcvex_fp_scalar.sv`。T-024 模板的 52-file payload、formal/
expected 双 manifest 和递归 QSF closure 均通过；Quartus 21.4 compatibility copy
只移除既有 `iter_kill`、`iter_pause`、`divider.kill`、`divider.pause` 四个默认端口
值。远端新 probe 为：

`D:\Projects\fpga-altra\lcvex\build\T-20260906-031-r20-timing-probe`

在 GamePC 上按 synthesis、fitter、signoff STA、custom 的顺序自然完成。custom
采用 T-027 non-fatal 方式：缺失端点、0 path 和无 D pin 均写入结构化终态并继续后续
查询。没有重试 Quartus 阶段，没有修改 active JSON、RTL、QSF/SDC 或 QEMU。

## 时序结果

| 项目 | R20 | R20−R19 |
| --- | ---: | ---: |
| `sys_clk_50` Fmax | 45.15 MHz | +0.91 MHz |
| setup WNS / TNS / failing endpoints | −2.147 ns / −8417.158 ns / 10353 | +0.455 ns / −1467.571 ns / +2791 |
| hold WNS | 0.016 ns | +0.001 ns |
| recovery WNS | 1.637 ns | −0.038 ns |
| removal WNS | 0.151 ns | −0.037 ns |
| minimum-pulse WNS (`sys_clk_50`) | 9.417 ns | +0.014 ns |

global `sys_clk_50` top-50 为 50/50 violated，最差 `−2.147 ns`，57–60 logic
levels；唯一主导族是 `g_iter.div_pre_hi -> g_iter.it_fin_mid_hi`（discarded 39
条、mant 11 条）。R19 的 global `ap_pre -> pp_pre`（−2.602 ns）已离开 global
top-50，但该替代锥的专用方向性查询仍为 50/50 violated、最差 `−1.944 ns`。
setup 仍为负值，因此这是 timing observation，不是 closure 或 release 授权。

## R20 目标锥与显式空结果

| 查询 | paths | violated | worst slack | 结果 |
| --- | ---: | ---: | ---: | --- |
| `ap_pre -> pp_pre` | 50 | 50 | −1.944 ns | measured |
| `pp_pre -> pack_scan` | 50 | 0 | 6.843 ns | measured |
| `pack_scan -> pack_pre` | 50 | 0 | 15.024 ns | measured |
| `pack_pre -> pack_mid` | 50 | 0 | 3.019 ns | measured |
| `pack_mid -> pack_result*` | 50 | 0 | 0.185 ns | registered boundary open |
| `pack_result* -> slot_result_r` | 50 | 0 | 13.286 ns | registered boundary open |
| old `pack_mid -> slot_result_r` | 0 | — | — | explicit `no_timing_paths` |
| `slot_result_r -> acc` | 50 | 0 | 11.940 ns | measured |
| `exmem_valid -> acc` | 50 | 0 | 5.612 ns | measured |
| `exmem_valid -> acc_flags` | 32 | 0 | 7.113 ns | measured |

另有 11 个显式 0-path/expected-absence 结果，包含旧 `TX_DONE`（`idex_valid`、kill、
commit/ready）、`fp_rsp_hold_valid` D pin 缺失、`slot_result -> acc_flags` 以及
`memwb/exmem wb_rd -> acc/acc_flags`。它们均由 non-fatal Tcl 写出并由独立 parser
校验，没有把 Q register 冒充 D pin。

## 阶段与证据

- synthesis：`15877.493 s`，peak private/working-set `11262.2/10576.6 MiB`，
  exit 0，safety-stop/timeout=false。
- fitter：`1773.496 s`，peak `11226.7/11033.1 MiB`，exit 0，safety-stop/timeout=false。
- signoff STA：`44.279 s`，peak `6532.9/6498.6 MiB`，exit 0，safety-stop/timeout=false。
- custom 四个 Tcl：各约 `27.5 s`，总计 `110.045 s`，均 exit 0；postflight
  EDA=0、forbidden artifact=0。
- fitter resource：ALM `159449/427200 (37%)`、register `96869`、RAM `121`、
  DSP `186`、PLL `3`、pins `141`；相对 R19 ALM `−291`、register `+175`，其余
  资源不变。

精确命令、source/manifest/QSF/DB/report hash、远端 610 项 custom report hash
清单、阶段 lock capture 和 parser 输出均在
[`T-20260906-031.json`](../tasks/evidence/T-20260906-031.json)。独立报告解析为
21 个主报告、482 timing rows、9 个 directional clusters；top-50 严格 parser 与
non-fatal parser 均通过。完整日志/数据库留在 `build/agents/T-20260906-031/` ignored
现场，不纳入 Git。

## 风险和下一步

`sys_clk_50` setup 的 TNS 和 failing endpoints 相对 R19 变差，且新主热点转移到
`div_pre_hi -> it_fin_mid_hi`；下一 timing batch 应先分析该锥。保持
assembler、SOF/JIC/RBF/POF/JBC/SVF/JAM、`quartus_pgm`、JTAG、烧写、上电和板测
全部关闭，不修改本次 QSF/SDC 例外。
