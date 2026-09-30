# LCVEX 性能线全量快照（T-20260830-021 P-SNAPSHOT）

> 本文件记录在当前主线上重建 Verilator runner 后，全部 14 个 perf workload 的 L0 仿真代理性能数据。
> **不是 A10/Fmax/架构签核**；未启动 Quartus；结果仅供后续性能对比。

## 元数据

- 任务：T-20260830-021 P-SNAPSHOT
- 代码基线 source SHA：`f7cf6d5ba6391e9877e8efe09a8d48969d77e59b`
- 快照实际运行 HEAD：`0055eaf10f9050eef6a2f852ef80e94aba5c5ef1`
- 分支：`feature/T-20260830-021-perf-snapshot`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260830-021`
- 创建时间：2026-08-30T05:04:06+08:00
- Verilator：5.050 2026-07-01 rev conda-forge build 0
- 交叉编译器：aarch64-linux-gnu-gcc (GCC) 16.1.0
- 编译选项：`PERF_CFLAGS=-O2`
- 最大周期：5000000
- cgroup：`systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0`
- runner 重建耗时：296.546 s，峰值 RSS：3587.5 MB

## 14 个 workload 汇总

| # | workload | status | cycles | wall (s) | RSS (MiB) |
|---:|---|---|---:|---:|---:|
| 1 | alu_latency | pass | 2500171 | 15.820 | 136.38 |
| 2 | alu_ilp | pass | 2520238 | 15.488 | 136.10 |
| 3 | ctrl_branch | pass | 2330280 | 15.139 | 136.07 |
| 4 | muldiv | pass | 848421 | 6.050 | 136.07 |
| 5 | mem_seq | pass | 3042223 | 18.496 | 136.05 |
| 6 | mem_random | pass | 3907778 | 23.284 | 136.22 |
| 7 | mem_ldst | pass | 1120538 | 7.704 | 136.00 |
| 8 | fp_scalar | pass | 226593 | 2.901 | 136.38 |
| 9 | fp_fp16 | pass | 254247 | 3.125 | 136.88 |
| 10 | neon_vect | pass | 227526 | 3.212 | 137.12 |
| 11 | kernel_crc | pass | 184738 | 2.463 | 136.24 |
| 12 | kernel_hash | pass | 55476 | 1.806 | 136.02 |
| 13 | kernel_matmul | pass | 497454 | 4.207 | 136.00 |
| 14 | kernel_sort | pass | 255687 | 2.911 | 136.25 |

**汇总：** 14/14 pass；总运行墙钟 122.605 s；周期合计 17971370。

## 归档

- 聚合 JSON：`docs/evidence/artifacts/T-20260830-021/perf_snapshot.json`
- 单 workload JSON：`docs/evidence/artifacts/T-20260830-021/perf_<name>.json`
- 精确验证事实：`docs/tasks/evidence/T-20260830-021.json`
- 交接文档：`docs/handoffs/T-20260830-021-perf-snapshot.md`

## 复现命令

```sh
# 1) 重建 runner（一次一个重型构建，cgroup <16GiB / MemorySwapMax=0 / VERILATOR_JOBS=1）
systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0 -- make VERILATOR_JOBS=1 microbench-build

# 2) 单个 workload 构建+运行并输出 JSON（以 alu_latency 为例）
make perf-build PERF_NAME=alu_latency
python3 sim/microbench/perf_runner.py \
  --runner build/microbench_runner/microbench_runner \
  --image build/microbench/perf_alu_latency.bin \
  --name alu_latency --max-cycles 5000000 \
  --out docs/evidence/artifacts/T-20260830-021/perf_alu_latency.json
```

## 边界与已知限制

- Performance data is simulation proxy only; not A10/Fmax or architecture sign-off.
- No Quartus or FPGA physical implementation was started.
- Heavy Verilator build used VERILATOR_JOBS=1 and cgroup MemoryMax=15G/MemorySwapMax=0; one heavy build at a time.
- Current RTL/microbench target has limited FP/NEON instruction subset; workloads already avoid unsupported FP/NEON paths.
- Workload cycle counts are whole-program measured cycles from Verilator, not architectural IPC/signoff metrics.
