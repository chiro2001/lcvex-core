# LCVEX 独立外部性能审计与增强规划（PE-EXT / T-20260830-035）

> 审计角色：独立外部 Agent（只读）<br>
> 审计 worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260830-035`<br>
> 审计分支：`feature/T-20260830-035-pe-ext-audit`<br>
> 审计快照：`cf12ee23787a41eb455a4096c59300f8573fb865`（基线登记为 `e42bf7442044f74b41b4d96584f774116c533069`）<br>
> 日期：2026-08-30<br>
> 性质：源码/文档静态审计与规划；**没有修改 RTL、测试、QEMU，也没有启动 Quartus 或重型仿真**。

## 0. 结论先行

当前系统的主要性能上限不是 ALU 组合逻辑，而是“交付和等待被串行化”：

1. core 每次只请求 4 字节取指，只有一个在途取指和一个响应槽；没有取指队列、BTB、方向预测或返回栈。
2. `mem_busy`、`dmem_pending`、页表遍历和 `ex_busy` 会让 IF/ID/EX/MEM 一起停顿。一个 load/store 在等待响应时，后续不相关指令也不能继续。
3. P-line 默认 `D_L1_ENABLE=0`、`I_L1_ENABLE=0`、`L2_ENABLE=0`，14 项快照是“无缓存 + 1-cycle RAM”的核心代理，不能用来签核缓存收益。
4. 可选的 L1/L2 写通或写回路径都以单阻塞、8 个 8B beat refill/writeback 为主；当前没有 MSHR、写缓冲、critical-word-first 或 hit-under-miss。
5. C2/C3 共享 L2 只保存 MSI 目录元数据，不保存共享数据阵列；cluster 全局一次只处理一个事务，并且 probe 按 sharer 逐个串行。C4 规模证据已显示吞吐随核数下降。
6. M1-B、`mem_delay`、`mem_router`、SRAM、AXI master 均为单 outstanding；Avalon 适配器虽有深度 4 的 CDC FIFO，后端仍是单个 512-bit word、`burstcount=1`。

对用户明确提出的三个问题，外部审计意见是：

| 问题 | 建议 | 原因 |
| --- | --- | --- |
| 更深流水级数？ | **近期不做，P2** | 主要改善 Fmax，不直接改善单发射 IPC；会扩大分支冲刷、前递、异常和系统指令排空成本。只有 STA 证明关键路径受益时才立项。 |
| 顺序 2-wide？ | **后置，P2** | `alu_ilp` 具备方向性动机，但取指带宽、分支气泡、单提交协议和寄存器文件端口尚未准备好；先做双发射会把验证风险前置。 |
| outstanding 访存/MSHR？ | **建议做，P1** | 这是隐藏内存延迟、解除全流水冻结的最高价值架构方向；应先建立可比较的缓存/事务基线，再以 2-entry、保持按序提交的受限版本起步。 |

建议的最短实施路径为：

> **P0 测量闭环与缓存矩阵 → P0 取指缓冲/早取 → P1 受限 MSHR/写缓冲 → P1 共享 L2 数据阵列与 probe 并行化 → P1 总线 burst/事务队列 → P2 Fmax 驱动的深流水和 2-wide。**

上述均为收益假设，不是已经实现的收益或 A10/Fmax/架构签核。

## 1. 审计边界与证据口径

### 1.1 覆盖对象

- core：`rtl/lcvex_core.sv`、`rtl/lcvex_decode.sv`、`rtl/lcvex_alu.sv`、`rtl/lcvex_muldiv.sv`、FP/NEON 执行单元；
- 单核 cache：`rtl/lcvex_l1_i.sv`、`rtl/lcvex_l1_d.sv`、`rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l2.sv`、`rtl/lcvex_l2_wb.sv`、`rtl/lcvex_catapult_soc_coh.sv`；
- 总线/内存：`rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_delay.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_axi4_master.sv`、`rtl/lcvex_axi4_avalon_adapter.sv`、`rtl/lcvex_async_fifo.sv`；
- 多核：`rtl/lcvex_l1_coherence.sv`、`rtl/lcvex_l2_cluster.sv`、`rtl/lcvex_core_wrap.sv`、`rtl/lcvex_cluster_top.sv`、`rtl/lcvex_c3_sysctrl.sv`；
- 测量与契约：`docs/PERFORMANCE_WORKLOAD_PLAN.md`、`docs/PERFORMANCE_SNAPSHOT.md`、`docs/C4_DUALCORE_BASELINE.md`、`docs/C3_FOURCORE_PREWORK.md`、`docs/C4_SCALE_PREWORK.md` 及对应 evidence JSON。

### 1.2 第三方审计原则

- 只把可由当前源码或已归档 evidence 复核的事实写成“现状”；所有性能收益写成待测方向。
- Verilator cycle 只作为同一 runner、同一镜像和同一参数下的代理数据；没有 retired instruction、IPC、cache hit/miss 或带宽计数时，不进行跨 workload 的定量归因。
- C4 synthetic client 的趋势可用于证明“串行模型存在扩展压力”，不能替代完整 core、多核内存模型或 Linux SMP。
- 不因已有 smoke 通过而推断非阻塞、乱序返回、完整 ARM 内存模型或硬件时序已经成立。

## 2. 现状审计

### 2.1 Core：四级顺序流水线与全局停顿

实际寄存器级是 IF/ID、ID/EX、EX/MEM、MEM/WB，架构状态在 `commit_fire` 或 ID 系统指令提交处更新。以下源码事实决定了吞吐上限：

| 观察 | 源码事实 | 性能含义 |
| --- | --- | --- |
| 单发射 | 每周期最多把一条 `ifid` 指令装入 `idex`；没有第二个执行槽。 | `alu_ilp` 中独立指令也只能串行进入流水。 |
| 取指串行 | `fetch_pending`、`fetch_got_data`、`fetch_translated` 各只有一个上下文；`fetch_imem_req` 的 `strb=8'h0F` 表示一次 4B。 | 取指请求/响应/捕获不能形成稳定的每周期供给。 |
| 访存冻结 | `mem_busy = exmem_valid && (exmem_is_load || exmem_is_store)`；`fetch_imem_req_valid` 在 `mem_busy` 时为 0。 | load/store 的响应等待期间不能取指。 |
| 单 outstanding | `dmem_pending = dmem_req_valid || dmem_req_issued`；`exmem_can_adv` 和 `stall_id` 均依赖它。 | 不相关的年轻指令不能隐藏内存延迟。 |
| 分支代价 | 分支在 ID 计算 `d.next_pc`，`flush_id` 清掉 IF/ID 并重定向 `if_pc`；无 BTB/方向预测/RAS。 | 循环、条件分支、调用/返回产生可见气泡。 |
| PTW 争用 | core 的 PTW、D、I 共用 `lcvex_mem_arb`，端口优先级为 PTW > D > I。 | TLB miss/页表遍历会压低取指和数据服务，且优先级不是 QoS。 |
| 多周期单槽 | `ex_busy = (is_muldiv && !muldiv_done) || (fp_div_is_div && !fp_div_done)`，期间 `stall_if` 为真。 | 乘除/FP 除法不能与前端或独立整数指令重叠。 |
| 提交背压 | `stall_wb = memwb_valid && !commit_ready`，向上游传播；提交包按一条指令建立。 | 锁步/消费者抖动会直接转化为流水线停顿；尚无独立 commit FIFO。 |

