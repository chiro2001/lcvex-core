# F1a `nocache_d2` 三项性能回退只读诊断

> 任务：`T-20260901-006`（PE-F1G-D2-PERF-AUDIT）<br>
> 状态：review；本报告只做归档 counter 重算和 RTL 静态审阅，不做动态复测或修复。<br>
> base_sha：`aa60cfec24ca880841257ccc80e96f8138caf023`<br>
> measurement_source_sha：`3816c95a92692e336b2c2063d9d7ef7f998d6b0f`<br>
> report_tip：见最终报告（承载文档的 Git tip 不在 evidence 自引用）<br>
> received_at：`2026-09-01T07:14:38+08:00`；reported_at：`2026-09-01T07:21:34+08:00`

## 结论

T-004 v2 归档矩阵的 196 行/98 对数据可重算，196 行均 `pass`，98/98 的严格架构
字段相等，只有以下三个 `nocache_d2` pair 的 `2%+64` cycle guard 失败：

| workload | F0 cycles | F1a cycles | 差值 | 增幅 | guard 上限 | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `alu_latency` | 5,795,747 | 6,219,933 | +424,186 | +7.319% | 5,911,725.94 | FAIL |
| `ctrl_branch` | 5,172,730 | 5,749,229 | +576,499 | +11.145% | 5,276,248.60 | FAIL |
| `mem_seq` | 7,273,882 | 7,456,315 | +182,433 | +2.508% | 7,419,423.64 | FAIL |

归档 counter 支持的最强判断是：回退与 F1a 两项 FIFO/epoch stale-quarantine 路径
和 `MEM_DELAY_MODE=2` 的响应等待强相关，不能归因于缓存命中、数据访存数量、PTW
或新增分支 flush。`alu_latency` 和 `ctrl_branch` 的额外周期尤其表现为
`stall_if`/`fetch_wait` 增长；`mem_seq` 的 `fetch_wait` 和 `mem_stall` 反而下降，
所以三项不能在没有动态 trace 的情况下宣称为完全同一根因。

证据等级为“归档 counter + 静态路径的相关性诊断”，尚未达到因果证明。F1a 默认
开关和性能签核继续阻塞；`2%+64` 阈值及 98/98 架构门槛均保持不变。

## 1. 范围、来源和统计口径

本任务读取 T-004 的权威 artifact：

- [`f1f_v2_matrix.json`](evidence/artifacts/T-20260901-004/f1f_v2_matrix.json)，
  1,356,853 bytes，SHA256
  `7a166c9e2104dc0c060ee2f3aaa9d2cc09fecc8ac757b8ff69f84948c0937e2a`；
- [`f1f_v2_matrix.csv`](evidence/artifacts/T-20260901-004/f1f_v2_matrix.csv)，
  81,251 bytes，SHA256
  `f71d0b4e05758d389101cce689cdd97c4e6adde316ff57f6248670a9064d74af`。

独立只读核对得到 JSON/CSV 均为 196 行、pair key 完全一致，commit digest schema
为 `lcvex-commit-digest-v2-active-payload` 的 196/196 行，状态为 `pass` 的 196/196
行，严格字段为 98/98 对相等。三项目标 pair 的 measurement source、workload
source 和 image hash 在 F0/F1a 内均相同。mode 2 由 `lcvex_mem_delay` 的固定
`SEED=8'hA5` LFSR 产生 0..4 周期的伪随机延迟；它是可复现的调度交互，不应当用
“随机噪声”替代解释。

所有 delta 均定义为 `F1a - F0`。runner 的 `stall_if`、`fetch_wait`、`mem_stall`
等是周期观测代理，谓词彼此可以重叠，不能把各列相加当成精确 cycle 分解：

- `stall_if` 直接采样 `core.stall_if`；其中 `stall_id` 包含 `fetch_stale_drain`。
- `fetch_wait` 是 `fetch_pending`、`fetch_got_data`、`fetch_translated` 或
  `fetch_stale_drain` 的并集。
- `mem_stall` 是 `dmem_pending` 或 `mem_busy` 的并集，`branch_flush` 采样
  `flush_id`，`ptw_stall` 采样 fetch/data MMU 请求。

本任务未启动 Verilator、QEMU、Gate D、Linux、Quartus，也未修改 RTL、runner、
workload、比较器、阈值或参考结果。

## 2. 同一 workload 的 delay 横向比较

