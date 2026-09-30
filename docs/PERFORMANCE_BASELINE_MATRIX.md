# LCVEX PE-F0 性能计数与缓存配置矩阵基线

> 任务：T-20260830-037 PE-F0
> 状态：**基线测量完成**。结果仅为 Verilator 仿真代理，不是 A10/Fmax/架构签核；未启动 Quartus，未实施性能优化。
> 数据文件：
> - 结构化 JSON：`docs/evidence/artifacts/T-20260830-037/perf_baseline_matrix.json`
> - CSV：`docs/evidence/artifacts/T-20260830-037/perf_baseline_matrix.csv`
> - 可复跑脚本：`scripts/run_perf_matrix.py`、`scripts/build-microbench.sh`、`sim/microbench/perf_runner.py`

## 1. 元数据

| 项目 | 值 |
| --- | --- |
| 代码基线 | `b47175ea90f55ec3ba4873e617e2ac9aab0efdd6`（feature/p7-final 最新 HEAD） |
| 任务分支 | `feature/T-20260830-037-pe-f0-baseline` |
| worktree | `/home/chiro/projects/mycpu/lcvex-wt-T-20260830-037` |
| Verilator | 5.050 2026-07-01 rev conda-forge build 0 |
| 交叉编译器 | aarch64-linux-gnu-gcc (GCC) 16.1.0 |
| perf 编译选项 | `-O2` |
| 最大周期 | 5,000,000 |
| 重型构建 | 每个 runner 单独构建，`VERILATOR_JOBS=1`，`systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0` |
| 测量资源 | 运行期 RSS 约 136 MiB；测量期间存在无关外部 Verilator 构建，wall time 不作为性能结论 |

## 2. 配置矩阵

| 代号 | I-L1 | D-L1 | L2 | MEM_DELAY_MODE | 说明 |
| --- | --- | --- | --- | --- | --- |
| `nocache_d0` | 0 | 0 | 0 | 0 | P-line 默认无缓存 + 1-cycle RAM |
| `l1i_d0` | 1 | 0 | 0 | 0 | 仅指令 L1 |
| `l1d_d0` | 0 | 1 | 0 | 0 | 仅数据 L1（写通/no-write-allocate） |
| `l1id_d0` | 1 | 1 | 0 | 0 | I+D-L1 |
| `l1id_l2_d0` | 1 | 1 | 1 | 0 | I+D-L1 + 统一 L2 |
| `nocache_d1` | 0 | 0 | 0 | 1 | 无缓存，固定 +1 周期响应 |
| `nocache_d2` | 0 | 0 | 0 | 2 | 无缓存，随机 0..4 周期延迟 |
| `fullcache_d1` | 1 | 1 | 1 | 1 | 全缓存，固定 +1 周期响应 |
| `fullcache_d2` | 1 | 1 | 1 | 2 | 全缓存，随机 0..4 周期延迟 |

所有 workload 均以相同的 `build/microbench/perf_*.bin` 运行；同一 workload 在不同配置下的镜像 hash 一致。

## 3. 指标定义

| 指标 | 定义/采集方式 |
| --- | --- |
| `cycles` | MAGIC store 被提交包捕获时的仿真周期数；超时记为 `max_cycles` |
| `retired_insn` | 每个周期统计 `commit_valid && commit_ready`，即架构提交指令数 |
| `ipc` | `retired_insn / cycles`（超时行不代表瞬时 IPC） |
| `stall_if` | 核心 `stall_if` 信号为高的周期数（总前端/流水冻结代理） |
| `fetch_wait` | `fetch_pending || fetch_got_data || fetch_translated` 为高的周期数（在途取指等待代理） |
| `branch_flush` | `flush_id` 为高的周期数（分支重定向冲刷代理） |
| `mem_stall` | `dmem_pending || mem_busy` 为高的周期数（数据访存等待代理） |
| `ptw_stall` | `fetch_walk || data_mmu_issue` 为高的周期数（MMU 页表遍历代理） |
| `il1_*` | I-L1 upstream/hit/miss/refill_beat/downstream 事件脉冲计数 |
| `dl1_*` | D-L1 upstream/read_hit/read_miss/write/refill_beat/downstream 事件脉冲计数 |
| `l2_*` | L2 upstream/read_hit/read_miss/write/refill_beat/downstream 事件脉冲计数 |
| `requests.arb` | 仲裁器接受的内存请求数（含 PTW/I/D） |
| `requests.ram` | 最终进入 SRAM 的请求数（近似内存/总线事务数；MMIO 未计入 perf workload） |

