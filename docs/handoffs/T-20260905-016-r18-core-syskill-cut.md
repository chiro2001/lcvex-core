# T-20260905-016：R18 core `sys_commit`/FP kill 反馈切断交接

```text
task=T-20260905-016
state=review
base=738cc142c0dae5269dffe9b8020094cb77ec8094
implementation_head=c8194730e61ffd7967afa3a4971027ad341e7a14
branch=timing/T-20260905-016-r18-core-syskill-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-016
owner=codex-r18-core
timing_source=T-20260905-014 fresh post-fit/STA
reported_at=2026-09-05 (Asia/Shanghai)
```

## 结论

T-014 的 fresh `sys_clk_50` top-50 显示 50 条路径均从
`idex_valid` 到 `g_fp_simd_enabled.fp_exec.state.TX_DONE`，最差 slack
`-3.256 ns`、data delay `23.509 ns`、26 logic levels。共同控制链包含
`sys_commit_ready → sys_commit → fp_tx_kill → fp_rsp_ready → TX_DONE D`。

本任务在 `rtl/lcvex_core.sv` 中移除了 `sys_commit` 到 `fp_tx_kill` 的组合项：

```systemverilog
assign fp_tx_kill = fetch_merge_wb || wb_exc_commit ||
                    irq_taken || wfi_irq_take || wfi_wake ||
                    difftest_restore_sys_valid;
```

`sys_commit` 仍由原有 ID/EX、EX/MEM、MEM/WB 全排空条件及
`sys_commit_ready/commit_ready` 约束。新增 `fp_tx_active` 仅用于断言，聚合
`fp_tx_candidate/fp_tx_issued/fp_tx_busy/fp_rsp_valid`；五条 SVA 分别证明
system commit 不会与 candidate、issued owner、wrapper busy、held response
或 aggregate owner 同周期共存。没有加入 false path，也没有关闭或放宽已有断言。

所有真实年轻 transaction kill 仍保留：fetch fault merge、WB exception、
ordinary IRQ、WFI IRQ/wake 以及 difftest system restore。FP wrapper 的
TX_DONE held response、单在途状态、FCVT GPR raw payload、提交顺序和
`lcvex_fp_scalar.sv`/`lcvex_neon_fp.sv` 均未修改。

## 定向测试

`tb/sv/lcvex_core_tb.sv` 增加 `+T016_SYSKILL` 分支，复用真实
`lcvex_soc_tb`，覆盖：

- 两条 older scalar 指令填满 MEM/WB 与 EX/MEM 时，TX_DONE response 在
  `commit_ready=0` 下保持 payload 至少三周期，释放后只消费/提交一次；
- FP response 后紧邻的 MSR FPCR、正常 ERET、UDEF 和 WFI，检查 system
  commit 顺序、异常/状态效果以及每周期 owner 互斥；
- `SCVTF → FCVTZS/FCVTZU W9,S7 → CBNZ`，检查 response 中 raw GPR=3、
  commit GPR=3、立即分支跳过 bad marker 并提交 taken marker。

`sim/cocotb/test_core_syskill.py` 提供同一组无 QEMU/reference 的 raw-bit
定向检查，并在每个周期观测 `sys_commit` 与 FP owner/response。

## owner 轻量证据

以下检查已通过：

- `git diff --check b350141..c8194730`；
- Python AST parse：`sim/cocotb/test_core_syskill.py`；
- 静态结构检查：`fp_tx_kill` 不含 `sys_commit`，六类真实 kill 全在，SVA 与
  SV/Cocotb focused markers 存在。

精确 source SHA、T-014 raw top-50 路径及日志/artifact SHA 见
[`docs/tasks/evidence/T-20260905-016.json`](../tasks/evidence/T-20260905-016.json)。

## 尚未运行与集成边界

按任务资源门，本 owner 没有启动 Verilator、SV/Cocotb runtime、QEMU、锁步、
Quartus 或任何 assembler/bitstream/JTAG/上电/板测操作。集成者应在 batch
candidate 的合并 SHA 上串行运行：

```text
focused SV: make VERILATOR_JOBS=1 sim-sv
然后运行 obj_dir/lcvex_core_tb +T016_SYSKILL
focused Cocotb: make -C sim/cocotb SIM=verilator \
  TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_core_syskill \
  SIM_BUILD=sim_build_core_syskill
```

之后联合 T-013/T-016 受影响的 L0–L2（含 T-012 FP/data-MMU overlap、
IRQ-young、P7 回归），再按 T-014 的新物理流程执行 synthesis→fitter→STA。
只有 fresh STA directional/top-50 证据才能宣称该 timing cone 被移除或由新
热点取代；本 handoff 不宣称 timing improvement。