每个 delay 点内，F0/F1a 只切换 FIFO 开关且其余参数相同；横向比较时仅将
`MEM_DELAY_MODE` 由 0、1、2 改变。下表中的
`Δimem` 是 request 计数差，`stale_drop` 和 `stale_drain` 是 F1a 计数；分支
flush 差值在这九个 pair 中都为 0。

| workload | delay | F0→F1a cycles（差值，增幅） | Δimem | stale_drop | stale_drain | Δstall_if | Δfetch_wait |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 0 | 2,500,171→2,000,136 (-500,035, -20.000%) | +250,009 | 250,007 | 0 | +5 | -500,052 |
| `alu_latency` | 1 | 4,000,283→4,000,264 (-19, -0.000%) | +250,009 | 250,009 | 500,018 | +500,014 | -47 |
| `alu_latency` | 2 | 5,795,747→6,219,933 (+424,186, +7.319%) | +250,009 | 250,009 | 1,054,904 | +1,054,899 | +424,141 |
| `ctrl_branch` | 0 | 2,330,280→1,860,231 (-470,049, -20.171%) | +200,008 | 200,004 | 0 | +20,018 | -530,112 |
| `ctrl_branch` | 1 | 3,750,476→3,740,433 (-10,043, -0.268%) | +220,006 | 220,006 | 440,012 | +420,001 | -110,149 |
| `ctrl_branch` | 2 | 5,172,730→5,749,229 (+576,499, +11.145%) | +220,006 | 220,006 | 901,818 | +884,187 | +428,727 |
| `mem_seq` | 0 | 3,042,223→2,582,793 (-459,430, -15.102%) | +114,801 | 114,778 | 0 | +286,794 | -1,147,983 |
| `mem_seq` | 1 | 5,108,405→5,050,468 (-57,937, -1.134%) | +172,101 | 172,101 | 344,202 | +172,113 | -1,205,348 |
| `mem_seq` | 2 | 7,273,882→7,456,315 (+182,433, +2.508%) | +172,101 | 172,101 | 677,434 | +468,935 | -1,419,485 |

这组对照显示：在 mode 0/1，额外的 wrong-path/stale 取指仍可由 FIFO 的并行度
抵消；mode 2 时同一类额外 request 的响应被随机延迟，等待与管线相位的组合才
暴露出 guard 回退。它说明 delay2/backpressure 交互是合理的后继 probe 方向，
但不证明某一条 RTL 赋值单独造成回退。

## 3. 三个 d2 pair 的完整 counter delta

### 3.1 Stall 代理

| workload | stall_if | fetch_wait | branch_flush | mem_stall | ptw_stall | muldiv_stall | load_use | wb_stall |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `alu_latency` | 59→1,054,958 (**+1,054,899**) | 4,795,687→5,219,828 (**+424,141**) | 250,011→250,011 (0) | 63→58 (-5) | 0→0 (0) | 0→0 (0) | 0→0 (0) | 0→0 (0) |
| `ctrl_branch` | 210,189→1,094,376 (**+884,187**) | 4,262,645→4,691,372 (**+428,727**) | 220,011→220,011 (0) | 230,203→212,572 (-17,631) | 0→0 (0) | 0→0 (0) | 0→0 (0) | 0→0 (0) |
| `mem_seq` | 2,302,267→2,771,202 (**+468,935**) | 6,298,101→4,878,616 (**-1,419,485**) | 172,124→172,124 (0) | 2,531,444→2,322,945 (**-208,499**) | 0→0 (0) | 252→252 (0) | 9→14 (+5) | 0→0 (0) |

`alu_latency`/`ctrl_branch` 的 `stall_if` 增量分别几乎贴合其 stale-drain 增量
（仅受重叠谓词影响），并且 `fetch_wait` 同向增加。`mem_seq` 的 stale-drain 仍为
677,434，但 `fetch_wait` 减少 1,419,485、`mem_stall` 减少 208,499；这正是不能
把三项直接归并为同一个“总 stall”原因的证据。

### 3.2 请求和响应

三项的完整通道 delta 如下；每个单元为 `F0→F1a (Δ)`。

