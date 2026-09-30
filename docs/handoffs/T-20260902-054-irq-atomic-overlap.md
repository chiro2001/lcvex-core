# T-20260902-054：natural CASP/STXR/DC ZVA IRQ overlap

```text
task=T-20260902-054
state=review
base=2a74712beaafdbda843cec4e9539a2d9cb1da51a
head=6df1a92f31421c8fa12309418bf20f06baaa6b7d
branch=verify/T-20260902-054-irq-atomic-overlap
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-054
sent_at=2026-09-04T19:35:47+08:00
received_at=2026-09-04T19:35:47+08:00
reported_at=2026-09-04T21:58:14+08:00
files=tb/sv/lcvex_irq_atomic_overlap_tb.sv; sim/difftest/test_program.py; sim/difftest/run_p6_irq_atomic_overlap.sh; sim/difftest/run_irq_atomic_probe.sh; sim/difftest/run_irq_atomic_trace.sh; Makefile; scripts/test_registry.json; docs/handoffs/T-20260902-054-irq-atomic-overlap.md; docs/tasks/evidence/T-20260902-054.json
tests=SV FIFO off/on x MEM_DELAY_MODE 0/2; QEMU strict+step probe+trace base/delay2 x CASP/STXR/DC ZVA; registry and syntax checks
blockers=无（冻结验收已通过）；QEMU step hook 不支持原子微相位且 step MEM_W 不可用，store tuple 由同源 trace probe 补充；STXR 同提交 mon_we 现场转 T-055；未修改 coordinator/plugin/QEMU/RTL
next=集成者 cherry-pick ca804be、e4c1904、6df1a92 与本 handoff/evidence，在合并 SHA 复跑 T-054 L0-L2；T-055 单独修复 STXR same-commit plugin monitor 契约；可选再跑 I+D+L2 cache
```

## 实现摘要

- 新增 `lcvex_irq_atomic_overlap_tb.sv`。每个场景先让真实事务进入流水/FSM，
  只 `force dut.gic_irq` 注入 IRQ；没有 force `commit_fire`、MEM/WB metadata、
  stage valid 或架构状态。覆盖：
  - CASP match：读相后在低半 8B 写已接受时注入，检查 fence、两段写 exactly-once、
    IRQ packet 携带 CASP 旧值/新值；
  - CASP mismatch：高半读相在途时注入，检查无写和返回旧 pair；
  - STXR：IF/ID + 真实 older MEM/WB 的 squash，以及自身比较读相/成功条件写相的
    IRQ 延迟；success/fail 的条件写计数为 1/0，状态回写为 0/1；
  - DC ZVA：第 3 个 8B beat 接受后注入，IRQ 保持 pending，完成 8 个零写，
    `maint_zva_idx` 覆盖 0..7，mask=`ff`，IRQ packet 不冒充 memory store。
- 新增 `build_hard_irq_atomic_overlap_program()` 及五个 wrapper。QEMU 侧用真实
  Generic Timer physical PPI30（GICD ISENABLER bit30）在完整指令边界触发 IRQ；
  DC ZVA image 预置 8 个非零 8B beat，IRQ 返回后逐 beat load 验证 64B 清零。
- 新增 `run_p6_irq_atomic_overlap.sh` / `run_irq_atomic_probe.sh` /
  `run_irq_atomic_trace.sh`、Makefile target 和独立 L1/L2 registry 条目。runner
  串行执行 base 与 `MEM_DELAY_MODE=2`，每个场景独立 socket、coord、step probe、
  trace 和失败现场；所有入口命令均显式使用外层 cgroup 与 `VERILATOR_JOBS=1`。

## 验证结论

SV 正式目标 `make VERILATOR_JOBS=1 sim-sv-irq-atomic-overlap` 通过四配置：

| FIFO | delay | CASP match/mismatch | STXR ID squash/success/fail | DC ZVA |
|---|---:|---:|---:|---:|
| off | 0 | 2 / 0 accepted writes | 0 / 1 / 0 | 8 beats, mask=ff |
| on | 0 | 2 / 0 accepted writes | 0 / 1 / 0 | 8 beats, mask=ff |
| off | 2 | 2 / 0 accepted writes | 0 / 1 / 0 | 8 beats, mask=ff |
| on | 2 | 2 / 0 accepted writes | 0 / 1 / 0 | 8 beats, mask=ff |

QEMU 11.1.0 strict step 通过 10/10（base/delay2 × 五场景）；专用 step probe
自动解析真实 COMMIT 的目标/IRQ PC、insn 和 `exc_code=0x40`，trace probe 自动
解析同源 QEMU trace 的有效 stores。协调器严格比较 PRE/COMMIT、seq、寄存器、
NZCV、异常和可用的内存副作用；所有 IRQ 为普通 COMMIT，不是 `ASYNC`：

- CASP match/mismatch：目标 CASP/IRQ 分别位于 `pc=0x44000078` /
  `0x44000080`，`exc_code=0x40`；trace-side effective stores 分别 2/0，match
  tuples 为 `0x44082000/0x33/8B`、`0x44082008/0x44/8B`。mismatch 的 raw
  trace 会给出 unchanged old-value phantom tuples，probe 按 pre-shadow 归类为
  有效 0 写，strict 状态仍通过。
- STXR success/fail：STXR 已正常退休并发布状态/写副作用后，在下一条边界
  `pc=0x44000074` / `0x4400006c` 取 IRQ，STXR 目标分别为 `0x44000070` /
  `0x44000064`，trace-side stores 为 1/0，状态为 0/1；
- DC ZVA：`pc=0x44000060` 的 DCZVA boundary，packet stores=0，返回后 8 个
  load 都与预置非零块清零结果一致。

所有 Verilator 编译和仿真均使用 `systemd-run --user --scope
-p MemoryMax=16G -p MemorySwapMax=0`、Verilator `-j 1`；QEMU/plugin 只读复用，
未修改 QEMU fork、coordinator、参考结果、断言或 `rtl/**`。

## 已知边界

QEMU fork 的 step hook 只强制每条指令一个 TB，并在完整指令边界记录异步异常，
没有 CASP/STXR/DC ZVA 内部微相位注入契约；且当前阻塞 PRE/GO step 路径不提供
可用 MEM_W tuple。因此 SV 承担中间 beat/phase 的真实流水检查，strict coordinator
承担架构状态/seq/异常比较，独立 QEMU trace probe 承担有效 store tuple 记账。
一次探索性运行把 IRQ 放在 STXR 同一 COMMIT，现有 plugin monitor 逻辑因
`exc_code=0x40` 抑制 `mon_we`，最小失败现场仍保留在 evidence 的 `resolved_failures`，
并明确要求独立 T-055 plugin regression；T-054 正式 wrapper 只验证 STXR 正常退休
后下一边界 IRQ。

仓库级 `check_task_timestamps.py --scope live --exit-code` 当前仍报告其他任务既有
时间账本问题（65 errors、52 warnings）；T-054 不在 active task JSON 集合中，故未修改
这些越界记录，其他本任务 JSON/registry/syntax/whitespace 审计均通过。

精确命令、source/artifact hash、资源峰值、seq/PC 和日志路径见
[`docs/tasks/evidence/T-20260902-054.json`](../tasks/evidence/T-20260902-054.json)。
