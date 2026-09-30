# LCVEX 性能验证工作负载线（P-line/性能线）

> 目的：在现有功能验证之外，建立可重复、可比较的 CPU 性能 workload。
> 原则：先正确后性能；不把微基准结果写成架构签核；RTL/FPGA 性能仍受 T-067 阻塞。

## 1. 范围

- 单核/FP/NEON/访存/整数/控制流 microbenchmark
- 双核/四核一致性相关 workload（C2 可用；C3 稳定后扩展）
- 混合真实 kernel（CRC、矩阵乘、排序、内存密集型等）
- 通用测量与报告基础设施（cycle 计数、JSON、SHA、可复现参数）

## 2. 目标

- 形成一组可单独运行、结果可对比的 baremetal 性能程序。
- 记录：cycle 数、wall time、RSS、编译 SHA、工具版本、配置参数。
- 报告：延迟、吞吐、ILP、访存层次、FP/NEON 吞吐、多核伸缩。
- 明确“这是性能代理数据，不是 A10/Fmax 签核”。

## 3. 任务拆分

| ID | 任务 | 负责内容 | 写集边界 |
|---|---|---|---|
| T-20260830-009 | P-parent | 规划/集成性能线 | docs、集成 |
| T-20260830-010 | P-INFRA | perf 构建/运行/报告基础设施 | `scripts/build-microbench*.sh`、`sim/microbench/*`、`baremetal/microbench_main.c`、`baremetal/perf/perf_common.h`、Makefile、docs |
| T-20260830-011 | P-ALU | 整数/控制流性能 workload | `baremetal/perf/t_alu_*.c`、`t_ctrl_*.c` |
| T-20260830-012 | P-MEM | 访存层次/带宽/延迟 workload | `baremetal/perf/t_mem_*.c` |
| T-20260830-013 | P-FP | FP/NEON 标量/向量吞吐与延迟 | `baremetal/perf/t_fp_*.c`、`t_neon_*.c` |
| T-20260830-014 | P-MC | 双核/多核消息/竞争/伸缩 workload | `baremetal/perf/t_mc_*.c`、适用 TB |
| T-20260830-015 | P-MIXED | 混合 kernel（CRC/矩阵/排序/哈希等） | `baremetal/perf/t_kernel_*.c` |

## 4. 测量方法

- 优先使用现有 `microbench_runner`：程序结束时写 MAGIC，runner 记录完成 cycle。
- P-INFRA 增加：
  - 每条 perf 测试可单独编译运行（`PERF_ONLY=<name>`）
  - 输出 JSON：`{name, sha, params, cycles, wall_sec, rss, status}`
  - SHA 绑定源码、工具链、裸机镜像
- 不在 microbench 中做“性能通过/失败”断言，只记录数据；功能断言仍可用 CHECK。

## 5. 验收口径

- 每个 workload 在指定 SHA 上：可构建、可运行、有 cycle 报告。
- 不宣称 A10 Fmax/LC；不宣称 Linux SMP/板级性能。
- C3 稳定前，MC 性能只用 C2 或 synthetic baseline。
- C4 8/16/32 性能按 C4-pre 口径单独报告。

## 6. 当前状态

- 规划创建：2026-08-30
- 任务并行派发中。
- P-INFRA 已提供基础构建/JSON 报告能力（见下节）。

## 7. 基础设施用法

### 7.1 workload 文件约定

- 位置：`baremetal/perf/t_<name>.c`。
- 每个 workload 导出 `int run_perf_<name>(void)`，返回 0 即可；
  功能自检可用 `PERF_CHECK`/`CHECK` 累计失败，但性能结论不以返回码判定。
- 公共辅助宏在 `baremetal/perf/perf_common.h`：
  - `PERF_NOINLINE`、`PERF_INLINE`、`PERF_VOLATILE`；
  - `PERF_USE(x)` / `perf_use()`、`perf_barrier()` 防优化；
  - `PERF_LOOP(var, n)` 循环辅助；
  - `PERF_DECL(name)` 导出声明。
- P-ALU/MEM/FP/NEON/MC/KERNEL 的 `t_*.c` 内容由各自任务负责；P-INFRA 只提供
  构建/运行/报告链路，不修改这些 workload。

### 7.2 单独构建

```bash
# 构建裸机 perf 镜像（默认 build/microbench/perf_<name>.bin）
PERF_ONLY=smoke bash scripts/build-microbench.sh

# 也支持 t_ 前缀或 .c 后缀（脚本自动规范化）
PERF_ONLY=t_smoke.c bash scripts/build-microbench.sh

# 或用 Makefile
make perf-build PERF_NAME=smoke
```

注意：perf 构建不传 `-mgeneral-regs-only`，以便 FP/NEON workload 使用 SIMD/FP
指令；原 `mb_all` / `MB_ONLY` 路径保持不变。
如需覆盖编译选项，可设置 `PERF_CFLAGS`，例如
`PERF_CFLAGS="-O2 -march=armv8.2-a+fp16"`。

### 7.3 运行并输出 JSON

推荐使用 Python 封装：

```bash
# 使用已构建的 Verilator runner（若不存在先构建 runner）
python3 sim/microbench/perf_runner.py \
  --runner build/microbench_runner/microbench_runner \
  --image build/microbench/perf_smoke.bin \
  --name smoke \
  --param iters=1000

# Makefile 入口（perf 只构建镜像和调用已有 runner；perf-full 会补建 runner）
make perf PERF_NAME=smoke PERF_PARAM=iters=1000
make perf-full PERF_NAME=smoke PERF_PARAM=iters=1000
```

JSON 字段：

```json
{
  "name": "smoke",
  "sha": "<repo head SHA>",
  "git_sha": "<repo head SHA>",
  "source_hash": "<baremetal 源码+构建脚本哈希>",
  "source_sha256": "<baremetal 源码+构建脚本哈希>",
  "image_hash": "<裸机镜像 SHA256>",
  "image_sha256": "<裸机镜像 SHA256>",
  "toolchain": "aarch64-linux-gnu-gcc (GCC) ...",
  "cycles": 1234,
  "wall_sec": 0.012345,
  "rss_kb": 12345,
  "rss": 12.05,
  "status": "pass",
  "params": {"iters": "1000"},
  "runner": "...",
  "command": ["..."]
}
```

- `status`：`pass` / `fail` / `timeout` / `error`。
- `cycles` 由 `microbench_runner` 从 MAGIC store 提交包采集。
- `params` 可用 `--params "free text"`（字符串）或重复 `--param k=v`（对象）。
- 报告可直接重定向保存，例如
  `... --out build/microbench/perf_smoke.json`。

### 7.4 可重复性与资源约束

- `git_sha` 绑定当前仓库 HEAD；`image_sha256` 绑定镜像；`source_sha256` 绑定
  workload C、公共头、微基准主程序、启动/链接脚本和构建脚本。
- 重型 Verilator runner 构建按项目规范执行：
  `VERILATOR_JOBS=1`，并使用 cgroup `MemoryMax<16GiB`、`MemorySwapMax=0`，
  一次一个；不要与 FPGA/C3 等重型构建并发。
- 不启动 Quartus；本基础设施输出仅为性能代理数据，不构成 A10/Fmax/架构签核。
