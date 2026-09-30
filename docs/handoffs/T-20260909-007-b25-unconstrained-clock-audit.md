# T-20260909-007：B25 unconstrained clock audit 交接

```text
task=T-20260909-007
state=review
base=2a10d23740e67850cdae7e91fd834c53c7746cac
source_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
head=2a10d23740e67850cdae7e91fd834c53c7746cac (source tree unchanged)
branch=verify/T-20260909-007-b25-unconstrained-clock-audit
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-007
sent_at=2026-09-09T10:35:01+08:00
received_at=2026-09-09T10:35:01+08:00
reported_at=2026-09-09T12:32:40+08:00
files=docs/tasks/evidence/T-20260909-007.json,docs/handoffs/T-20260909-007-b25-unconstrained-clock-audit.md,build/agents/T-007/**（ignored report-only artifacts）
evidence=docs/tasks/evidence/T-20260909-007.json
blockers=两个 vendor-generated unconstrained clock targets 仍需正式 waiver 或 vendor SDC classification；不能用任意 JTAG cable 频率 create_clock
next=由集成者审核 waiver ownership；若接受 waiver，保持 recovery/removal 与 UCP post-fit checker 作为 Gate D 物理前置
```

## 结论

本任务只读复用了 T-002 的 frozen fitted database：

```text
probe=D:\Projects\fpga-altra\lcvex\build\T-20260909-002-b25-physical
project=D:\Projects\fpga-altra\lcvex\build\T-20260909-002-b25-physical\fpga\catapult_a10\quartus
runtime=D:\Projects\fpga-altra\lcvex\build\T-20260909-002-b25-physical\runtime\T-20260909-007
quartus=Quartus Prime Pro 21.4.0 Build 67
```

最终 report-only `quartus_sta` exit=0，0 errors/4 warnings；4 个 warning 是 fast/slow
各一次的 `altera_reserved_tck` 和 `soc|emif_adapter|emif_rst_sync1_n` 无关联时钟
诊断。加载 Qsys 自动生成的 EMIF/JTAG/reset SDC 后，fast 和 slow 的 UCP 结果一致：

| 项目 | Setup | Hold |
| --- | ---: | ---: |
| Illegal clocks | 0 | 0 |
| Unconstrained clocks | 2 | 2 |
| Unconstrained input ports | 2 | 2 |
| Unconstrained input-port paths | 63 | 63 |
| Unconstrained output ports | 1 | 1 |
| Unconstrained output-port paths | 4 | 4 |

两个 clock target 精确为 `altera_reserved_tck` 和
`soc|emif_adapter|emif_rst_sync1_n`；两个 input port 是
`altera_reserved_tdi`/`altera_reserved_tms`，output 是
`altera_reserved_tdo`。端口 fanout/fanin 查询为 TDI=26、TMS=37、TDO fanin=4，
与 63/4 条 UCP 路径闭合。TDI 路径按 fitted hierarchy 分为
alt_jtag_atlantic=7、auto_fab/SLD=11、EMIF embedded JTAG=7、TDO 回环=1；TMS
全部 37 条落在 auto_fab/SLD fabric；TDO 四条来源是三个 auto_fab JTAG register 和
`altera_reserved_tdi`。

`altera_reserved_tck` 是 fitted port node，`get_clocks` count=0，fanout edge count=1，
指向 `altera_reserved_tck~input`。TimeQuest 警告中唯一代表性使用者是
`emif|emif_bot|emif_bot|col_if|colmaster|jtag_phy_embedded_in_jtag_master|normal.jtag_dc_streaming|sink_crosser|output_stage|data1[0]`。
这属于 Intel SLD/EMIF/JTAG debug fabric，不是 LCVEX 功能时钟。

`soc|emif_adapter|emif_rst_sync1_n` 是 fitted `reg` node，`get_clocks` count=0，
fanout edge count=1 且 edge type=asynchronous；输入 edge 是该寄存器的 `clrn`。
TimeQuest 将 `soc|emif_adapter|emif_state_q.EMIF_IDLE~1` 报作由该 node clocked，
这是 async-control 的时序模型表现。以该 reset stage 的 register collection 为
source、adapter register collection（5462 个）为 target，fast/slow 各得到 627 条
recovery 与 627 条 removal，均 0 violated：

```text
recovery worst slack = 1.202 ns (Slow 900mV 100C Model)
removal  worst slack = 0.191 ns (Fast 900mV 0C Model)
launch/latch clock   = emif|emif_bot|emif_bot_core_usr_clk, 3.750 ns
```

RTL 对应关系为 `rtl/lcvex_axi4_avalon_adapter.sv:248-255` 的两级 EMIF reset
synchronizer，`:289-290` 将 stage-2 暴露为 `emif_fsm_rst_n`，`:1029-1036` 以
`negedge emif_fsm_rst_n` 作本地 async assertion、同步释放后的状态机 reset。
因此没有证据要求 RTL 修复；该目标应按 synchronized active-low reset control 处理，
保留 recovery/removal 复核。

## 约束 ownership 与建议

- `fpga/catapult_a10/quartus/catapult_a10.qsf:61` 引入 `../flash/sfl/sfl_sys.qip`；
  `:71-72` 显式引入两个 generated JTAG-UART Verilog 文件。