因此，单纯把某一级拆成更多级不会自动提升 IPC。若不同时提供前端供给和等待隐藏，额外流水级只会增加分支恢复距离以及精确异常的状态量。

### 2.2 Cache：存在多套实现，但测量和服务能力不统一

| 路径 | 当前结构 | 已确认的性能限制 |
| --- | --- | --- |
| P-line `lcvex_soc_tb` | 可选 I-L1、D-L1、旧统一 L2；默认均关闭。 | 快照无法测出缓存层次收益；开启后仍是阻塞 miss。 |
| I-L1 / D-L1（M2） | 64B line、直接映射、单阻塞；miss 用 8 次 8B 下游读。 | 没有 MSHR、预取、bank、critical-word-first；目标 beat 到达后仍要完成整行才响应。 |
| B4/B5 D-L1 + L2-WB | D-L1 写回/写分配，L2 2-way 写回；dirty victim 和 refill 均逐 beat、单 outstanding。 | 写回、写分配、维护和 drain 占用同一状态机；没有写缓冲或 hit-under-miss。 |
| C2/C3 coherent L1 | 每核统一、直接映射、单 outstanding；I/D/PTW 先在核内仲裁。 | 取指和数据共享一条 L1 端点，彼此干扰；`PH_EVICT` 等路径再次串行 cluster 事务。 |
| 共享 L2 cluster | `lcvex_l2_cluster` 只存 `dir_state/dir_sharers/dir_owner/dir_dirty`，`line_buf` 仅为当前事务暂存。 | S 状态共享行不在 L2 命中，ReadShared/ReadUnique 都可能重新读 PoC。 |

