# T-20260906-035：R21 A10 physical verification 交接

```text
task=T-20260906-035 state=review
base=80b1f813de47a1223dd135117650419a0b6c05fc
head=70e090a4a64d5743dcb0d3734fb13094ffe2355f
branch=verify/T-20260906-035-r21-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-035
sent_at=2026-09-06T19:47:37+08:00 received_at=2026-09-06T19:49:00+08:00
reported_at=2026-09-07T03:04:15+08:00
files=docs/tasks/evidence/T-20260906-035.json,docs/handoffs/T-20260906-035-r21-quartus-physical.md,build/agents/T-20260906-035/**（ignored）,D:/Projects/fpga-altra/lcvex/build/T-20260906-035-r21-timing-probe
stages=synthesis -> fitter -> sta_signoff -> nonfatal custom reports
resource_lock=gamepc；四个重型阶段均加锁；busy_return_75=false；final=FREE
candidate/source=80b1f813de47a1223dd135117650419a0b6c05fc
blockers=sys_clk_50 setup 仍未闭合；新 global top-50 为 core idex_valid -> fp_rsp_hold.gpr_data/rsp_data_r
evidence=docs/tasks/evidence/T-20260906-035.json
```

## 结论

T-035 在精确 R21 candidate `80b1f813de47a1223dd135117650419a0b6c05fc` 上完成了一次
全新的 Arria 10 synthesis、fitter、signoff STA 和 non-fatal custom report。物理输入
与 R20 的差异仅为 `rtl/lcvex_fp_scalar.sv`；当前 worktree 比 candidate 多出的内容是
任务文档，RTL/FPGA 输入逐项无差异。

双 manifest 均为 52/52，formal manifest 的 RTL blob 逐项匹配 candidate Git；远端
manifest 52/52、递归 QSF closure 14 个直接 assignment/19 个 canonical 文件均通过。
Quartus 21.4 兼容副本只移除 `iter_kill`、`iter_pause`、`divider.kill`、`divider.pause`
四个默认端口值；formal source 保持原始 hash，未被兼容 patch 污染。

setup 仍为负，因此本轮是 timing observation，不是 closure 或 release 授权。R21 已
显著改善 R20 的主 setup 数值，原 `div_pre -> it_fin_mid` 与新增 FMA 两段均为正 slack；
但旧直接 `ap_pre -> pp_pre` 仍有 −0.271 ns 的残余方向性路径，新 global top-50 已转移
到 core `idex_valid -> fp_rsp_hold.gpr_data/rsp_data_r`。

## 时序结果

| 项目 | R20 | R21 | R21−R20 |
| --- | ---: | ---: | ---: |
| `sys_clk_50` Fmax | 45.15 MHz | 48.57 MHz | +3.42 MHz |
| setup WNS | −2.147 ns | −0.588 ns | +1.559 ns |
| setup TNS | −8417.158 ns | −67.238 ns | +8349.920 ns |
| setup failing endpoints | 10353 | 550 | −9803 |
| `sys_clk_50` hold WNS | 0.016 ns | 0.017 ns | +0.001 ns |
| `sys_clk_50` recovery WNS | 1.637 ns | 1.639 ns | +0.002 ns |
| `sys_clk_50` removal WNS | 0.151 ns | 0.193 ns | +0.042 ns |
| `sys_clk_50` minimum pulse WNS | 9.417 ns | 9.441 ns | +0.024 ns |

跨所有时钟的 worst-case 为 setup `−0.588 ns`、hold `+0.017 ns`、recovery `+0.406 ns`、
removal `+0.156 ns`、minimum-pulse `+0.120 ns`；DDR 与 metastability summary 均通过。

新 `sys_clk_50` top-50 为 50/50 violated，最差 `−0.588 ns`，25–26 logic levels：

- 41 条为 `core.idex_valid -> soc|core|fp_rsp_hold.gpr_data[]|fp_rsp_hold.gpr_data[]`，slack `−0.588..−0.529 ns`；
- 9 条为 `core.idex_valid -> soc|coh|i_l1|rsp_data_r[]`，slack `−0.566..−0.531 ns`。

## R21 目标锥

