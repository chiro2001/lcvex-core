# T-20260909-008：B25 FIFO payload SDC closure 交接

```text
task=T-20260909-008
label=B25-FIFO-PAYLOAD-SDC-CLOSURE
state=implementation-complete
acceptance_status=exact-3b-sdc-and-local-adapter-validation-pass; post-fit-closure-pending
batch=T-20260909-011
base_sha=fcb61cb9ebff2f389f43b0f0a3973d9314176779
source_head_before_docs=fcb61cb9ebff2f389f43b0f0a3973d9314176779
branch=fix/T-20260909-008-b25-fifo-payload-sdc
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-008
sent_at=2026-09-09T12:48:32+08:00
received_at=2026-09-09T12:48:32+08:00
reported_at=2026-09-09T13:05:51+08:00
evidence=docs/tasks/evidence/T-20260909-008.json
correction=metadata-only handoff path correction
pre_correction_tip=3361c0f44e309184d0cb4e732ba5f85b95db4347
correction_requested_at=2026-09-09T13:11:11+08:00
correction_applied_at=2026-09-09T13:12:59+08:00
tests_rerun=false
```

## 结论

T-005 fitted audit 已证明 response FIFO memory 到 `txn_local_q*`、`read_len_q*` 和
`read_beat_q*` 存在与现有两个 response payload sink 相同的异步数据路径。本 lane
只在 `fpga/catapult_a10/quartus/catapult_a10.sdc` 的 section 3b 增加以下三条精确
exception：

```tcl
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|txn_local_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_len_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_beat_q*}]
```

没有把路径扩大到 `soc|emif_adapter|*`，没有切 Gray pointer synchronizer，也没有
修改 section 3b 以外的 SDC。新增 `check_fifo_payload_sdc.py` 是无 Quartus、无网络、
无 Git/环境依赖的 hermetic 文本 checker；它只解析 3b，并要求六个 exact endpoint
family 各出现一次：request→`emif_req_q`，以及 response→`txn_local_q`、`read_len_q`、
`read_beat_q`、`read_line_q`、`response_code_q`。

## 实现与边界

- SDC 原文件 SHA-256：`b16247b74c6b07c7d0c4a0a50d4787072299b8b73e0caccce5fb273307ac078f`
  → `3a5bf655c3d5467912834999c8221815f6630f597757254e8d91d7ceb365a207`；差异为
  `+6/-0`，其中只有三条 active `set_false_path`。
- checker SHA-256：`e559fe6cdd2417f4488a742dca73e86c68f1e24a611a7e12612b955d62fad53c`。
- 正向 checker 报告六个 family 均 `count=1`，3b active command 总数为 6。
- checker 内置 task-local fault matrix：缺失、重复、response source broad、adapter
  target broad、response sink→FIFO memory 反向、response memory→request sink 反向，
  共 6/6 个故障均非零失败；日志和完整矩阵见 evidence。
- 本 lane 没有 RTL delta；adapter、BFM、SVA、Cocotb 源 hash 与 base 相同。没有修改
  QSF、manifest、SHA registry、active task、TASKS、PROJECT_STATUS、ROADMAP、QEMU
  或参考结果。

## 本地验证

所有 heavy 作业都经 `resource-lock run local`，`min_local_available_mib=4096`，
`MemoryMax=16G`、`MemorySwapMax=0`、Verilator 单线程，并使用
`build/agents/T-20260909-008/{sv,cocotb}/tmp`。最终锁状态为 `local FREE; gamepc FREE`。

- `python3 -m py_compile fpga/catapult_a10/tools/check_fifo_payload_sdc.py`：exit 0。
- `python3 fpga/catapult_a10/tools/check_fifo_payload_sdc.py --sdc ...`：exit 0，
  `FIFO_PAYLOAD_SDC_CHECK_PASS`；日志 SHA 为
  `23f57d89a1149eae903ce80806bff8d265f0ffbd99b71e174957ab644816a057`。
- `python3 fpga/catapult_a10/tools/check_fifo_payload_sdc.py --self-test`：exit 0，
  fault `6/6`；日志 SHA 为
  `d7a42eb7415654adba8a6357cd68e6b0aaaa9e7020051c96796688d6ce37205f`。
- fresh SV/SVA Verilator build（空 task-local `obj_dir`，`--timing --assert`）：exit 0，
  12 modules，child max RSS `370864 KiB`；日志 SHA 为
  `3f2685f782cf84dbe74824feb2973ed5b174797d8124c06cb728f8c59a2354de`。
- fresh SV/SVA runtime：exit 0，`PASS: B2 AXI4/Avalon SV regression writes=0 reads=0`，
  3 us，child max RSS `14088 KiB`；日志 SHA 为
  `182df5bf7418e657663b4af294dce2c6ec2d822d0d3cbe1a5915d0ebc51f6259`。
- adapter Cocotb：exit 0，`TESTS=7 PASS=7 FAIL=0`，4616.01 ns，child max RSS
  `371520 KiB`；日志 SHA 为
  `301b32629a04659ab598f34953c8cc1d5d145fe2b777af8e02a4dda8138127f8`。

中途一次 local lock 按协议返回 exit 75 并等待；一次错误的 `/usr/bin/time` wrapper
和一次复用旧 `obj_dir` 的结果均已丢弃。最终 SV 证据在创建空 `obj_dir`、预创建
task-local TMPDIR 后重新全量生成，日志无 `/tmp` fallback。上述过程、命令、时间戳、
exit/RSS/锁信息和完整 write-region diff 见
[`docs/tasks/evidence/T-20260909-008.json`](../tasks/evidence/T-20260909-008.json)。

## 集成与风险

本 lane 按要求没有做 Quartus/TimeQuest、remote overlay、synthesis、fitter、assembler、
bitstream、GamePC、JTAG、板卡或 Flash 动作。因此当前结论是实现和受影响 adapter
回归通过，不是 physical timing closure。集成者在合并后的 isolated fitted clone 中
重跑两 FIFO memory 到六个 endpoint family 的 setup/hold、`report_exceptions`（含
`-ignored`）、`report_clocks`、recovery/removal/min-pulse 和 unconstrained checks；
确认新三个 pair 为 Complete、无 broad/ignored exception，并保留无关 synchronizer
路径。T-007 的 vendor/JTAG/reset-clock unconstrained 分类仍是独立物理门。

完整 evidence：[`T-20260909-008.json`](../tasks/evidence/T-20260909-008.json)。

## 元数据修正记录

原子实现提交 `3361c0f44e309184d0cb4e732ba5f85b95db4347` 创建的 handoff 文件名不符合
任务登记路径。本次 follow-up 仅执行文件重命名并同步 evidence 路径；原始测试时间、
exit/RSS、日志 hash、实现内容和测试结论全部保留，未重跑任何测试或修改 SDC/checker。