写回路径的“成功后才清 dirty/发布 tag”是正确性优点，但在当前单事务链上会把每条 64B line 的代价固定为最多 8 个请求加 8 个响应阶段。优化应先加可观测计数，再分别评估 early-restart、写缓冲和非阻塞 miss，避免以 correctness drain 作为性能热路径。

### 2.3 总线/内存：单 outstanding 贯穿各层

从 `lcvex_mem_arb` 到 `lcvex_mem_delay`、`lcvex_mem_router`、`lcvex_mem_ram`，均只有一个 `in_flight`/`pending` 上下文；仲裁器端口优先级为 PTW > D > I。结果是：即便下游 RAM 或 FPGA EMIF 能承受多个事务，协议上游也不会发出第二个地址。

AXI master 的 `state_q` 只有一个请求上下文（单 ID、单 outstanding），但保留了 LEN/ID/突发字段；这为未来扩展留下接口位置，却没有提供当前并行度。Avalon adapter 的请求/响应异步 FIFO 地址宽度为 2（深度 4），CPU 状态机仍只收集一笔 AXI 事务；后端 `avalon_burstcount` 固定为 1 个 512-bit word。FIFO 深度不能等同于 memory-level parallelism。

### 2.4 多核：全局单事务与串行 probe 是可量化瓶颈

`lcvex_l2_cluster` 在 `S_IDLE` 才选择一个 `arb_sel`，接受后一直持有 `cur_core/cur_idx` 到 `S_RSP`；每核 coherent L1 也只允许一笔未完成请求。对 S→M 或 M owner 迁移，`probe_pending_mask` 经 `first_core()` 每次只取一个 sharer，状态序列为 `S_PROBE_REQ → S_PROBE_WAIT → S_PROBE_COMMIT`。

已归档 C4 synthetic 证据（不是完整 core 性能）如下：

| CORE_COUNT | 目录 owner/sharer 表示 | 最多串行 probe | synthetic 吞吐（lines/cycle） | 说明 |
| ---: | --- | ---: | ---: | --- |
| 8 | 8-bit one-hot | 7 | 0.0521 | 21 tx / 403 cycles，平均 17 cycles |
| 16 | 16-bit one-hot | 15 | 0.0490 | 37 tx / 755 cycles，平均 19 cycles |
| 32 | 32-bit one-hot | 31 | 0.0473 | 69 tx / 1459 cycles，平均 19 cycles |

该趋势支持“核数增加而共享事务吞吐下降”的假设，但不支持任何 Linux SMP 或完整 ARM 内存模型结论。另一个工程层面信号是：8 核 default-FP cluster lint/elab 约 347 s、2.76 GiB RSS；16 核 default-FP 在约 32 分 40 秒、5.55 GiB RSS 后未完成，32 核未启动。规模优化必须把硬件延迟与验证成本分开记录。

## 3. P-line 数据的正确解读

当前全量快照（T-20260830-021）记录的是整程序到 MAGIC store 的 cycle，而不是 IPC。它可以作为回归锚点，不能直接证明某个结构是唯一瓶颈：

| workload | cycles | 外部审计关注点（假设） |
| --- | ---: | --- |
| `alu_latency` | 2,500,171 | 依赖链与循环前端；适合测前端固定开销。 |
| `alu_ilp` | 2,520,238 | 2/4/8 条独立 ADD 仍单发射；适合测未来 2-wide 上限，但不是 IPC。 |
| `ctrl_branch` | 2,330,280 | taken/not-taken、调用/返回冲刷。 |
| `muldiv` | 848,421 | 多周期 EX 槽和前端冻结。 |
| `mem_seq` | 3,042,223 | 无缓存顺序流量、单请求往返和循环开销。 |
| `mem_random` | 3,907,778 | 依赖 pointer chase 与随机读；最适合验证 MSHR/MLP。 |
| `mem_ldst` | 1,120,538 | load-use、pair 访存和 store 路径。 |
| `fp_scalar` | 226,593 | FP 执行延迟与前端供给；当前不是双发射证据。 |
| `fp_fp16` | 254,247 | FP16 执行/状态路径。 |
| `neon_vect` | 227,526 | SIMD 独立操作与向量访存；适合未来配对试验。 |
| `kernel_crc` | 184,738 | 循环、查表和前端/访存混合。 |
| `kernel_hash` | 55,476 | 小工作集和循环控制。 |
| `kernel_matmul` | 497,454 | 规则访存与算术重叠的候选。 |
| `kernel_sort` | 255,687 | 分支与不规则访存混合。 |