| workload | 方向 | imem | dmem | ptw | arb | l2 | delay_router | ram |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | req | 750,050→1,000,059 (+250,009) | 6→6 (0) | 0→0 (0) | 750,056→1,000,065 (+250,009) | 750,056→1,000,065 (+250,009) | 750,055→1,000,064 (+250,009) | 750,055→1,000,064 (+250,009) |
| `alu_latency` | rsp | 750,050→1,000,059 (+250,009) | 6→6 (0) | 0→0 (0) | 750,056→1,000,065 (+250,009) | 750,056→1,000,065 (+250,009) | 750,056→1,000,065 (+250,009) | 750,056→1,000,065 (+250,009) |
| `ctrl_branch` | req | 690,075→910,081 (+220,006) | 20,023→20,023 (0) | 0→0 (0) | 710,098→930,104 (+220,006) | 710,098→930,104 (+220,006) | 710,097→930,103 (+220,006) | 710,097→930,103 (+220,006) |
| `ctrl_branch` | rsp | 690,075→910,081 (+220,006) | 20,023→20,023 (0) | 0→0 (0) | 710,098→930,104 (+220,006) | 710,098→930,104 (+220,006) | 710,098→930,104 (+220,006) | 710,098→930,104 (+220,006) |
| `mem_seq` | req | 803,658→975,759 (+172,101) | 229,437→229,437 (0) | 0→0 (0) | 1,033,095→1,205,196 (+172,101) | 1,033,095→1,205,196 (+172,101) | 1,033,094→1,205,195 (+172,101) | 1,033,094→1,205,195 (+172,101) |
| `mem_seq` | rsp | 803,658→975,759 (+172,101) | 229,437→229,437 (0) | 0→0 (0) | 1,033,095→1,205,196 (+172,101) | 1,033,095→1,205,196 (+172,101) | 1,033,095→1,205,196 (+172,101) | 1,033,095→1,205,196 (+172,101) |

新增量只出现在取指及其下游路由；三项 d2 的数据访存 request/response 与 F0
完全相同，PTW 也全为 0。`nocache` 路径的 I-L1、D-L1、L2 事件 counters 在
两侧的 `upstream/hit/miss/refill/write/downstream` 全部为 0，因此没有 cache
hit/miss delta 可以解释回退。

### 3.3 FIFO、epoch 和 stale

F0 三项所有 FIFO 字段均为 0/disabled；下表列出 F1a 观测值，`epoch_final` 是
8-bit epoch 的最终值，不能代替累计 bump 数。

| workload | epoch_final | epoch_bumps | occupancy_max/peak | push/pop | flush | stale_drop | stale_drain_cycles | overflow |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 155 | 250,011 | 1/1 | 750,050/750,050 | 250,011 | 250,009 | 1,054,904 | 0 |
| `ctrl_branch` | 107 | 220,011 | 1/1 | 690,075/690,075 | 220,011 | 220,006 | 901,818 | 0 |
| `mem_seq` | 92 | 172,124 | 2/2 | 803,658/803,658 | 172,124 | 172,101 | 677,434 | 0 |

三项均满足 occupancy/peak≤2、overflow=0、push≥pop，且 `epoch_bumps == flush`。
因此已有 counters 没有显示 FIFO 容量越界、epoch 不同步或 stale response 未被
隔离；它们显示的是大量合法的 flush/stale-drain 活动。

## 4. `nocache_d2` 其它 workload 横向比较

下表覆盖同一 `nocache_d2` 配置的全部 14 个 workload。`Δimem` 为 request 差，
其余 delta 为 F1a-F0；`stale_drop`/`stale_drain` 为 F1a 累计值。