> 这些 stall 和 cache 计数为只读观测代理，不修改架构状态；不是 ARM PMU 级精确性能事件。

## 4. 汇总结果

| 配置 | 通过 | 超时 | 通过项 cycles 合计 | 通过项 IPC 均值 | 通过项 RAM 请求合计 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `nocache_d0` | 14/14 | 0 | 17,971,370 | 0.2376 | 4,750,906 |
| `l1i_d0` | 14/14 | 0 | 17,973,482 | 0.2376 | 482,401 |
| `l1d_d0` | 13/14 | 1 | 14,656,594 | 0.2589 | 4,090,855 |
| `l1id_d0` | 13/14 | 1 | 14,658,568 | 0.2589 | 297,488 |
| `l1id_l2_d0` | 13/14 | 1 | 15,158,642 | 0.2503 | 250,037 |
| `nocache_d1` | 12/14 | 2 | 17,251,008 | 0.1734 | 3,136,098 |
| `nocache_d2` | 9/14 | 5 | 7,155,308 | 0.1054 | 875,868 |
| `fullcache_d1` | 13/14 | 1 | 15,658,716 | 0.2423 | 250,037 |
| `fullcache_d2` | 13/14 | 1 | 16,136,201 | 0.2351 | 250,037 |

> 通过项 cycles 合计受超时 workload 缺失影响，不宜直接跨配置比较绝对值；第 5 节给出 delay-0 公共 13 项对比。

### 5. delay-0 公共 13 项（排除 `mem_random` 超时）直接对比

| 配置 | 13 项总周期 | 相对 nocache | 说明 |
| --- | ---: | ---: | --- |
| `nocache_d0` | 14,063,592 | 0% | 基线 |
| `l1i_d0` | 14,065,592 | +0.014% | 几乎中性，RAM 请求降至约 1/10 |
| `l1d_d0` | 14,656,594 | +4.22% | 写通 D-L1 不改善周期，反而增加 |
| `l1id_d0` | 14,658,568 | +4.23% | 同 D-L1 趋势 |
| `l1id_l2_d0` | 15,158,642 | +7.79% | L2 进一步降低 RAM 请求但周期更多 |

**核心里程碑结论**：当前缓存配置不是周期性能收益来源；它主要降低内存/总线事务数。原因是当前流水线单个 outstanding、访存等待时整流水冻结，缓存命中节省的请求数无法转化为并行/隐藏延迟。

## 6. 关键 workload 代表数据

| Workload | nocache_d0 | l1i_d0 | l1d_d0 | l1id_l2_d0 | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| `alu_latency` | 2,500,171 | 2,500,267 | 2,500,195 | 2,500,411 | 缓存几乎无影响 |
| `alu_ilp` | 2,520,238 | 2,520,350 | 2,520,262 | 2,520,510 | 缓存几乎无影响 |
| `ctrl_branch` | 2,330,280 | 2,330,408 | 2,330,338 | 2,330,652 | 分支/取指为主 |
| `muldiv` | 848,421 | 848,613 | 848,445 | 848,853 | 多周期 EX 为主 |
| `mem_seq` | 3,042,223 | 3,042,335 | 3,469,043 | 3,862,695 | D-L1 反而更慢；RAM 请求大减 |
| `mem_random` | 3,907,778 | 3,907,890 | timeout | timeout | 随机访存+单 outstanding 最脆弱 |
| `mem_ldst` | 1,120,538 | 1,120,682 | 1,255,802 | 1,329,866 | 访存延迟主导 |
| `kernel_crc` | 184,738 | 184,898 | 186,372 | 188,310 | 小循环 |
| `kernel_matmul` | 497,454 | 497,566 | 500,292 | 503,354 | 规则访存 |
| `kernel_sort` | 255,687 | 255,767 | 272,917 | 290,307 | 分支+不规则访存 |
| `fp_scalar` | 226,593 | 226,961 | 226,647 | 227,433 | FP 链 |
| `neon_vect` | 227,526 | 227,782 | 235,918 | 244,784 | 向量访存 |

