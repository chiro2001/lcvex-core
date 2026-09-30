# T-20260906-024：R19 A10 physical verification 交接

```text
task=T-20260906-024
state=physical-flow-complete-custom-directional-blocked
base=1c56632516c3d1e45c117d3a31dfa82faab9ecb8
head=见本提交
branch=verify/T-20260906-024-r19-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-024
sent_at=2026-09-06T10:53:54+08:00
received_at=2026-09-06T10:53:54+08:00
reported_at=2026-09-06T11:12:58+08:00
files=docs/tasks/evidence/T-20260906-024.json,docs/handoffs/T-20260906-024-r19-quartus-physical.md
evidence=docs/tasks/evidence/T-20260906-024.json
blockers=report_directional.tcl exit=29 at idex_valid_to_tx_done endpoint_missing; top50/backpressure/acc queries not reached
next=do not retry failed custom stage; register a follow-up directional/top50 query task after the missing endpoint contract is resolved
quartus_started=true
```

## 结论

R19 的本地 physical candidate 已准备完成，源 RTL 固定为
`1c56632516c3d1e45c117d3a31dfa82faab9ecb8`。formal 与 expected 两套 staging
均通过 52/52 manifest 闭合，分类为 formal RTL 47、平台 RTL 2、project 3。
生成的预定 probe 为：

`D:\Projects\fpga-altra\lcvex\build\T-20260906-024-r19-timing-probe`

续任后的唯一精确只读对账于 `2026-09-06T10:56:03.9421390+08:00` 完成：probe
存在，fitter 进程树为空，EDA 仅观察到既有 `jtagserver.exe PID 5476`，空闲物理内存
`37563.4 MiB`、CPU `28.0%`、D 盘空闲 `78774964224` bytes，forbidden artifact 为
0。对账 SSH exit=0，证据 hash 为
`74060771d610bd4187de71124e66c9c41d250d855bf38a98ba64faa59b36baf8`。

fitter 已自然结束且通过：`06:25:53.4151503 → 06:57:44.6678247`，exit=0，
safety-stop=false，timeout=false，peak private/working-set 为 `11091.9/10866.5 MiB`。
signoff STA 也已通过：`07:48:26.9784022 → 07:49:07.4347080`，exit=0，
safety-stop=false。上述运行及日志是续任前已产生并保留的远端 runtime 证据；本续任没有
重启 Quartus stage。

custom STA 按顺序完成 `report_top.tcl`、`report_emif.tcl`，随后
`report_directional.tcl` 因 `idex_valid_to_tx_done` 的目标寄存器数为 0 而 exit=29；
`report_sys_clk_50_top50.tcl` 未启动。按“不重试失败/safety-stop”规则没有重跑，任务状态
保持为带 blocker 的 physical observation，不能宣称 top-50 完整、timing closure 或
全部 directional acceptance。

## 已验证内容

- source tree `0426d7d99149df70576bb61dace185fb7605dec0`、RTL subtree
  `7b6e4c76ba8cb13edce467b8b1aa4d651ca912d2`、platform RTL subtree
  `d106699393497bea2abac5fee48e466372ce0c42` 已记录；当前 worktree 的
  `rtl/` 与 `fpga/` 相对 source SHA 无差异。
- `manifest_t024_formal_source.json` SHA256 为
  `a620ffeac089a80fe70349f914b1f79d8edf6c5021666931cdabf3f41e7759f6`；
  `manifest_t024_expected.json` SHA256 为
  `d0fec18c8f0c7572ddc4c0f3dde139a959236f73b73d0f7084b759a5d39a7fea`。
  两套树均独立复核为 count 52、missing 0、extra 0、bad 0。
- R18 `50b046b69341c13c4b93fffd89e5dda7d81590ff` 到 R19 的 physical-input
  差异严格为 `rtl/lcvex_core.sv` 与 `rtl/lcvex_fp_scalar.sv`；其它 RTL/FPGA
  输入未变化。
- Quartus 21.4 compatibility copy 独立于 formal source，仅移除已证明必要的
  `iter_kill`、`iter_pause`、`divider.kill`、`divider.pause` 四个默认端口值。
  formal SHA256 为 `9c821e3cfc60c031c803b3791989fe01532b681e91eef4d82a0f690ff8c693d0`，
  patched SHA256 为 `a49302fd042ddf62830b0861e737736d765a5144f0df28ef9da0f673c1573833`，
  diff 为 4 行删除/4 行新增。
- QSF 只做 31 个旧 T-008 probe-root 到 R19 probe-root 的可逆替换，QPF/SDC
  未改写。静态 QSF guard 检查 14 条直接外部 assignment；递归 closure catalog
  固定 19 个文件，远端 guard 已报告 `direct=14`、`canonical=19`、
  `missing=0`、`extra=0`、`QSF_EXTERNAL_EXISTENCE_AND_HASH=PASS`。修订后的
  catalog SHA256 为 `d8a09f8ef50ead357d70dae42c94393d12244d64db26f5adebc63dad87a62afb`，
  guard SHA256 为 `9e85ade130f054523404c3f6b5d6795be0fa7289deeee9bd89a57e42836a117b`。