| workload | Δcycles（增幅） | guard | Δstall_if | Δfetch_wait | Δimem | stale_drop | stale_drain |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| `alu_ilp` | -69,250 (-1.196%) | PASS | +506,377 | -69,294 | +120,007 | 120,007 | 506,376 |
| `alu_latency` | +424,186 (+7.319%) | **FAIL** | +1,054,899 | +424,141 | +250,009 | 250,009 | 1,054,904 |
| `ctrl_branch` | +576,499 (+11.145%) | **FAIL** | +884,187 | +428,727 | +220,006 | 220,006 | 901,818 |
| `fp_fp16` | -36,494 (-6.107%) | PASS | +34,552 | -36,533 | +8,192 | 8,192 | 34,562 |
| `fp_scalar` | -4,501 (-0.887%) | PASS | +51,918 | -20,382 | +12,339 | 12,339 | 51,930 |
| `kernel_crc` | -28,180 (-6.600%) | PASS | +7,238 | -61,469 | +2,566 | 2,566 | 9,633 |
| `kernel_hash` | -5,952 (-7.148%) | PASS | +2,190 | -38,337 | +1,299 | 1,299 | 3,839 |
| `kernel_matmul` | -40,301 (-5.006%) | PASS | +21,513 | -336,007 | +8,966 | 8,966 | 26,183 |
| `kernel_sort` | -41,890 (-6.820%) | PASS | -10,081 | -153,111 | +8,590 | 8,590 | 29,315 |
| `mem_ldst` | -68,295 (-2.542%) | PASS | +103,671 | -595,737 | +38,917 | 38,917 | 169,985 |
| `mem_random` | -166,254 (-2.711%) | PASS | +229,459 | -2,712,389 | +106,501 | 106,501 | 416,902 |
| `mem_seq` | +182,433 (+2.508%) | **FAIL** | +468,935 | -1,419,485 | +172,101 | 172,101 | 677,434 |
| `muldiv` | -17,567 (-1.930%) | PASS | +30,165 | -671,861 | +12,009 | 8,013 | 30,167 |
| `neon_vect` | +10,361 (+1.977%) | PASS | +43,114 | -44,129 | +10,745 | 10,745 | 45,394 |

`alu_ilp`、`mem_random` 等通过项也可能有很大的 stale-drain 或 `stall_if` 增量，
但其 `fetch_wait` 下降足以覆盖该开销；反例是三个失败项的等待/执行相位组合。
`muldiv` 的 push/pop 和 stale 计数受未完成乘除窗口影响，说明 counters 是观测
代理，不能从单个计数器推出精确因果链。

## 5. RTL 静态路径审阅

审阅冻结 source 中 [`rtl/lcvex_core.sv`](../rtl/lcvex_core.sv) 和
[`rtl/lcvex_mem_delay.sv`](../rtl/lcvex_mem_delay.sv)，得到以下可验证路径：

1. `fetch_fifo_active` 只在 `FETCH_FIFO_ENABLE!=0 && FETCH_FIFO_DEPTH==2` 时成立
  （`lcvex_core.sv:831-834`）。F0 清零并走 legacy single-context；F1a 用固定
  两项 ring。
2. `frontend_kill` 包含 `flush_id`、system/exception redirect、IRQ、TLBI 和维护
   起始等条件（`lcvex_core.sv:847-856`）。kill 时 FIFO flush、epoch bump、在途
   old context 进入 stale quarantine。
3. `fetch_fifo_pop` 排除 `frontend_kill`、`fetch_stale_drain`、system hold、数据
   翻译/访存等待、`stall_wb`、`ex_busy` 等（`lcvex_core.sv:862-880`）；FIFO 满时
   只有 pop 才释放 `fetch_fifo_space`。
4. current response 必须有 current epoch；stale response 在
   `imem_rsp_ready` 仍为 1 时被消费并计入 `fetch_stale_rsp_drop`
   （`lcvex_core.sv:882-903`、`1857-1862`）。此后 `fetch_imem_req_valid` 受
   `fetch_stale_drain` 阻塞（`1830-1842`），因此一次 kill 可能表现为“先 drain
   旧响应、再重新请求当前 PC”。这与三项新增 imem 请求/stale drop 相符。
5. `stall_id` 显式包含 `fetch_stale_drain`，并由此传到 `stall_if`
   （`lcvex_core.sv:1810-1819`）；FIFO flush 优先于 push/pop，正常时支持同时
   push+pop（`2081-2149`）。这能解释 `stale_drain` 与 `stall_if` 的强相关，不能
   仅凭计数器证明 ring 的 push/pop 实现错误。
6. `lcvex_mem_delay` mode 2 对每个单 outstanding response 取 LFSR 的 0..4
   延迟，且 `req_ready` 在 request/response pending 时关闭
  （`lcvex_mem_delay.sv:50-70`、`74-109`）。F1a 的 stale drain 因而会直接暴露
   为前端等待；其实际收益/损失仍取决于 workload 的 flush 和访存相位。

现有 F1a SVA 仍是重要边界：`frontend_kill` 禁止同拍 push/pop，stale drain 禁止
新 fetch/MMU issue，FIFO count≤2，push epoch 必须 current（`lcvex_core.sv:4306-4322`）。
归档矩阵的 occupancy/overflow counters 与这些边界一致，但本任务没有重新运行
SVA。

