# T-20260908-001：B25 Quartus SystemVerilog 兼容性修复交接

```text
task=T-20260908-001 state=done-local-focused-followup
base=8316a1b8b94010ea31cf791e441e3f065197e841
head=839ecbecadfa81d8243adeaa31df193943b2ca11
branch=fix/T-20260908-001-b25-quartus-sv-compat
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-001
sent_at=2026-09-08T11:23:14+08:00 received_at=2026-09-08T11:23:14+08:00
reported_at=2026-09-08T12:02:15+08:00
files=rtl/lcvex_fp_scalar.sv,rtl/lcvex_neon_fp.sv,tb/sv/lcvex_fp_scalar_tb.sv,tb/sv/lcvex_fp_scalar_p7_4_tb.sv,tb/sv/lcvex_fp_scalar_p7_5_tb.sv,docs/tasks/evidence/T-20260908-001.json,docs/handoffs/T-20260908-001-b25-quartus-sv-compat.md,build/agents/T-20260908-001/**（ignored）
tests=instance-audit 11/11 + 3/3 PASS；4 affected focused Verilator lint/build/runtime PASS
blockers=physical Quartus rerun pending integration candidate
evidence=docs/tasks/evidence/T-20260908-001.json
```

## 实现

在 `rtl/lcvex_fp_scalar.sv` 中：

- 移除 `lcvex_fp_scalar` 的 `iter_kill`、`iter_pause` input declaration initializer；
- 移除 `lcvex_fp_divider` 的 `kill`、`pause` initializer；
- 给 legacy `div_lo`、`div_hi` 显式连接 `.kill(1'b0)` / `.pause(1'b0)`；
- 保留 `FP_ITER=1` 的 `it_divider` `.kill(iter_kill)` / `.pause(iter_pause)`，未改变
  FSM、reset/kill/pause 优先级、状态枚举或 latency。
- follow-up 按扩展写集给 NEON `FP_ITER=0` 的 `scalar_lane` 以及三个 legacy scalar
  testbench 显式连接 `.iter_kill(1'b0)` / `.iter_pause(1'b0)`；未改输出处理。

实现只包含一个 RTL 文件，commit 为
`c868d900e6f6d88cc3f77828a34f04daea9d5048`，SHA-256 为
`c30396fef6f3bc55fef912a9d1e6ee807efb8a85eb72870763d63df4487521e4`。

## 实例审计

任务专用静态 runner `build/agents/T-20260908-001/audit_iter_ports.py` 枚举了 11 个
`lcvex_fp_scalar` 实例和 3 个 `lcvex_fp_divider` 实例：

- 11 个 scalar 实例（7 个 `FP_ITER=1`、4 个 `FP_ITER=0`）均显式驱动
  `iter_kill/iter_pause`；
- 3 个 divider 实例均显式驱动 `kill/pause`；`div_lo/div_hi` 使用常量 0，`it_divider`
  使用迭代控制信号；
- 4 个 legacy `FP_ITER=0` scalar caller（NEON `scalar_lane`、三个 raw scalar TB）
  现均 tie-off 为 `1'b0`；它们不展开 `g_iter`，所以控制不会进入迭代逻辑；
- 目标文件 input declaration initializer 数为 0。

审计 JSON 为 `build/agents/T-20260908-001/instance-audit-followup.json`，SHA-256 为
`f8e2196cf4d624d5e44032c2f5ac7d9830ef75dda53f56288c17aab503360304`。

## 验证

在 `/home/chiro/projects/mycpu/lcvex-wt-T-20260908-001` 中使用：

```text
/home/chiro/projects/.resource-locks/resource-lock run local lcvex T-20260908-001 b25_physical \
  --min-local-available-mib 8192 --meta stage=focused_verilator \
  --meta source_sha=8316a1b8b94010ea31cf791e441e3f065197e841 -- \
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
  bash build/agents/T-20260908-001/run_focused.sh
```

初始 7 个 testbench 和 follow-up 的 4 个受影响 testbench 均为 lint/build/runtime
exit 0。follow-up 具体复跑：

- scalar baseline：P7-1 raw-bit directed vectors；
- P7-4 scalar：FMA/conversion raw-bit vectors；
- P7-5 scalar：H/sqrt/minmax/frint/fcvt raw-bit vectors；
- FP exec directed：transaction、NEON、FDIV/FSQRT latency、kill/reset/reissue。

初始 7 项 focused 集合还覆盖：

- scalar baseline：P7-1 raw-bit directed vectors；
- R18：scan/classify/normalize、pause、kill、reset、valid-drop；
- R20 route：non-half route、half preservation、default/control probes；
- R20 pack：H/S/D DIV/SQRT、round/flags、pause/kill/reset/valid；
- R21 iter-round：leading metadata、DIV/SQRT finish、round-pack latency；
- R21 FMA-cut：四种 FMA、special/rounding、pause 控制；
- FP exec directed：transaction、NEON、FDIV/FSQRT latency、kill/reset/reissue。

初始 systemd scope 运行约 3 分 59 秒、峰值约 2.3 GiB；follow-up scope 运行约
2 分 26 秒、峰值约 1.6 GiB，均为 `-j1`。最终 `local FREE; gamepc FREE`。精确
日志、每项 exit、Verilator allocation、控制 PINMISSING=0 和 hash 见 evidence JSON。

## 边界与下一步

本任务没有运行 GamePC/Quartus、assembler/SOF/JTAG/板卡/Flash，也没有修改 QEMU、
参考结果、测试期望、active task JSON、TASKS、PROJECT_STATUS 或 ROADMAP。集成者应在
合并该 commit 后，以合并 candidate 重新执行一次 fresh Quartus physical flow；本地
focused 证据不能替代物理签核。
