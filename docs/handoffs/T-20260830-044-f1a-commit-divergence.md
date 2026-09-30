# Handoff：T-20260830-044 PE-F1A-DYN

## 结构化元数据

- task：`T-20260830-044`
- state：`review`
- base：`ab6e44f6de301a50dd8930b7e457ee6e4ba3d424`
- diagnostic_source_sha：`5f7120ac768f2c5257f7ae1899787829e6065ed9`
- comparator_source_sha：`cbd63645441677907caecb99857e01240b8cae47`
- branch：`verify/T-20260830-044-f1a-commit-divergence`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260830-044`
- model：`gpt-5.6-luna`
- reasoning_effort：`max`
- sent_at：`2026-08-30T22:13:05+08:00`
- received_at：`2026-08-30T22:14:00+08:00`
- reported_at：`2026-08-30T22:49:22+08:00`

## 实现摘要

在 `sim/microbench/microbench_runner.cc` 增加 opt-in `--trace FILE`。无 trace 时，
`alu_latency` f0/f1a 的周期、retired、commit/memory digest 与 T-043 完全一致；trace
记录为 header/commit/footer JSONL，active effects 稀疏化，并保存当拍 FIFO/epoch/stale
上下文。`sim/microbench/perf_runner.py` 只在给出 `--trace` 时转发路径并返回 trace 路径。
`scripts/compare_commit_traces.py` 流式比较架构字段、输出有限窗口、trace SHA、配置/
provenance 和反汇编，fixture 覆盖 equal/duplicate/skip/effect/wrong-path/termination。

没有修改 RTL、TB、Makefile、run_perf_matrix、baremetal、QEMU 或参考结果。完整 trace
只在 `build/agents/T-20260830-044/`，不进 Git。

## 关键结果

- 两个 `nocache_d0` runner 均在 `diagnostic_source_sha` 上独立构建，均使用
  `MemoryMax=15G`、`MemorySwapMax=0`、`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1`。
- comparator fixture PASS；`alu_latency` 完整架构 trace `equal`，750049 records。
- 无 trace `alu_latency`：f0=`2500171/750049/e02f90ea8089a4f1`，f1a=`2000136/750049/e02f90ea8089a4f1`。
- `fp_scalar`：f0/f1a retired=`65963/65965`，首差异在 pair index 65958，分类
  `duplicate`；F1a 重复 `PC=0x44000574, insn=0xbd47703f` 两次后才进入 `0x44000578`。
- `mem_seq`：f0/f1a retired=`803657/803667`，首差异在 pair index 16，分类
  `duplicate`；F1a 重复 `PC=0x44000104, insn=0xaa0a03e6` 两次后才进入 `0x44000108`。
- 两个 mismatch 的 trace 都包含有效 active vector/GPR effect；不是 inactive payload
  造成的最终 digest 假阳性。memory digest 分别仍为 `0x4078dabba91c60f0` 和
  `0x6b40dea7a6ade5c3`。

## 根因边界

最高优先级假设是 FIFO pop 与 IF/ID consume/replace 未严格原子绑定：
`rtl/lcvex_core.sv:812-819` 的 pop predicate 没有直接绑定 IF/ID advance，而
`:2564-2577` 在 pop 时将 FIFO head 写回 IF/ID。`mem_seq` 首差异正发生在
`occupancy=1,pop=1` 的重复提交周期。当前公开端口没有 FIFO head/tail PC/seq、IF/ID
advance 或 stall 细节，因此只能确定 duplicate 首差异，不能证明 entry 来源；不伪造
唯一根因。

建议下一 RTL 修复任务精确写集：

- `rtl/lcvex_core.sv`：修正 FIFO head/IFID consume/replace 绑定并加入不重复 SVA；
- `tb/sv/lcvex_fetch_fifo_tb.sv`、`sim/cocotb/test_fetch_fifo.py`：覆盖 load-use/stall
  下 FIFO refill duplicate；
- `sim/difftest/test_program.py`、`sim/difftest/run_f1a.sh`：加入 strict lockstep 回归。

在修复完成前保持 `FETCH_FIFO_ENABLE=0`，F1b 继续阻断。

## Evidence 链

- [诊断报告](../F1A_COMMIT_DIVERGENCE.md)
- [evidence](../tasks/evidence/T-20260830-044.json)