## 6. 证据等级和同源判断

| 判断 | 证据 | 等级 |
| --- | --- | --- |
| 三项不是缓存 miss/PTW/data request 数量导致 | nocache d2 cache 全零；dmem/PTW delta 全零 | 强相关排除 |
| 三项都触发 FIFO stale/重取指活动 | Δimem>0，stale_drop 与 flush 同量级，overflow=0 | 强相关 |
| `alu_latency` 与 `ctrl_branch` 共享前端等待放大模式 | d2 的 Δstall_if、Δfetch_wait 均为大幅正值，branch_flush 不变 | 中强相关 |
| `mem_seq` 与前两项完全同源 | 其 Δfetch_wait、Δmem_stall 为负，只有 Δstall_if/重取指为正 | 未证实，不能合并断言 |
| 已定位某一条 RTL bug | 只有 aggregate counter 和静态审阅，无 per-cycle/per-request trace | 未证实 |

因此当前最合理的统一工作假设是“F1a FIFO stale quarantine 与 delay2 单 outstanding
backpressure 的交互”，并将 `alu_latency`/`ctrl_branch` 视为前端等待放大子类、
`mem_seq` 视为访存相位不同的子类。这个假设必须由后继动态 probe 验证。

## 7. 最小后继动态 probe（本任务不实现）

后继任务只运行 `nocache_d2` 的三个 workload、F0/F1a 共 6 rows，沿用相同 image、
source SHA、LFSR seed、10M 上限和原 `2%+64` guard。每一对在首次 commit 后按
`seq` 在线/紧邻比较：PC、insn、next PC、GPR/SP/NZCV、memory/mem2、exception、
monitor、vector/FP effect 任一字段不同立即停止并保留最近事件。

每周期或事件记录至少包含：

- commit packet 与 `commit_ready`；
- `stall_if`、`fetch_wait`、`branch_flush`、`mem_stall`、`ptw_stall`；
- `if_pc`、`fetch_pc_r`、`fetch_pending`、`fetch_translated`、`fetch_trans_busy`；
- `fetch_epoch`、FIFO occupancy/peak/push/pop/flush、stale drain/drop、
  `fetch_stale_mmu`/`fetch_stale_imem`；
- imem/dmem、arb/L2、delay-router、RAM 的 valid/ready request/response 握手；
- delay block 的 `req_pending`、`rsp_pending`、`delay_cnt`、LFSR phase。

最小后继写集仅需新增诊断观测：
`tb/sv/lcvex_soc_tb.sv` 暴露 delay block 的只读握手/状态，
`sim/microbench/microbench_runner.cc` 增加有界 probe/event 输出和早停条件；现有
`perf_runner.py --trace` 入口可复用，不修改 RTL 功能、workload、比较器或阈值。
若内部信号不适合稳定暴露，可在同一写集中改为固定命名的 read-only probe ports，
仍不改变架构行为。

以下任一条件立即停止该 pair，并保存指令编码、反汇编、最近 commit、RTL/QEMU
状态（本 probe 无 QEMU 则标明 unavailable）：首次 commit 字段差异、FIFO
occupancy>2/overflow、请求/响应握手违反单 outstanding、任一侧 timeout/error、
或资源超出预算。无差异且六行完成后，再根据事件时间轴决定是否立修复任务；不在
probe 任务中偷偷改变 workload 或门槛。

计划资源（估计，不是本任务实测）：独立 sibling worktree、两个 unique runner
变体串行重建、六行串行运行；CPU 1（不超过本地 50%）、内存上限 2 GiB、构建/有界
event artifact 约 512 MiB，预计 wall ≤30 min。不得访问或复用 T-004 的 build、
trace 或失败现场；若需要更长 trace，应使用仓库内任务 artifact 路径并先更新资源
估计。

## 8. 验收边界

本报告完成的是 T-006 的静态 counter delta、横向比较、证据等级和最小 probe 设计。
它不是动态性能复测，也不是 RTL 修复或性能签核。当前决策保持：

- 98/98 严格架构等价与 FIFO bounds 通过，但性能 guard 仍为 95/98；
- F1a 默认配置仍关闭，标准 F0 Gate D 与 F1a-on 性能签核分离；
- 后继动态 probe 只有在 per-cycle 证据闭合后，才能登记最小修复写集。
