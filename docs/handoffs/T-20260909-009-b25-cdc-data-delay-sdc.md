# T-20260909-009：B25 CDC data-delay SDC closure 交接

```text
task=T-20260909-009 state=done
base=fcb61cb9ebff2f389f43b0f0a3973d9314176779
head=e03c6430e354247057ae243d6cd724e54add0ded
implementation_commit=e03c6430e354247057ae243d6cd724e54add0ded
branch=fix/T-20260909-009-b25-cdc-data-delay-sdc
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-009
sent_at=2026-09-09T12:48:32+08:00
received_at=2026-09-09T12:48:32+08:00
reported_at=2026-09-09T13:07:30+08:00
timezone=Asia/Shanghai
evidence=docs/tasks/evidence/T-20260909-009.json
```

## 结论

本 lane 已完成五个 CDC pair 的约束替换：四组 3-bit Gray pointer 和一组 1-bit
T-045 poison 均保留原有完整 `set_false_path`，并将同一 `from/to` 的
`set_max_delay ... 2.000` 原位替换为独立 `set_data_delay ... 2.000`。正式 SDC 中
`set_max_delay` 数量为 0、`set_data_delay` 数量为 5；section 3b、section 4c 的其它
reset/calibration 条件没有扩大或改写。

T-006 的 Quartus Prime Pro 21.4 loaded-DB 证据证明 `set_max_delay -datapath_only` 和
`set_max_delay -setup` 都是 unsupported，而 `set_data_delay` 独立于 full false path，
可产生 `Max Delay Exception (Datapath Only)`。T-006 G1 的五对 data-delay slack 全部
非负，最差 poison 为 `+0.984 ns`；本 lane 保留所有 2 ns 值，没有声称本地静态 checker
替代 physical STA。

## 实现

- `fpga/catapult_a10/quartus/catapult_a10.sdc`：只改 section 3 四条 Gray bound 和
  section 4c poison bound；每条仍为 2.000 ns，且对应 full false path 保持在前。
- `fpga/catapult_a10/tools/check_cdc_data_delay_sdc.py`：新增无 Quartus/数据库/网络依赖
  的 hermetic checker。它解析 active Tcl continuation，要求五对 exact full-false +
  exact `set_data_delay`，拒绝旧 `set_max_delay`、缺失/重复、broad/wrong selector、
  错误值和 unsupported option，并检查 data-delay 不早于对应 full false path。
- `--fault-matrix` 在内存中覆盖 10 个故障：data/false missing、duplicate、broad、
  wrong value、unsupported option、legacy max-delay、hold-only false path；10/10 均被
  fail-closed 捕获。

## 验证

最终所有重型本机作业均通过 `resource-lock run local`、`min_local_available_mib=4096`、
Verilator 单线程和 `systemd-run` 的 `MemoryMax=16G/MemorySwapMax=0` 执行，临时目录和
SIM_BUILD 均在 `build/agents/T-20260909-009/`（ignored）：

- `python3 -m py_compile .../check_cdc_data_delay_sdc.py`、checker 默认检查及
  `--fault-matrix`：exit 0；5/5 pair 各有 1 条 full false + 1 条 data-delay，旧
  `set_max_delay=0`；10/10 faults caught。
- SV Verilator endpoint reset/timeout regression：exit 0，`PASS: B2 AXI4/Avalon SV
  regression writes=0 reads=0`，仿真到 3 us；编译 peak RSS 1,485,520 KiB，仿真 wrapper
  peak RSS 22,080 KiB。
- Cocotb endpoint：7/7 通过，覆盖正常 CDC、校准失败 DECERR、reset flush、永久
  wait/missing response timeout、late drain、AW/W partial reset、stalled command reset
  和 EMIF-only reset/response hold；仿真到 4616.01 ns，peak RSS 232,304 KiB。
- `git diff --check`：exit 0。

完整命令、退出码、RSS、锁/cgroup、源 SHA、artifact SHA 和 transient failed attempts
见 [`T-20260909-009.json`](../tasks/evidence/T-20260909-009.json)。transient attempts
包括一次未激活 conda 的 SV 环境失败、一次相对 TMPDIR 被 `make -C` 回退 `/tmp` 的
非采纳 Cocotb 运行，以及一次 scope PATH 缺 conda 的失败；它们均无效且随后已用绝对
路径/task-local TMPDIR 成功复跑。

## 边界与后续

本 lane 未触碰 RTL、QSF、manifest、registry、QEMU、active task/TASKS/PROJECT_STATUS/
ROADMAP，也未连接 GamePC、Quartus、QDB、assembler、JTAG、板卡或 Flash。checker 只
证明源 SDC 契约，不证明 fitted netlist 的 collection/cardinality、exception Complete 或
data-delay slack。集成者应在 batch candidate 上按 T-006 的四 corner 计划复跑
TimeQuest：五对 source/target 非空且等宽、full false path 无 ignored/override、独立
`report_timing -setup -data_delay` 五组路径完整且 slack 非负，并确认 QDB/output
provenance。
