# T-20260830-022 FINAL-GATED 本地回归证据

- SHA: `a110ba3aeea212834edd86949845bd07eda99aba`
- Branch/Worktree: `feature/T-20260830-022-final-gated` / `/home/chiro/projects/mycpu/lcvex-wt-T-20260830-022`
- 环境: Verilator 5.050, Cocotb 2.0.1, Python 3.12.14, QEMU 11.1.0 fork 84f07211, aarch64 gcc 16.1.0
- Cgroup: `systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0 -p MemoryAccounting=yes`
- 重型构建: `VERILATOR_JOBS=1`, `MAKEFLAGS=-j1`, 一次一个重型构建/运行；Gate D 锁步阶段使用 `--parallel` 由 planner 并行。

## 结论

| 项目 | 结果 | 关键指标 |
| --- | --- | --- |
| `make test` | PASS | wall 867.749s, peak 3,499,208,704 B (~3.26 GiB) |
| Gate D 全量 `--parallel` | PASS | wall 1717.841s, peak 5,852,987,392 B (~5.45 GiB), 0 failures |
| CORE_COUNT=1 cluster lint | PASS | wall 25.751s, peak 422,805,504 B |
| l2_cluster CORE_COUNT=1 lint | PASS | wall 0.887s, peak 68,149,248 B (既有 UNSIGNED warning) |
| 可选 C3 cluster4_multi TB | PASS | wall 23.814s |
| 可选 C4 cluster8 TB | PASS | wall 28.282s |

## 日志

- `make_test_T022.log.txt`
- `gate_d_T022.log.txt`
- `core_count_1_cluster_lint_T022.log.txt`
- `core_count_1_l2_cluster_lint_T022.log.txt`
- `c3_cluster4_multi_T022.log.txt`
- `c4_cluster8_T022.log.txt`

## 边界

未启动 Quartus；无 FPGA/上板/CI。完整 fourcore 系统级 TB 未单独运行；可选 C3/C4 覆盖为模块级多核 TB。