在引入任何改动前，应在同一 SHA 上补充 `retired_instructions`、提交 stall、取指请求/响应、分支 flush、dmem wait、PTW busy、cache hit/miss/refill/writeback 和总线事务数。没有这些计数，不能把 `mem_random` 的高 cycle 单独归因于 cache，也不能把 `alu_ilp` 的 cycle 差直接换算为双发射收益。

## 4. 候选方向逐项评估

优先级含义：P0 = 下一批必须先做的低耦合测量/结构；P1 = 高价值、需要协议或一致性设计；P2 = 依赖时序/协议基础的远期方向。每一项的“收益”均为方向性预期。

### PE-00：性能计数与缓存配置矩阵（P0）

- **当前证据/瓶颈假设**：P-line 默认三层 cache 全关；runner 只观察到 MAGIC 完成 cycle，`commit_ready` 默认常为 1。现有 cache/总线没有统一 hit/miss/等待计数。
- **预期收益方向**：不改变 RTL 性能；提高归因能力，避免把测量噪声或配置差异当作优化收益。
- **改动范围/风险**：`Makefile`、`scripts/build-microbench.sh`、`sim/microbench/perf_runner.py` 和报告格式；可在 BFM/wrapper 增加非架构计数。风险低，但必须保持默认 `nocache` 行为。
- **验证/度量**：同一镜像跑 `nocache`、I-L1、D-L1、I+D、I+D+L2、B5 WB（可用时）以及 delay 0/1/2；输出 cycle、retired、IPC、请求/命中/缺失/beat、stall 分类，绑定 source/image/tool SHA。
- **依赖**：无；是所有后续性能任务的入口。

### PE-01：取指 FIFO、critical-word-first 与顺序预取（P0）

- **当前证据/瓶颈假设**：core 只有 `fetch_pending/fetch_got_data` 单上下文和 4B 请求；`mem_busy` 时禁止新取指；I-L1 miss 要等 8 beat 完成后才进入 `S_RSP`。
- **预期收益方向**：提高 front-end IPC、隐藏内存响应抖动；循环和小 kernel 应先受益。critical-word-first/early restart 可降低首次取指 miss 延迟，顺序预取可降低连续 I miss，但收益必须由 I-L1 miss 计数验证。
- **改动范围/风险**：`lcvex_core.sv`、可选 `fetch_buffer`，以及 `lcvex_l1_i.sv` 的填充状态；flush、IABT、TLBI 和跨页处理是主要风险。先不做推测性提交。
- **验证/度量**：取指队列满/空、flush 后无 stale response、跨页/跨 line fault、`ctrl_branch` taken/not-taken、函数调用返回、随机 `MEM_DELAY_MODE=2`；比较 fetch bubbles、branch flush 和 IPC。
- **依赖**：PE-00；默认参数关闭时必须与现有单请求路径等价。

### PE-02：BTB/方向预测/RAS（P1）

- **当前证据/瓶颈假设**：所有非顺序 `d.next_pc` 在 ID 解析后冲刷 IF/ID，没有 BTB、方向历史或返回栈。
- **预期收益方向**：降低 taken branch、间接跳转、BL/RET 的重取指气泡；对 `ctrl_branch`、sort 和调用密集 kernel 有方向性收益。
- **改动范围/风险**：新增小型直接映射 BTB、2-bit 方向表、可选 RAS；需要预测 tag、epoch/flush、错误路径取指 fault 丢弃规则。错误预测不能产生内存或架构副作用。
- **验证/度量**：预测命中/错误计数、分支类型分相、错误路径 IABT/异常、BTB alias、RAS under/overflow、QEMU lockstep 全量。先做非推测目标缓存，再做方向预测。
- **依赖**：PE-01；须冻结 fetch epoch 语义。