## 远端阶段结果

- synthesis：`exit=0`，`00:39:00.2252898 → 06:24:58.8932596`，wall
  `20758.668 s`，peak private/working-set `11781.5/10990.5 MiB`，最终空闲
  `28300.9 MiB`，未 safety-stop。
- fitter：`quartus_sh.exe PID 47000`、`quartus_fit.exe PID 31456` 自然结束，
  `exit=0`，`06:25:53.4151503 → 06:57:44.6678247`，peak private/working-set
  `11091.9/10866.5 MiB`，最终空闲 `30800.7 MiB`，safety-stop=false、timeout=false，
  post-stage guard=PASS。
- signoff STA：`exit=0`，`07:48:26.9784022 → 07:49:07.4347080`，peak
  private/working-set `6574.6/6543.4 MiB`，最终空闲 `30322.7 MiB`，
  safety-stop=false、timeout=false，post-stage guard=PASS。
- custom STA：`report_top.tcl` 和 `report_emif.tcl` 均 exit=0；
  `report_directional.tcl` 于 `07:51:12.8714313` 在 `idex_valid_to_tx_done`
  endpoint_missing 处 exit=29，未启动 `report_sys_clk_50_top50.tcl`。
- 最终只读对账（`10:56:03.9421390`）：fitter root/tree=0，EDA 仅有既有
  `jtagserver.exe PID 5476`，free/total `37563.4/63092.3 MiB`、CPU `28.0%`、
  D 盘空闲 `78774964224 bytes`、forbidden artifact=0。

## 时序与资源

- `sys_clk_50` Fmax `44.24 MHz`；setup WNS/TNS/failing endpoints 为
  `-2.602 ns / -6949.587 ns / 7562`；hold/recovery/removal/min-pulse 为
  `0.015/1.675/0.188/9.403 ns`，setup 仍未闭合。
- 相对 R17/T-014：Fmax `+1.24 MHz`（`+2.884%`）、setup WNS `+0.654 ns`、TNS
  `+14786.630 ns`、failing endpoints `-10747`。
- Fitter resource：`159740/427200 ALM (37%)`、`96694` registers、`121/2713`
  RAM、`186/1518` DSP、`141/826` pins、`3/112` PLL；相对 R17 ALM `+801`
  (`+0.504%`)、registers `+1127` (`+1.179%`)，其余无变化。
- 全局 top-N 目前只有 signoff/custom 的 top-10：10/10 violated，最差 `-2.602 ns`，
  全部 61 logic levels，replacement cone 为 `g_iter.ap_pre → g_iter.pp_pre`。
  专用 top-50 Tcl 未运行，不能把 top-10 当 top-50。

## Directional 结果

`idex_valid → fp_exec.state.TX_DONE` 为 blocker（from=2、to=0、paths=0、
`endpoint_missing`）；core kill/control → TX_DONE、core backpressure →
`fp_rsp_hold_valid` D、以及 acc/acc_flags 查询均未到达。已取得的结果为：old
`pp_pre→pack_mid`/`pp_pre→pack_pre` 均 0 paths；`pp_pre→pack_scan` 50 paths、0
violated、worst `7.972 ns`；`pack_scan→pack_pre` 50/0、`14.823 ns`；
`pack_pre→pack_mid` 50/0、`3.146 ns`；`pack_mid→slot_result_r` 50 paths、26
violated、`-0.280 ns`。EMIF 为 24 clocks、552 pairs、6 pairs with paths、300
reported paths，`emif→sys=0`、`sys→emif=0`。

所有板级动作仍由用户许可门控。

精确命令、阶段结果、文件清单、hash、未执行项和风险见
[`T-20260906-024.json`](../tasks/evidence/T-20260906-024.json)。准备 hash 清单为
`build/agents/T-20260906-024/evidence/prep_artifact_hashes.txt`（144 项，SHA256
`b00bf86a64f05f7c3b041af86cd96e1c3a882324febd97c73baef21e1397698d`）。本次续任对账证据为
`build/agents/T-20260906-024/runtime/status_reconcile.resume.stdout`，SHA256
`74060771d610bd4187de71124e66c9c41d250d855bf38a98ba64faa59b36baf8`；远端 fit/STA
及方向报告的 artifact hash 也集中记录在 evidence JSON。

## 风险与边界

当前 R19 setup 仍为负值，且 custom directional 在 `TX_DONE` endpoint_missing
处 exit=29，故 top-50、backpressure、acc 方向仍未测量；不要重试该失败 stage。T-020
worktree 与远端 probe 没有被操作；assembler、SOF/JIC/RBF/POF/JBC/SVF/JAM、
programming/JTAG、上电和板测均禁止。没有终止 VRChat/SteamVR 等无关进程，也没有修改
RTL、QSF/SDC timing exception 或参考结果。