完整 14 workload × 9 配置位于 JSON/CSV。

## 7. 缓存命中与事务削减

I-L1 命中率极高（以 `alu_latency` 为例 750,045/750,050 ≈ 99.999%），使仲裁器/RAM 请求从约 750k 降到约 59。D-L1 在顺序/规则访存中有较高读命中，但写通/no-write-allocate 引入额外下游写和 refill 阻塞；`mem_seq` 的 D-L1 读命中约 89%，RAM 请求从 1.03M 降到 0.20M（I+D+L2），周期却从 3.04M 增到 3.86M。

`mem_random` 在 D-L1/全缓存配置下均在 5M 内未完成，说明随机访问的 miss/refill 在单 outstanding 下被完全串行暴露。

## 8. 最大收益方向与 F1/F3 建议

1. **当前最大可衡量收益是“总线/内存事务削减”**，不是周期。I-L1、D-L1、L2 可把 RAM 请求降低 1~20 倍，但 delay-0 公共 13 项周期反而 +0.01%~+7.8%。
2. **周期瓶颈来自访存延迟暴露与流水线单 outstanding**：`mem_seq`/`mem_random`/`mem_ldst` 的 `mem_stall` 和 `fetch_wait` 很高；加入缓存后请求数下降但等待无法隐藏。
3. **F3（受限 outstanding / MSHR / store buffer）应是内存密集型方向的最高优先实施项**：本矩阵证明“缓存已能把事务减下去，但单 outstanding 把延迟摊在关键路径上”，F3 可直接把已降低的事务数转化为 MLP/IPC。
4. **F1（取指 FIFO / early restart / critical-word-first）仍作为前端前提保留**：在 1-cycle RAM 基线上单独 I-L1 没有周期收益，不能证明 F1 有独立大收益；但 branch/ALU 类仍有大量 `branch_flush`/`fetch_wait`，F1 仍是后续 2-wide 和真实内存延迟下值得实施的方向。
5. **建议优先级**：F3 优先（P1 中最高价值），F1 与 F3 可并行设计但合入需串行；当前不优先投入独立 cache 容量/策略优化（F4/F5/F8），因为在本矩阵中缓存命中/事务收益已足够，缺的是并行与延迟隐藏。

## 9. 复现命令

```sh
# 1) 构建某个配置的 runner（一次一个，cgroup <16GiB）
systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0 -- \
  make VERILATOR_JOBS=1 PERF_RUNNER_DIR=build/microbench_runner_l1id_l2_d0 \
    PERF_I_L1=1 PERF_D_L1=1 PERF_L2=1 PERF_MEM_DELAY_MODE=0 \
    microbench-build-config

# 2) 构建 perf 镜像
make perf-build PERF_NAME=mem_seq

# 3) 跑完整矩阵（或 --aggregate-only 聚合已有 JSON）
python3 scripts/run_perf_matrix.py --configs all --workloads all --skip-build \
  --out-dir build/perf_matrix
python3 scripts/run_perf_matrix.py --configs all --workloads all --aggregate-only \
  --out-dir build/perf_matrix
```

## 10. 已知限制

- 未启动 Quartus；无 FPGA 频率/资源结论。
- `MEM_DELAY_MODE=2` 使用固定 LFSR 随机延迟 0..4 周期，不是 4/16/32 固定延迟；本仓库现有延迟注入器不支持更大固定延迟。
- 未实现 B5 WB cache / AXI 总线矩阵；矩阵仅覆盖 M1-B 单事务内存路径。
- `memory stall/fetch stall` 为内部信号周期代理，不是 ARM PMU 精确事件。
- 测量期间存在无关外部 Verilator 重型构建，因此 wall time 不是稳定性能指标；周期/计数仍为确定性仿真结果。
- 超时表示该 workload 在 5M 周期内未到达 MAGIC，不视为失败的数据“通过”。