### PE-03：受限 outstanding、MSHR、store buffer（P1）

- **当前证据/瓶颈假设**：`dmem_pending` 令 EX/MEM、MEM/WB 和上游停顿；L1/L2 refill/writeback 逐 beat；store 需等待响应，且无写合并。
- **预期收益方向**：提高 MLP、隐藏可变内存延迟和 refill 时间；`mem_seq`、`mem_random`、`mem_ldst` 及 matmul/sort 最敏感。独立 pointer chase 只有在软件/硬件能提供多个独立链时才会受益，单链依赖仍是延迟测试。
- **改动范围/风险**：分阶段修改 `lcvex_core.sv`、`lcvex_pkg.sv`、L1/L2、`mem_arb/router/ram`；首版建议 2-entry miss queue + 同 line 合并 + 1-entry store buffer，仍按程序顺序提交。必须定义 transaction ID、fault 配对、排空和 checkpoint 边界。
- **验证/度量**：同/异地址 miss 合并、响应乱序、背压、load-use、store-to-load forwarding、LDXR/STXR/LSE、MMU fault、维护/异常和 drain；报告 outstanding occupancy、隐藏周期和按序 commit。未经这些测试不得打开默认开关。
- **依赖**：PE-00 的真实 cache baseline；先冻结 M1-B 响应/线性化契约，再考虑多 ID。

### PE-04：L1/L2 refill、写回和数据阵列服务优化（P1）

- **当前证据/瓶颈假设**：I/D-L1、L2 和 WB 路径均单阻塞，8 个 8B beat 完成前不响应；WB dirty 行为保持 metadata 直至全成功，正确但延迟长。
- **预期收益方向**：critical-word-first/early restart 降低 miss 首字延迟；写缓冲降低 store commit 阻塞；line buffer 与命中读并行可提高带宽。不会自动增加架构 IPC，需与 PE-03 分离测量。
- **改动范围/风险**：`lcvex_l1_i.sv`、`lcvex_l1_d.sv`、`lcvex_l1_d_wb.sv`、`lcvex_l2.sv`、`lcvex_l2_wb.sv`；维护、fault、dirty victim、同 line 合并和 probe hold 是风险点。
- **验证/度量**：命中/缺失/首字返回/完整行完成时间、写回队列深度、fault 后 metadata、DC/IC/TLBI、checkpoint drain；先仅允许 critical-word-first，保持整行有效发布点不变。
- **依赖**：PE-00；PE-03 的 MSHR 事务 ID 设计。

### PE-05：共享 L2 数据阵列、目录和 probe 并行化（P1）

- **当前证据/瓶颈假设**：cluster 的 L2 只有目录，S 状态数据仍来自 PoC；全局 single transaction，`probe_pending_mask` 逐个 target，C4 吞吐随 N 下降。
- **预期收益方向**：共享命中减少 PoC 流量；不同 line 可并行；多 sharer invalidate/dirty owner migration 的延迟接近一次广播而非 N 次串行。
- **改动范围/风险**：新增 `l2_cluster_wb` 或复用 L2-WB 数据阵列，扩展 per-core probe response 状态、同 line 排序、目录编码；一致性竞态、probe fault/abort 和内存模型风险最高。
- **验证/度量**：C2/C3 全回归、同 line 与不同 line 竞争、M→S/S→M、dirty owner、probe fault、目录不变式（M owner 唯一、S 无 owner）、8/16/32 synthetic 与有限真实 core；记录 PoC beat、probe 数、line latency、吞吐。
- **依赖**：先关闭 C2/C3 正确性缺口；PE-03 的事务 ID/排队契约；CORE_COUNT=1 锚点不可回归。

### PE-06：仲裁、backpressure 和维护/异常路径 QoS（P0/P1）

- **当前证据/瓶颈假设**：M1-B 端口 PTW > D > I 固定优先，`commit_ready` 背压传播到整条流水；系统指令/维护要求前方排空，DC ZVA 还要逐 8B 写。
- **预期收益方向**：在不改变架构顺序的前提下减少不必要的 starvation 和恢复气泡；MMU 开启、页表密集、维护密集负载的尾延迟可下降。不是简单地把 PTW 降为低优先级。
- **改动范围/风险**：`lcvex_mem_arb.sv`、core 的 commit/maintenance sequencer；增加 aging/配额、独立响应槽或维护 micro-queue。错误的优先级改变可能造成 PTW 活锁或观察顺序变化。
- **验证/度量**：PTW/I/D 饥饿上界、commit stall 周期、系统指令 drain 周期、TLBI/IC/DC fault、WFI/WFE/IRQ；SVA 证明 ready/valid 稳定和无重复提交。
- **依赖**：PE-00 计数器；在 PE-03 之前只做公平性和观测，不放宽内存顺序。