| 查询 | paths | violated | worst slack | logic levels | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| `div_pre -> it_fin_mid` | 50 | 0 | +4.290 ns | 18 | 原迭代 round-pack 第一段已为正 |
| `it_fin_mid -> pack_result` | 50 | 0 | +2.737 ns | 27–30 | 替代迭代 round-pack 锥已测量 |
| `it_fin_mid -> slot_result_r` | 0 | — | — | — | 明确 `no_timing_paths` |
| `ap_pre -> fma_align` | 50 | 0 | +2.553 ns | 22–23 | R21 新寄存边界 |
| `fma_align -> pp_pre` | 50 | 0 | +1.251 ns | 53–55 | R21 新 FMA 宽锥 |
| 旧直接 `ap_pre -> pp_pre` | 50 | 50 | −0.271 ns | 51–52 | 仍有残余 metadata/控制方向性路径 |
| `pack_mid -> pack_result` | 50 | 0 | +1.832 ns | 31–32 | R20 保留锥为正 |
| `pack_result -> slot_result_r` | 50 | 0 | +12.055 ns | 3–7 | 注册结果边界保持打开 |
| 旧 `pack_mid -> slot_result_r` | 0 | — | — | — | 明确 `no_timing_paths` |

补充的 core/accumulator 查询由 parser 完整核对：26 个报告、678 timing rows、13 个
directional clusters、12 个 0-path/expected-absence 报告；旧 TX_DONE、hold-valid D
pin 和无关写回路径均按结构化 terminal result 保存。

## 阶段和资源

- synthesis：`2026-09-06T20:06:46.9822131+08:00` 至 `2026-09-07T01:57:04.5445375+08:00`，`21017.562 s`，exit 0；peak private/working-set `11709.2/11064.2 MiB`，monitor 最低 free `25223.4 MiB`。
- fitter：`2155.303 s`，exit 0；peak private/working-set `11383.7/11121.6 MiB`，monitor 最低 free `19791.6 MiB`。
- signoff STA：`46.718 s`，exit 0；peak private/working-set `6690.9/6645.6 MiB`，monitor 最低 free `24339.7 MiB`。
- custom 四个 Tcl：总计 `133.22 s`，全部 exit 0；各脚本均有独立 monitor，post-stage guard 通过。
- 最终 postflight：EDA=0、禁止产物=0；D 盘剩余 `75430313984` bytes；资源锁最终 `local FREE / gamepc FREE`。

相对 R20 fitter 资源：ALM `159449 -> 164863`（`+5414/+3.3954%`），register
`96869 -> 98482`（`+1613/+1.6651%`）；RAM=121、DSP=186、PLL=3、pins=141，均无变化。

## 事件与边界

1. 初次 local identity 检查的 awk 正则过度转义，暂时打印 formal/platform `0/0`；
   没有被用作验收事实，随后独立 `count_check` 得到权威 `47/2`，manifest independent
   得到 `52/52`。
2. 一次 base64 `EncodedCommand` 的 QSF closure 调用在 Windows 命令行长度限制处失败，
   未执行 Quartus；改用已同步 `.ps1` 的 SSH `-File` 调用后 closure PASS。
3. 第一次 synthesis 入口因同步清单漏了 `run_synthesis.ps1` 在 PowerShell 入口处失败，
   Quartus 未启动；补同步入口后只运行一次成功 synthesis，没有重试已完成的物理阶段。
4. 第一次 parser 因下载清单漏了已生成的 `ap_pre_to_pp_pre` 报告而停在下载完整性检查；
   仅在 `gamepc` 锁下补取单个 artifact，未重跑 custom 或任何 Quartus 阶段。
5. 远端既有 `jtagserver` PID 5476 仅被 guard 观察，未停止、未连接、未进行 JTAG 或板级动作。

精确的失败现场、命令、时间、source/manifest/database/report hash、lock capture 和
parser 输出以 [`T-20260906-035.json`](../tasks/evidence/T-20260906-035.json) 为准；完整
log/数据库保留在 ignored `build/agents/T-20260906-035/` 和独立远端 probe，不进入 Git。

## 风险和下一步

`sys_clk_50` setup 尚未闭合；下一 timing batch 应基于新的 `idex_valid -> fp_rsp_hold`
及 `idex_valid -> rsp_data_r` top-N 重新聚类，不能把 R21 的正方向性 slack 当作全局
closure。继续保持 assembler、SOF/JIC/RBF/POF/JBC/SVF/JAM、`quartus_pgm`、JTAG、烧写、
上电和板测门关闭。
