# T-20260909-005：B25 async FIFO payload hold 审计交接

```text
task=T-20260909-005
label=B25-ASYNC-FIFO-PAYLOAD-HOLD-AUDIT
state=review
decision=SDC-fix
acceptance_status=audit-complete; physical-closure-not-accepted
base_sha=2a10d23740e67850cdae7e91fd834c53c7746cac
physical_source_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
branch=verify/T-20260909-005-b25-async-fifo-payload-hold-audit
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-005
remote_probe=D:/Projects/fpga-altra/lcvex/build/T-20260909-002-b25-physical
remote_runtime=D:/Projects/fpga-altra/lcvex/build/T-20260909-002-b25-physical/runtime/T-005
evidence=docs/tasks/evidence/T-20260909-005.json
```

## 结论

结论为 `SDC-fix`。冻结 T-002 fitted DB 的精确端点枚举证明，当前 3b 已覆盖的
`response_fifo|mem* -> read_line_q* / response_code_q*` 之外，还存在三个同一协议域的
payload/control sinks：`txn_local_q*`、`read_len_q*`、`read_beat_q*`。它们的路径不是
普通同步逻辑，而是 EMIF user clock 到 `sys_clk_25` 的异步 FIFO memory read-data
路径；当前均显示 `No SDC Exception on Path`。

| from → to endpoint family | setup（Fast 900mV 0C） | hold（Slow 900mV 0C） | launch → latch |
| --- | --- | --- | --- |
| `response_fifo|mem* → txn_local_q*` | 18 paths，0 violated，WNS +4.262 ns | 18 paths，7 violated，WNS −10.338 ns | `emif|emif_bot|emif_bot_core_usr_clk` → `sys_clk_25` |
| `response_fifo|mem* → read_len_q*` | 18，0，+4.166 ns | 18，7，−10.105 ns | 同上 |
| `response_fifo|mem* → read_beat_q*` | 144，0，+3.723 ns | 144，56，−9.256 ns | 同上 |
| `response_fifo|mem* → read_line_q*` | 0（现有 3b Complete） | 0（现有 3b Complete） | — |
| `response_fifo|mem* → response_code_q*` | 0（现有 3b Complete） | 0（现有 3b Complete） | — |

`response_fifo|mem*` 源集合为 1558，`request_fifo|mem*` 为 1815。response→整个
`soc|emif_adapter|*` 的 broad query 共 180 paths（hold 70 violated），端点分布恰为
`txn_local_q` 18、`read_len_q[0]` 18、`read_beat_q[0..7]` 144；request→
`emif_req_q*` 及 request→整个 adapter 在现有 SDC 下均无 timed path。

## 协议证明与 overlay

`lcvex_async_fifo_cdc` 使用独立的 registered Gray pointer、两级 pointer synchronizer
和 `rd_empty = (rd_ptr_gray_q == wr_ptr_gray_rd2_q)`。写时钟边沿同时写 `mem[]` 并推进
`wr_ptr_gray_q`；读域只有在 `rd_empty` 消失后才允许 `rd_en`，而 `rd_data` 是当前
`rd_ptr_bin_q` 对 FIFO memory 的数据。因 `wr_ptr_gray_rd1_q`、`wr_ptr_gray_rd2_q`
连续在两个 `rd_clk` 边沿采样，新的 entry 至少经过两个读时钟同步采样；adapter 在
随后一个读边沿才由 `resp_fifo_rd_en` 捕获 packet。因此“payload 写入后至少两个读
时钟稳定再捕获”成立，前提是 Gray 单 bit transition、FIFO full/no-overwrite 及
registered read protocol 保持不变。这里没有宣称 payload 自身有第二级 synchronizer。

在同一次 `quartus_sta` report-only invocation 中，内存中加入了精确 endpoint-only
`set_false_path` overlay：

```tcl
set_false_path -from [get_registers -nowarn {*request_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|emif_req_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|txn_local_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_len_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_beat_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_line_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_code_q*}]
```

这不是 checked-in SDC 修改。overlay 后 response memory→all adapter 为 `Nothing to
report`；全局 `sys_clk_25` hold 仍有 50 条路径、0 violated、WNS +0.018 ns，首条为
EPCQ `add_msb_reg`，并且仍可见
`request_fifo|rd_ptr_gray_wr1_q[0] -> request_fifo|rd_ptr_gray_wr2_q[0]`。因此 overlay
只移除了枚举出的 FIFO packet payload sinks，没有吞掉其它同步器 hold。基线 top path
正好为 `response_fifo|mem~514 -> txn_local_q`、WNS −10.338 ns、No SDC Exception。

## 后续动作

只允许另立 SDC 修复任务修改
`fpga/catapult_a10/quartus/catapult_a10.sdc` 的 3b 区域（当前约 93–102 行），增加
上述三个 response endpoint 的三条 `set_false_path`；不得扩大为 adapter/global
wildcard，也不修改 RTL。未来任务的 L0–L2 和报告复验至少包括：

- L0：`make -C sim/cocotb -f Makefile.axi4_avalon SIM=verilator TOPLEVEL=lcvex_axi4_avalon_cocotb_tb COCOTB_TEST_MODULES=test_axi4_avalon SIM_BUILD=build/agents/<future-task>/cocotb`；
- L1：adapter SV/Verilator lint、现有 SVA 及 `tb/sv/lcvex_axi4_avalon_tb.sv`；
- L2：现有 AXI/Avalon directed lockstep/difftest lane，记录无 RTL delta；
- 在新 SDC 应用后的 post-fit DB 上重跑两 FIFO memory 的全部端点 collection、setup/hold
  `report_timing`、`report_exceptions`（含 `-ignored`）、`report_clocks` 以及
  setup/hold/recovery/removal/min-pulse。只有所有适用 Gate D 条件闭合后才可解除物理门。

本任务没有运行 synthesis/fitter/assembler、没有生成 bitstream、没有 JTAG/board/Flash
动作；fitted DB、QPF/QSF/SDC 的选定 hash 前后相同，远端 postflight 为 EDA=0、禁用
扩展名 artifact=0。最初下载到的本地 `remote/probe/runtime/T-005` 已完整迁移到
`build/agents/T-20260909-005/runtime/remote/T-005`，保留 bytes/timestamps/hash，仓库
根目录不再有 `remote/`。

详细命令、时间戳、资源锁（包含 return 75 等待）、报告及 hash 在
[`T-20260909-005.json`](../tasks/evidence/T-20260909-005.json)。
