# T-20260908-002：B25 post/pre-index writeback 交接

```text
task=T-20260908-002
state=done
base=8316a1b8b94010ea31cf791e441e3f065197e841
head=8c0a8f41724427807802d0243f17818669c9d40a
branch=fix/T-20260908-002-b25-postpre-writeback
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-002
sent_at=2026-09-08T11:23:14+08:00
received_at=2026-09-08T11:23:14+08:00
reported_at=2026-09-08T12:02:42+08:00
timezone=Asia/Shanghai
files=rtl/lcvex_core.sv,sim/difftest/b25_postpre_writeback_matrix.py,sim/difftest/run_b25_postpre_writeback_matrix.sh
evidence=docs/tasks/evidence/T-20260908-002.json
```

## 结果

已定位并修复 T-046 的首错。cycle 67 同时存在较新的 EX/MEM `ORR x20,x21,xzr`
（结果 `0x44090010`）和较旧 MEM/WB indexed-load 的 `wb3_extra`
（`0x44090011`）；原 `gprv` 优先级先取 MEM/WB `wb3`，使译码使用旧 base。于是
`ldrb w5,[x20,#4]!` 的 `mem_addr/wb3_extra` 被算成 `0x44090015`，并在后续保持/再次
捕获现场出现 `exmem VA=0x44090019`。

实现修复为：

- 在 ID 前递中保持同一阶段的 pre/post `wb3` 优先，同时把年轻 EX/MEM 普通 GPR
  写回放到任何旧 MEM/WB producer 之前；因此 EX/MEM 的 ORR 覆盖旧 MEM/WB `wb3`。
- 单寄存器 SP pre/post 也从解码锁存的 `wb3_extra` 更新 `exmem_sp_wdata`；ADD/SUB
  SP 仍保留 ALU 结果路径，不会被空的 `wb3_extra` 覆盖。
- 所有 GPR/SP/NZCV 架构状态仍只在 commit 边界更新。

## 验证

- 未修复 `hard_postpre`：base/cache/delay2 均在 `seq=21`、PC `0x44000054`、编码
  `0x38404e85` 失败（RTL `x20=...15`，QEMU `x20=...14`）。
- 修复后 `hard_postpre`：base/cache/delay2 各 70 条与 QEMU 完全一致。
- 新增 90-word focused matrix，覆盖 B/H/W/X load/store、pre/post、Rt==Rn、SP base
  和紧邻 base 消费；base/cache/delay2 各 180 条与 QEMU 完全一致。
- commit-state monitor 执行矩阵 180 次提交，检查 GPR[0..30]、SP_EL0、SP_EL1、NZCV；
  `violations=0`。
- `env VERILATOR_JOBS=2 make test`：P0、SV assertions、Cocotb 和编码器检查全部通过。
- 未运行完整 Gate D；应由集成候选统一重跑。

精确命令、exit code、耗时/RSS、基线/修复日志、QEMU/plugin/tool hash、资源锁和风险见
[T-20260908-002 evidence](../tasks/evidence/T-20260908-002.json)。

## 边界与下一步

本任务只修改 `rtl/lcvex_core.sv` 的 wb3/address-forwarding 区域，并新增独立 focused
generator/runner；没有修改 `rtl/lcvex_decode.sv`、register-offset 单寄存器 block、
common typedef/ports/helpers、FP scalar、QEMU、reference 或测试期望。register-offset
依赖仍由 T-004 负责。

所有编译/锁步均通过 `resource-lock run local ... --min-local-available-mib 8192`，
产物和 TMPDIR 位于本 worktree；未访问 GamePC、Quartus、JTAG、assembler、SOF、板卡或
Flash。集成者应合并 `8c0a8f41`，在合并候选上重跑受影响 L0-L2 和完整 Gate D，再进入
physical/board flow。
