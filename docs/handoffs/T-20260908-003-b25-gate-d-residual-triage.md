# T-20260908-003：B25 Gate D residual triage 交接

```text
task=T-20260908-003
state=done
base=8316a1b8b94010ea31cf791e441e3f065197e841
task_json_base=004b62c19cf2ff4dfd0fb721332fc3a651ed7b99
branch=verify/T-20260908-003-b25-gate-d-residual-triage
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-003
sent_at=2026-09-08T11:23:14+08:00
received_at=2026-09-08T11:23:14+08:00
reported_at=2026-09-08T11:45:00+08:00
files=docs/tasks/evidence/T-20260908-003.json, docs/handoffs/T-20260908-003-b25-gate-d-residual-triage.md
```

## 结论

T-046 的 `random_1_results.xml` 中“522990 处”是累计差异数，不是首个时间序列
指令索引；`gate-d.log` 的第 522990 行也是后续 `insn[62818]` 级联错误。真正首个
seed=1 差异是 `insn[2807]`：

```text
PC       0x440044c4
encoding 0x78377a80
disas    strh w0, [x20, x23, lsl #1]
pre      x20=0x44080000, x23=7, x0=0, NZCV=0xa
QEMU     store addr=0x4408000e, data=0, size=2
RTL      store addr=0x44080000, data=0, size=2
```

`x23=7` 由紧邻的 `insn[2806] mov x23,#7` 提供，故正确寄存器偏移是
`7 << 1 = 0xe`。RTL 的地址只使用了 base，说明 index register 的流水线依赖
没有被识别/前递。

分类为：**different-root（相对 T-20260908-002，置信度 high）**。

T-002 修复的是 immediate pre/post-index 的 `wb3_extra` 基址写回（T-046 的
`ldrb w5,[x20,#4]!`，DUT `x20=base+5`、QEMU `base+4`）。本随机指令的
`bits[11:10]=10`，是 register-offset addressing，不产生 `wb3`。当前 decode
在 `rtl/lcvex_decode.sv:2435-2438` 先登记 `rm` 为 `rs2`，随后 STR 分支
`2442-2446` 将 `rs2` 覆盖为 store data `rt`；`rtl/lcvex_core.sv:2022-2080`
的 `id_reads`/`ex_id_gpr_hazard` 因而看不到 `rm=x23` 的依赖。这是独立的
register-offset index hazard，不能由 T-002 的 pre/post base writeback 修复自动
证明关闭。

## random_2/random_3 缺失判定

判定为 **downstream-not-run**，不是独立覆盖基础设施故障：

- `Makefile:593-596` 以无忽略前缀的三个递归 `$(MAKE)` 顺序执行 seed 1、2、3；
- `Makefile:578-588` 的 seed=1 Cocotb 返回非零后，make 停在 seed=1，seed=2/3
  从未启动；T-046 Gate D 摘要也明确记录这一点；
- Gate D 的 `step()` 捕获随机步骤失败后仍继续覆盖步骤；
- `scripts/insn_coverage.py:187-192` 只因两个路径不存在返回 2，未显示额外生成器、
  工具或格式错误。

## 最小复跑建议

1. T-002 先保存并通过 `hard_postpre` base/cache/delay2 及其 writeback 矩阵。
2. 为本次独立根因加入 `mov x23,#7; strh w0,[x20,x23,lsl#1]`，确认有效地址
   `0x4408000e`；覆盖 W/X、`S`、UXTW/UXTX 与 `Rt==Rn` 依赖组合。
3. 修复后可先用 seed=1、`LENGTH=3000` 到达该首错做快速 triage；Gate D 关闭仍需
   seed=1/2/3 各 `LENGTH=100000`，三份 trace 全部生成后再运行
   `scripts/insn_coverage.py --expect random ...`。
4. 最后在合并 SHA 上重跑完整 Gate D；本任务没有执行 full Gate D 或随机锁步。

## 证据与边界

首错 trace 窗口、objdump、译码/冒险源片段、Gate 日志窗口、trace presence、make
控制流和 coverage 缺失输入检查均保存在 `build/agents/T-20260908-003/**`，精确
SHA256、命令、退出码、RSS 和资源状态见 evidence JSON。复用的是 T-046 已冻结的
`random_1.trace`/结果 XML（复制到本任务 build 目录后只读解析）；当前 local 槽位在
检查时由 T-20260908-001 占用，因此没有启动新的随机锁步。未修改 RTL、QEMU、reference、
test、expectation、active task JSON、状态文档、GamePC、Quartus 或板卡。