### PE-07：总线 line packet、突发和多 ID（P1/P2）

- **当前证据/瓶颈假设**：M1-B 8B beat、arb/router/RAM 单 outstanding；AXI 128-bit master 单 ID；Avalon 512-bit 但 `burstcount=1`。增加 CDC FIFO 深度本身不会增加事务并行。
- **预期收益方向**：line-level burst 减少 8 次请求握手；多个 ID 隐藏 EMIF/DDR latency；对顺序流量和多核 PoC 最有效，随机单链收益有限。
- **改动范围/风险**：`lcvex_pkg.sv`、arb/router/delay/ram、L1/L2 refill、AXI master、Avalon adapter/SVA；需重新定义 byte-enable、4 KiB boundary、乱序响应、fault 和 reset/calibration epoch。
- **验证/度量**：8B/16B/64B 配置矩阵、AXI AW/W/AR/R/B 独立握手、乱序 ID、Avalon waitrequest/readdatavalid、CDC reset/calibration、跨行/跨页 fault；报告有效带宽和每 line 握手数。
- **依赖**：PE-03 的 transaction ID 和 cache MSHR；不要在单 outstanding core 上先做大协议改写。

### PE-08：多 bank、line 宽度和预取（P2）

- **当前证据/瓶颈假设**：cache data 为 byte-array，单端口语义；核心/仲裁本身也只有一笔事务。单纯 bank 化无法消除上游串行。
- **预期收益方向**：在已有并行请求后提高 RAM 带宽、降低冲突；128B line/next-line prefetch 可能改善顺序流量，但会增加污染和跨边界流量。
- **改动范围/风险**：L1/L2 阵列、tag/data banking、line/probe/AXI 契约；行宽改变会影响所有维护和一致性消息，预取错误会放大 PoC 流量。
- **验证/度量**：bank conflict、容量/污染、跨 64B/4 KiB 边界、prefetch usefulness/accuracy、随机访问负收益；仅在 PE-03/07 后开启。
- **依赖**：PE-00、PE-03、PE-07；需有 FPGA RAM/时序报告而非只看 Verilator cycle。

### PE-09：更深流水线（P2）

- **当前证据/瓶颈假设**：当前四级寄存器流水对功能复杂度仍可控；现有最大停顿来自前端和访存，而非已证明的 ALU Fmax 路径。
- **预期收益方向**：可能提高 FPGA Fmax，几乎不直接增加每周期提交数；若分支和访存不变，墙钟性能未必改善。
- **改动范围/风险**：拆 decode/AGU/EX/MEM 需要扩展所有 pipeline 字段、forwarding、flush、precise exception、system drain 和 commit packet 对齐。
- **验证/度量**：先有 Quartus/STA critical path、资源和功耗目标；随后 QEMU lockstep、随机 delay、异常/维护/IRQ、长依赖链和分支压力。没有 STA 不立项。
- **依赖**：PE-01、PE-03 稳定；冻结提交/异常协议。

### PE-10：顺序 2-wide（P2）

- **当前证据/瓶颈假设**：`alu_ilp` 有独立 ADD 链，但当前 IF、寄存器文件、旁路和提交包均是一条指令粒度；FP/NEON/访存/系统指令的双结果路径复杂。
- **预期收益方向**：对独立整数/FP/NEON 理论上提高吞吐；分支、load-use、cache miss 和多周期除法仍会限制实际 IPC，不能以 2x 作为承诺。
- **改动范围/风险**：双路 fetch/decode、寄存器文件读写端口、配对检测/旁路、两个执行槽和按序双提交；`commit_packet`/lockstep 协议需定义“一拍两提交”或拆成两个带 seq 的事件。异常和 store 顺序必须保持精确。
- **验证/度量**：先只允许两条独立 ALU、禁止 branch/load/store/system 配对；`alu_ilp`、FP/NEON 独立链、依赖/结构冲突、每条指令 QEMU lockstep、双提交序列和 backpressure。逐步扩大配对集合。
- **依赖**：PE-01、PE-03、PE-06；提交协议和差分协调器先冻结。

