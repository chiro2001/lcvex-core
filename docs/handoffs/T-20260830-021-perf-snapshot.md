# Handoff T-20260830-021: P-SNAPSHOT 性能线全量快照

## 元数据

- task: T-20260830-021
- owner: T-20260830-021 (P-SNAPSHOT)
- date: 2026-08-30
- base_sha: `f7cf6d5ba6391e9877e8efe09a8d48969d77e59b`
- head_sha: `15463d9846d32502264bcda1c14ba4231c6f9370`（实现/证据内容提交）
- branch: `feature/T-20260830-021-perf-snapshot`
- worktree: `/home/chiro/projects/mycpu/lcvex-wt-T-20260830-021`
- dependencies: P-INFRA/P-ALU/P-MEM/P-FP/P-MIXED/P-FIX
- qemu_release: 不使用
- rtl_filelist_sha: 见 evidence
- config/toolchain: Verilator 5.050；aarch64-linux-gnu-gcc 16.1.0；`PERF_MAX_CYCLES=5000000`，`PERF_CFLAGS=-O2`
- evidence: `docs/tasks/evidence/T-20260830-021.json`

## 目标与边界

在当前主线上重建 `build/microbench_runner/microbench_runner`，并在 5M cycle
上限内运行全部 14 个 perf workload，保存每个 JSON，汇总性能快照。本任务只做
仿真性能代理数据采集，不启动 Quartus，不宣称 A10/Fmax/架构签核。

## 实现摘要

- 改动文件：
  - `docs/PERFORMANCE_SNAPSHOT.md`：14 workload 汇总表、环境、复现命令和限制。
  - `docs/evidence/artifacts/T-20260830-021/perf_snapshot.json`：聚合 JSON。
  - `docs/evidence/artifacts/T-20260830-021/perf_<name>.json`：14 个单 workload JSON。
  - `docs/handoffs/T-20260830-021-perf-snapshot.md`：本交接。
  - `docs/tasks/evidence/T-20260830-021.json`：精确验证事实。
- 未改动：
  - 未修改 RTL、`baremetal/perf/**` workload 源码、`sim/microbench/**` runner 源码。
  - 未启动 Quartus，未做 FPGA/Fmax。
- 重型重建：
  - 使用 `systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0`，
    `VERILATOR_JOBS=1`，执行 `make microbench-build`（全量重建，非增量）。
  - 实际 runner 重建 wall 296.546 s，峰值 RSS 3587.5 MB（低于 15G 限制）。

## 验证证据

| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-runner-rebuild-001 | L0 | 重建 runner PASS |
| owner-perf-alu_latency-001 … owner-perf-kernel_sort-001 | L0 | 14/14 workload 全部 PASS |

精确命令、SHA、耗时、RSS、artifact manifest 以 evidence JSON 为准。

## 结果汇总

| workload | status | cycles |
|---|---:|---:|
| alu_latency | pass | 2500171 |
| alu_ilp | pass | 2520238 |
| ctrl_branch | pass | 2330280 |
| muldiv | pass | 848421 |
| mem_seq | pass | 3042223 |
| mem_random | pass | 3907778 |
| mem_ldst | pass | 1120538 |
| fp_scalar | pass | 226593 |
| fp_fp16 | pass | 254247 |
| neon_vect | pass | 227526 |
| kernel_crc | pass | 184738 |
| kernel_hash | pass | 55476 |
| kernel_matmul | pass | 497454 |
| kernel_sort | pass | 255687 |

- 全部在 `PERF_MAX_CYCLES=5000000` 下完成。
- 14 个 workload 单次运行墙钟合计约 122.605 s。
- 聚合 JSON：`docs/evidence/artifacts/T-20260830-021/perf_snapshot.json`。

## 失败现场/重现

无失败。若需复现：

```sh
# 重建 runner（一次一个重型构建，cgroup <16GiB / MemorySwapMax=0 / VERILATOR_JOBS=1）
systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0 -- make VERILATOR_JOBS=1 microbench-build

# 单个 workload 示例
make perf-build PERF_NAME=alu_latency
python3 sim/microbench/perf_runner.py \
  --runner build/microbench_runner/microbench_runner \
  --image build/microbench/perf_alu_latency.bin \
  --name alu_latency --max-cycles 5000000 \
  --out docs/evidence/artifacts/T-20260830-021/perf_alu_latency.json
```

## 已知限制与后续任务

- 这是 Verilator 仿真性能代理，不是 A10/Fmax/架构签核。
- 未启动 Quartus，未做板级/物理验证。
- 当前 RTL/microbench 的 FP/NEON 指令子集有限，workload 已避开不支持路径。
- 若后续新增 FP/NEON workload，需同步加入 `scripts/build-microbench.sh` 的 FP 白名单。
- 本快照可作为后续性能回归的基线；比较时应固定 source SHA、工具链和 workload 默认参数。

## 集成说明

- owner 已提交 handoff/evidence；集成者可复核后合入 `feature/p7-final`。
- 合入后按模板应由集成者在 merge SHA 复跑至少 `owner-perf-*` 子集并补 `merge_sha`。