- `fpga/catapult_a10/jtag_uart/jtag_uart_std_altera_avalon_jtag_uart_1910_zesttkq.v:556-574`
  通过 `synthesis read_comments_as_HDL` 实例化 `alt_jtag_atlantic`（instance ID 0），
  是 reserved TCK/TDI/TMS/TDO 的生成源；fitted UCP 还显示 auto_fab SLD fabric 与
  EMIF embedded JTAG consumer。
- 远端只读加载了四个生成 SDC：EMIF arch（SHA
  `32bf047be0124781fbc84be6d7a1384ef4df8318ef5de316ea7ede10560b4274`）、JTAG DC
  streaming（`50c01997a1d3e9171e132bf2cffa6e2aed46784c5cf7e93574321d9d6683cf12`）和
  两个 reset-controller（各 `901e9f96d7e8449813ec8f5d5bab823e64c32e49653e3a8c78c35bbdb1485c70`）。
  它们负责 EMIF generated clocks/厂商边界；没有给 `altera_reserved_tck` 指定固定
  周期。
- `fpga/catapult_a10/quartus/catapult_a10.sdc:1-14` 只拥有 clk_u59=100 MHz、
  sys_clk_25=25 MHz/40 ns、clk_y3=266.667 MHz 与 LED false path，未声明 reserved
  JTAG clock 或 port delay，也未把 reset control 当作周期 clock。

建议接受两个明确的、对象受限的 vendor waiver：

1. `altera_reserved_tck`、`altera_reserved_tdi`、`altera_reserved_tms`、
   `altera_reserved_tdo` 以及其 `jtag_uart_inst|...|*alt_jtag_atlantic|*`、
   `auto_fab_0|alt_sld_fab_0|*`、
   `emif|emif_bot|*jtag_phy_embedded_in_jtag_master*` hierarchy。TCK 由 cable 在
   运行时驱动，不能用任意 15/30 MHz 等 cable 观察值 create_clock。若 Intel 提供
   专用约束，应由该生成 package 维护；否则 waiver 必须保存上述 UCP counts 和
   hierarchy，复跑后证明不存在 user functional path。
2. `soc|emif_adapter|emif_rst_sync1_n` 及其 `emif_state_q.*`/`emif_req_q.*`
   recovery/removal sinks。它不是 clock；可用窄 vendor/TimeQuest reset-control
   classification waiver，或由 vendor package 提供等效标注。不得为它添加周期、
   `create_clock` 或通过 false path 隐藏 recovery/removal；627/627、0 violation 的
   检查必须保留。

## 输入、验证与安全边界

fitted 输入 pre/post hash 完全相等：QPF `38ac01ac...4ec1dd`，remote normalized QSF
`1deb0042...5bfa46`（candidate raw QSF `3e0ef899...171c5fe`，normalized bytes 相等），
SDC `b16247b7...ac078f`，fit/STA summary `176f857f...51d600`/
`e1c97995...157246`，`report.fit.rdb` `665b7e78...995f9e4`，`report.sta.rdb`
`99c94c64...91704a`，final timing netlist `4ae224b6...797dcda`，chip CDB
`69b45acf...c554e6`。完整 hash 与报告 hash 见
[`T-20260909-007.json`](../tasks/evidence/T-20260909-007.json)。

最终本地解析命令为：

```text
python3 -m py_compile build/agents/T-007/analysis/t007_parse_reports.py
python3 build/agents/T-007/analysis/t007_parse_reports.py > build/agents/T-007/analysis/t007_parsed.json
/home/chiro/projects/.resource-locks/resource-lock status all
```

解析 artifact 为 `build/agents/T-007/analysis/t007_parsed.json`（SHA256
`91a918b3aed6443fc5d6ea333914b0f10f1382c0df314c840233c1d90d9a4c4b`）；完整 314-entry
hash 清单为 `build/agents/T-007/analysis/t007_artifact_hashes.txt`（SHA256
`9390341fdbe6e3eb92903e7d08a1098dd15f7fd57f0850de27e0b123513b4b40`）。

远端最终 postflight（仍在 gamepc lock 内）为：EDA process=0，既有 jtagserver PID 5688
仅观察、不停止；T-007 runtime forbidden extension=0，project `output_files` forbidden
extension=0，runtime files=47，output_files files=13。没有运行 synthesis、fitter、
signoff STA flow、assembler、bitstream、quartus_pgm、JTAG、board、power、Flash/EPCQ。

由于前序脚本/API harness 参数修订，本任务实际启动了 5 个串行、互斥的
`quartus_sta` process；前 4 个分别在模型参数、TimeQuest flag/过滤 API、生成 SDC
变量命名阶段失败或未产生可用结果，最终 acceptance 只采用最后一个成功 process。
所有 process 都通过 `resource-lock gamepc`，无并发 STA，fitted DB pre/post hash 均未改变。

期间曾有参数/API harness 修订（非法 `-model` 名、TimeQuest flag、生成 SDC 的 `pins`
数组命名），均在证据 JSON 的 `transient_harness_events` 记录；所有失败在分析模型
校验/脚本阶段停止，fitted DB pre/post hash 未改变。最终有效 query 才作为 acceptance
证据，未修改 RTL/QSF/SDC/QEMU、active task JSON、TASKS/PROJECT_STATUS/ROADMAP。