## 5. 建议的实施与验收顺序

### 阶段 A：测量冻结（P0）

1. 维持 `nocache` 默认，新增 I/D/L2/WB 配置矩阵和 delay 0/1/2。
2. 记录每条提交、取指、分支、dmem、PTW、cache、PoC、commit backpressure 计数；输出 cycle、retired、IPC、line latency、有效带宽。
3. 把 C2/C3/C4 synthetic 与完整 core 结果分开；为 `CORE_COUNT=1` 建立性能锚点。

### 阶段 B：低耦合前端（P0/P1）

1. 先实现可关闭的 2–8 entry fetch FIFO，保持非推测提交。
2. 再实现 critical-word-first/early restart；最后评估 BTB/方向预测/RAS。
3. 每一步用 `ctrl_branch`、`alu_latency`、kernel 和随机延迟回归，确认 flush/异常不变。

### 阶段 C：单核内存并行（P1）

1. 先在 cache 控制器增加 2-entry MSHR/同 line 合并和 1-entry store buffer，核心仍单发射、按序提交。
2. 再让 L1 refill 与命中/取指有限重叠；保留原单事务开关作为回退路径。
3. 用独立/依赖双 pointer chase、load-use、原子/维护/fault/backpressure 验收；没有响应配对和精确异常证明，不扩大队列深度。

### 阶段 D：共享 L2 与总线（P1）

1. 先给 coherent cluster 增加真实 L2 数据阵列，保持同 line 单序列化。
2. 再做不同 line 并行和 probe 多播/位图 pending；最后再做目录分片或仲裁树。
3. 将 line refill/writeback 聚合到 AXI/Avalon burst，并在有 MSHR 后引入多 ID；CDC/reset/calibration 单独验收。

### 阶段 E：时序驱动远期结构（P2）

- 只有在 Quartus/STA 指明关键路径后才拆更深流水；
- 只有在前端/访存/提交协议稳定且 `alu_ilp` 等测量显示有可回收 ILP 时才实现 2-wide；
- 多 bank、128B line、预取以 FPGA RAM 映射和污染数据为准，不以仿真 cycle 单独决策。

## 6. 统一验证与回退要求

每个性能改动必须带参数化回退路径，默认值保持当前行为；验收按 L0→L1→L2→L3 递进：

- L0：静态检查、计数器/报告 schema、定向 microbench；
- L1：相关 cache/arbiter/cluster SVA、随机延迟和故障注入；
- L2：QEMU 单步锁步，逐条提交严格对应，覆盖 MMU、原子、维护、异常、IRQ；
- L3：同一合并 SHA 的 Gate D 子集和性能矩阵；FPGA 频率/资源另由 Gate F 处理。

必须持续保留的安全不变式：

1. 架构状态只在 commit 边界更新；错误路径和预取数据不得产生提交或内存副作用。
2. 任何多 outstanding 响应都带 transaction ID，fault、reset、checkpoint、drain 后不得错配或重放。
3. store 的架构可见顺序、exclusive/atomic 线性化点和 DMB/DSB/ISB 语义不因性能队列改变。
4. `CORE_COUNT=1`、C2/C3 已有 correctness smoke 和旧的单事务路径可独立复现。
5. 任何“性能提升”报告必须同时给出配置、源码/镜像 SHA、工具版本、cycle、retired、计数器和限制；不能只给墙钟或 Verilator RSS。

## 7. 外部审计结论

- **近期最值得做**：PE-00 测量闭环、PE-01 取指 FIFO/early restart、PE-03 受限 MSHR/store buffer。
- **中期高价值但高风险**：PE-05 共享 L2 数据阵列与 probe 并行、PE-07 line burst/多 ID；两者应建立在事务 ID、cache baseline 和精确异常验证之上。
- **不建议现在做**：没有 STA 依据的深流水、没有前端/访存基础的全功能 2-wide、只加深 CDC FIFO 却不增加可服务事务的“伪并行”、将 C4 synthetic 吞吐当作完整多核性能签核。

本文件是第三方静态规划，不宣称任何候选已经实现，也不替代 Gate D、Gate F、QEMU lockstep 或 Linux/板级验证。与内部 PE-A 规划合并前，不应启动性能增强 RTL 实施。
