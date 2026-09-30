# LCVEX 性能增强最终合并版路线图（PE-A + PE-EXT 综合）

> 状态：**规划/路线图**，不是已实现性能收益。
> 生成任务：T-20260830-035 PE-EXT 综合；输入为 PE-A 与 PE-EXT 两份独立审计。
> 输入：
> - `docs/PERFORMANCE_ENHANCEMENT_PLAN.md`（PE-A / T-20260830-034）
> - `docs/PERFORMANCE_ENHANCEMENT_PLAN_INDEPENDENT.md`（PE-EXT / T-20260830-035，外部独立审计）
> - `docs/PERFORMANCE_WORKLOAD_PLAN.md`、`docs/PERFORMANCE_SNAPSHOT.md`、`docs/C4_DUALCORE_BASELINE.md`
> - `docs/C3_FOURCORE_PREWORK.md`、`docs/C4_SCALE_PREWORK.md`
> 约束：不修改 RTL/测试，不启动 Quartus，不开始实施优化；所有“预期收益”均为待测量假设。

## 0. 执行摘要

两份审计独立得出的结论高度一致：

1. **当前性能上限不是 ALU 组合逻辑，而是“指令交付与访存等待被串行化”。** 单发射、单在途取指、分支在 ID 解析并冲刷、访存单 outstanding、页表遍历/乘除/系统指令全流水冻结，共同压低了 IPC。
2. **现有 P-line 默认关闭 I-L1/D-L1/L2，14 项快照只是“无缓存 + 1-cycle RAM”的整程序周期代理。** 在没有 retired instruction、stall 分类、cache hit/miss、总线事务计数之前，不能把任何改动后的 cycle 变化定量归因到某个微架构结构。
3. **访存并行度（MSHR / outstanding）是单核和多核内存密集型负载的最高价值方向，但必须在真实缓存基线和事务 ID/精确异常契约之后实施。**
4. **多核共享 L2 目前只有目录元数据，没有数据阵列；cluster 是全局单事务、probe 逐 sharer 串行。** C4 synthetic 证据显示吞吐随核数下降，是未来多核扩展的主要结构性瓶颈。
5. **更深流水和完整 2-wide 顺序双发射都应后置。** 需要先有前端、访存、提交协议基础，并由 Quartus/STA 或明确 ILP 测量驱动，否则风险远高于收益。

### 最终 Top 3 建议（综合）

| 排名 | 方向 | 最终优先级 | 为什么 |
|---|---|---|---|
| 1 | **F0：性能测量闭环 + 缓存配置矩阵** | P0 | 不改 RTL，收益是可验证性；所有后续优化需要同一 SHA 下的 cache/no-cache、stall、IPC、事务计数基线。 |
| 2 | **F1：前端取指 FIFO / 早取 / critical-word-first** | P0 | 改动集中在 core 前端和 I-L1 响应路径，对循环、分支、kernel 最直接；是后续 2-wide 的前端前提。 |
| 3 | **F3：受限 outstanding / MSHR / 写缓冲** | P1 | 解除 load/store 等待时全流水冻结，是隐藏内存延迟、提升 stream/random/multicore MLP 的核心结构；建议先做 2-entry、按序提交的受限版本。 |

> 注：F0 本身不是性能提升；F1 和 F3 是实际 RTL 改动。最终实施顺序为 **F0 → F1（或 F3 的前置设计）→ F3 → F5/F7**，F2 可与 F3 并行但需避开同一 core 写集。

## 1. 两份审计的共识、差异与合并结论

### 1.1 强共识

| 话题 | PE-A | PE-EXT | 最终结论 |
|---|---|---|---|
| P-line 测量缺口 | C2：缓存配置接入 P-line | PE-00：性能计数 + 缓存矩阵 | 必须作为第一步；无争议。 |
| 前端瓶颈 | C1：取指缓冲/分支预测 | PE-01/02：取指 FIFO/early restart，BTB/RAS 随后 | 取指缓冲 P0，分支预测 P1。 |
| 访存 outstanding | C3：MSHR/非阻塞 P1 | PE-03：受限 MSHR/store buffer P1 | 保留 P1，分阶段实施，先 2-entry 按序提交。 |
| 多核共享 L2 无数据阵列 | C4：共享 L2 数据+probe 并行 P1 | PE-05：真实 L2 数据阵列/并行 probe P1 | P1，必须在 C2/C3 正确性关闭后。 |
| 总线加宽/多 ID | C5：P1/P2 | PE-07：P1/P2 | P1/P2，依赖 MSHR 事务 ID，不先于 F3。 |
| 深流水 | C6：P2 | PE-09：P2 | P2，无 STA 不立项。 |
| 2-wide | C7：P2 | PE-10：P2 | P2，先冻结双提交/锁步协议。 |

### 1.2 主要分歧与取舍

- **“先做分支预测还是先做取指缓冲？”**
  - PE-A 把 C1 合并为“取指缓冲 + 分支预测 + BTB/RAS”整体 P0。
  - PE-EXT 建议拆成 PE-01（取指 FIFO/early restart）P0 和 PE-02（BTB/方向/RAS）P1，理由是分支预测是推测路径，错误路径与 IABT/TLBI/flush 的交互需要先冻结取指 epoch。
  - **最终采用 PE-EXT 的拆分**：先取指缓冲/早取，再独立做分支预测。风险更低，验证更清晰。
- **“MSHR 是否应与取指缓冲并行？”**
  - 二者都会修改 `lcvex_core.sv`，并有大量共享 stall/forwarding 语义，不宜在同一工作树并行写同一文件。
  - **最终建议：F0 完成后，F1 先落地并回归；F3 同时可在独立 worktree 做协议/模块设计，但 RTL 合入需串行。**
- **“C4 多核是否应先于单核总线优化？”**
  - PE-A 将 C4 放入 P1 第二梯队，PE-EXT 也将其放在 P1 中游。
  - **最终结论：单核内存并行（F3）和测量（F0）先于多核共享 L2（F5），因为多核每核仍然只有单 outstanding，单核 MSHR 是 F5 的必要前提。**

## 2. 最终候选方向清单

> 优先级定义：
> - **P0**：下一批必须启动/低风险建立测量与前端基础。
> - **P1**：高价值，需要事务/一致性协议设计或中等以上风险。
> - **P2**：远期，依赖频率/ILP/协议基础，或需要 Quartus/STA 数据支撑。

| ID | 方向 | 优先级 | 一句话目标 |
|---|---|---|---|
| F0 | 性能计数与缓存配置矩阵 | P0 | 把 P-line 变成可归因的 IPC/延迟/带宽测量平台。 |
| F1 | 取指 FIFO、早取、critical-word-first | P0 | 隐藏取指延迟，减少前端气泡。 |
| F2 | BTB / 方向预测 / RAS | P1 | 降低分支、调用/返回重取指代价。 |
| F3 | 受限 outstanding / MSHR / store buffer | P1 | 隐藏访存延迟，允许 miss 与后续独立工作重叠，仍按序提交。 |
| F4 | refill/writeback/数据阵列服务优化 | P1 | critical-word-first、写缓冲、line buffer、hit-under-miss。 |
| F5 | 共享 L2 数据阵列、目录与 probe 并行化 | P1 | 让 S 共享行在 L2 命中，减少 PoC 流量和 probe 串行。 |
| F6 | 仲裁/backpressure/维护/异常 QoS | P0/P1 | 减少固定优先级和系统指令排空造成的不必要停滞。 |
| F7 | 总线 line packet、突发与多 ID | P1/P2 | 将 8×8B beat 变为 line burst，AXI/Avalon 支持多 outstanding。 |
| F8 | 多 bank、更宽 line、预取 | P2 | 在已有并行请求上提高缓存/内存带宽。 |
| F9 | 更深流水线 | P2 | 面向 Fmax，由 STA 驱动。 |
| F10 | 顺序 2-wide | P2 | 提高 ILP，需前端/访存/提交协议基础。 |

## 3. 各方向详细评估

### F0：性能计数与缓存配置矩阵（P0）

**目标**：让所有后续 RTL 改动都能在同一 SHA 上回答“快了/慢了、快在哪、慢在哪”。

**当前结构/证据**：
- `tb/sv/lcvex_soc_tb.sv` 默认 `D_L1_ENABLE=0`、`I_L1_ENABLE=0`、`L2_ENABLE=0`，`make microbench-build` 未传任何 `-G*_ENABLE=1`。
- `PERFORMANCE_SNAPSHOT.md` 只记录整程序到 MAGIC 的 cycles；无 retired_insn、无 stall 分类、无 cache/hit/miss、无总线事务数。
- `C4_DUALCORE_BASELINE.md` 和 C4 evidence 也显示只有构建/有限 smoke 和 synthetic proxy，并没有完整 core IPC。

**瓶颈假设**：当前无法区分“前端瓶颈、访存瓶颈、cache 命中率、PTW 开销或提交背压”，因此无法安全选择优化方向或归因收益。

**预期收益方向**：
- 不直接提高 IPC/带宽；提高可验证性、降低错误优化风险。
- 可输出 `cycles`、`retired_insn`、代理 IPC、取指请求/响应、分支 flush、dmem wait、PTW busy、L1I/L1D/L2 hit/miss/refill/writeback、PoC/AXI 事务数。
- 可跑配置矩阵：`nocache`、`l1i`、`l1d`、`l1i+l1d`、`l1i+l1d+l2`、B5 WB 路径（如可接入）、`mem_delay=0/1/2`。

**改动范围**：
- 主要 `Makefile`、`scripts/build-microbench.sh`、`sim/microbench/perf_runner.py`、报告 schema/JSON。
- 可新建只读调试计数器或 wrapper 观测，不改动架构状态。
- 不修改 RTL 核心行为；若需要暴露信号可在仿真顶层加 debug 输出，默认关闭。

**风险/难度**：低。需保持 `make microbench-build` 默认行为，避免破坏 lockstep/现有测试。

**验证/度量**：
- 在固定 SHA/分支/工具版本下，对同一镜像跑完整矩阵并保存 JSON。
- 每一项记录 source/image/tool SHA、cycles、retired、stall/hit/miss、RSS。
- 与现有 P-SNAPSHOT nocache 数值对齐作为回归锚点。

**P-line 对应**：全部 14 项；尤其 `mem_seq/random/ldst`、`kernel_*` 需要 cache/总线计数。

**依赖**：无。这是所有后续任务的入口。

---

### F1：取指 FIFO、早取与 critical-word-first（P0）

**目标**：让取指不再“每次只发一个 4B 请求、等待响应、再捕获”，并让 I-L1 miss 的首个目标 beat 尽快返回。

**当前结构/证据**：
- `lcvex_core.sv` 只有 `fetch_pending`、`fetch_got_data`、`fetch_translated` 单上下文；`fetch_imem_req` 的 `strb=8'h0F`，每次 4B。
- `mem_busy` 或 `dmem_pending` 时会阻止新取指；`flush_id` 会清 IF/ID 并取消在途取指。
- `lcvex_l1_i.sv` 的 miss 状态是 `S_REFILL → S_REFILL_WAIT` 循环 8 次，全部完成后才 `S_RSP` 返回；没有 critical-word-first。
- `alu_latency`、`ctrl_branch`、kernel 类 workload 的周期中包含大量循环/取指/分支开销。

**瓶颈假设**：
- 前端供给不足；即使 ALU 1 周期结果，流水线也经常因等取指或分支清空而空转。
- I-L1 miss 需要完整 8-beat refill 后才响应，顺序执行时首次取指 miss 延迟大。

**预期收益方向**：
- 提高 IPC/降低取指气泡；对循环、小 kernel、分支密集负载最敏感。
- critical-word-first/early-restart 可降低首次 miss 延迟，但必须保持“整行填充后才发布 tag/valid”的正确性边界。
- 为后续 BTB/RAS 和 2-wide 提供取指带宽。

**改动范围**：
- `rtl/lcvex_core.sv`（取指 FSM、IF/ID、flush、IABT 合并）。
- 可选新增 `rtl/lcvex_fetch_buffer.sv` 或取指队列。
- `rtl/lcvex_l1_i.sv`（refill critical-word-first/early-restart）。
- 不改推测提交；所有预取数据只进队列/cache，不可产生架构状态或内存副作用。

**风险/难度**：中高。
- 取指队列改变在途请求清空/响应丢弃、系统指令排空、TLBI/IC 失效、跨页/跨行 fault 合并语义。
- 默认参数必须可关闭，关闭时与现有单请求行为等价。
- 不能因预取让 MMU 翻译 fault 或错误路径取指进入提交。

**验证/度量**：
- 新 SVA：flush 后无 stale 响应、队列不丢不重、维护/TLBI 后无陈旧取指、跨页/line fault 正确。
- `t_ctrl_branch` 扩展 taken/not-taken、函数调用/返回、间接跳转。
- 随机 `MEM_DELAY_MODE=2`、MMU 开启、Linux 启动早期取指回归。
- 对照 `alu_latency`、`ctrl_branch`、`kernel_crc/hash/sort/matmul`。

**P-line 对应**：所有；最直接 `alu_latency`、`alu_ilp`、`ctrl_branch`、`muldiv`、kernel。

**依赖**：F0；无其他 RTL 前置。

---

### F2：BTB / 方向预测 / RAS（P1）

**目标**：减少 taken branch、间接跳转、BL/RET 的重取指气泡。

**当前结构/证据**：
- 分支目标和方向在 ID 由 decode 计算；`flush_id` 清 IF/ID 并把 `if_pc` 指向 `d.next_pc`。
- 没有 BTB、2-bit 分支历史、随机预测、返回栈。
- 所有无条件/条件/调用/返回分支都需要等待解码并可能冲刷已取到的错误路径。

**瓶颈假设**：
- 循环、条件分支、调用/返回密集负载存在大量可回收的取指气泡。
- 仅靠取指 FIFO 无法避免错误路径 fetch；预测器可减少 flush 次数。

**预期收益方向**：
- 降低分支延迟和前端清空次数；对 `ctrl_branch`、`kernel_sort`、调用密集 kernel 有明显方向性收益。
- 不能承诺 IPC 2x；需用分支计数验证。

**改动范围**：
- 新增小型直接映射 BTB、2-bit 方向预测器、可选 RAS。
- `lcvex_core.sv` 前端：预测目标、预测方向、epoch/flush、错误路径丢弃。
- 可能需要 `rtl/lcvex_branch_predict.sv`。

**风险/难度**：高。
- 预测本身不产生提交/内存副作用；错误路径取指必须可被 flush 且不能造成 IABT/TLBI 误合并。
- 分支目标预测可能与 MMU 翻译、ASID/TLBI、异常向量等交互。
- 需要严格定义错误路径 age 和 flush 边界。

**验证/度量**：
- 预测命中/错误计数、分支类型分相（taken/not-taken/indirect/call/ret）。
- 错误路径 IABT/异常、BTB alias、RAS under/overflow。
- QEMU 全量锁步；`t_ctrl_branch`、`kernel_sort` 分支敏感。
- 默认关闭或命中率不足时回退到 F1 无预测模式。

**P-line 对应**：`ctrl_branch`、`alu_latency`、`kernel_sort/matmul/crc/hash`。

**依赖**：F1 取指 FIFO/epoch；F0 计数器。RAS 还需要稳定 BL/RET 语义；不要与 F3 并行改 core。

---

### F3：受限 outstanding / MSHR / store buffer（P1）

**目标**：在保持程序顺序提交的前提下，允许 2 个左右独立访存 miss 同时进行，并为 store 提供写合并/缓冲，隐藏内存延迟。

**当前结构/证据**：
- `dmem_pending = dmem_req_valid || dmem_req_issued`，且 `exmem_can_adv`、`stall_id`、`mem_busy` 都依赖它；一个 load/store 等待响应时整条流水线（含取指）冻结。
- `lcvex_mem_arb.sv`、`lcvex_mem_delay.sv`、`lcvex_mem_router.sv`、`lcvex_mem_ram.sv` 均为单 outstanding。
- 旧/新 L1、L2 refill 都是单阻塞、8 个 8B beat；没有 MSHR、同 line 合并、写缓冲。
- `lcvex_axi4_master.sv` 只支持单 ID/单 outstanding，但接口保留了 ID/LEN 字段。

**瓶颈假设**：
- 内存密集型负载的延迟无法被隐藏；单链 pointer chase 本身可能仍受依赖限制，但独立链/流式访问有明确 MLP 收益。
- Store 也要等下游响应，缺少 store buffer 会让简单写循环同步阻塞。

**预期收益方向**：
- 提高 MLP、有效内存带宽、隐藏随机/可变延迟；对 `mem_seq`、`mem_random`、`mem_ldst`、`kernel_matmul/sort` 和未来多核共享内存负载最直接。
- 不是所有访存都会变快：单依赖链仍受延迟限制，需区分 latency-bound vs bandwidth-bound。

**改动范围**：
- 首版范围（建议）：2-entry miss queue/MSHR + 同 line 合并 + 1-entry store buffer；仍单发射、按程序顺序提交。
- 需要给 M1-B 请求/响应增加 transaction ID 或等价 sideband；`lcvex_pkg.sv`、`lcvex_core.sv`、L1/L2、`mem_arb/router/ram` 都可能修改。
- 后续可扩到 4-entry、不同地址乱序返回、load queue。

**风险/难度**：很高。
- 访存序、异常（DABT）、exclusive/原子、页表自修改、checkpoint/drain、错误路径都必须保持精确。
- 现有 SVA 多假设单 outstanding；需同步扩展。
- 若事务 ID 不完整，reset/checkpoint 后可能响应错配。

**验证/度量**：
- 同地址多 miss 合并、不同地址并行、响应乱序、背压、store-to-load forwarding。
- LDXR/STXR、LSE 原子、LSE128、MMU fault、维护/异常、WFI/IRQ、drain。
- 使用独立/依赖双 pointer chase、流式 copy、多线程共享内存 workload。
- 报告 outstanding occupancy、隐藏周期、按序 commit、PoC/AXI 事务数。
- 未通过响应配对和精确异常验证前，不打开默认开关。

**P-line 对应**：`mem_seq`、`mem_random`、`mem_ldst`、`kernel_matmul/sort/hash/crc` 的访存部分；`neon_vect` 向量访存。

**依赖**：F0 的真实缓存基线；建议与 F1 串行合入（都改 core），但可在独立 worktree 并行设计；F4/F7 需要它的事务 ID。

---

### F4：refill / writeback / 数据阵列服务优化（P1）

**目标**：在已有 MSHR 和事务 ID 基础上，降低 cache line 传输延迟，提升缓存数据阵列服务能力。

**当前结构/证据**：
- `lcvex_l1_i.sv`、`lcvex_l1_d.sv`、`lcvex_l1_d_wb.sv`、`lcvex_l2.sv`、`lcvex_l2_wb.sv` 都是单阻塞、8×8B beat 完成整行后才响应/发布。
- 写回路径为正确性会保留 metadata 直到全部 beat 成功；没有写缓冲、critical-word-first、line buffer 并行。
- `lcvex_catapult_soc_coh.sv` 的单核 WB 层次有 I-L1/D-L1/L2/probe，但仍单事务。

**瓶颈假设**：
- 每次 miss/写回固定串行 8 个 beat，即使目标 beat 已到达也要等整行。
- Store 需要等写响应，导致写密集循环无法吸收写延迟。
- D-L1 与 L2 状态机串行，命中读、refill 写、probe、writeback 不能并行。

**预期收益方向**：
- critical-word-first/early-restart 降低首次 miss 返回延迟。
- 写缓冲/写合并降低 store 阻塞。
- line buffer、多 bank、hit-under-miss 可在有 MSHR 后提高数据阵列带宽。
- 方向性收益，需与 F3 分开测量。

**改动范围**：
- `lcvex_l1_i.sv`、`lcvex_l1_d.sv`、`lcvex_l1_d_wb.sv`、`lcvex_l2.sv`、`lcvex_l2_wb.sv`。
- 可能调整 refill/writeback 状态机，保持 metadata 提交点不变（最后一个 beat 成功后才发布 valid/tag/dirty）。
- 可增加 fill_buf 多缓冲、命中读与 refill 写分离。

**风险/难度**：中高。
- probe/dirty victim/维护/fault 的正确性边界敏感；不能为了性能提前发布可见数据。
- 改变 refill 状态可能影响检查点 drain 和 L1/L2 一致性 SVA。

**验证/度量**：
- 命中/缺失/首字返回/完整行完成时间、refill 队列深度、writeback 延迟。
- DC/IC/TLBI、dirty victim、probe abort、checkpoint drain、fault 后 metadata 保持。
- `mem_seq`、`mem_random`、`kernel_matmul`、向量访存。

**P-line 对应**：`mem_*`、`kernel_*`，尤其开启缓存矩阵后。

**依赖**：F0；F3 的事务 ID/MSHR 是让本项收益可被利用的前提。可在 F3 落地后串行实施。

---

### F5：共享 L2 数据阵列、目录与 probe 并行化（P1）

**目标**：把多核 cluster 从“目录-only + 全局单事务 + 串行 probe”升级为带真实共享数据、不同 line 可并行、多 sharer 失效可多播的真实共享缓存层次。

**当前结构/证据**：
- `lcvex_l2_cluster.sv` 只维护 `dir_state/dir_sharers/dir_owner/dir_dirty`；没有 L2 数据阵列，S 状态行仍从 PoC 读取或从 dirty L1 probe 拿数据。
- cluster 状态机 `S_IDLE` 才接受一个请求，接受后到 `S_RSP` 一直持有单当前事务。
- `probe_pending_mask` 通过 `first_core()` 每次只选一个 sharer，状态为 `S_PROBE_REQ → S_PROBE_WAIT → S_PROBE_COMMIT` 循环。
- C4 synthetic 数据显示 8/16/32 核吞吐 0.0521/0.0490/0.0473 lines/cycle，最大串行 probe 7/15/31；16/32 核完整 FP 构建成本高。

**瓶颈假设**：
- 多核共享数据局部性无法被 L2 吸收，所有 miss 都打到 PoC。
- 全局单事务使不同 line 的核间请求互相阻塞。
- 多 sharer 失效/升级需要 N 次 probe，核数越高开销越大。

**预期收益方向**：
- S 状态共享行在 L2 命中，减少 PoC 流量和延迟。
- 不同 line 事务并行，提高 cluster 吞吐。
- 多播 probe 把串行失效变为近似一次广播；dirty owner 迁移延迟降低。
- 需要真实多核 P-MC 测量验证扩展性。

**改动范围**：
- `rtl/lcvex_l2_cluster.sv` 或新增 `lcvex_l2_cluster_wb.sv`（复用 `lcvex_l2_wb.sv` 的数据阵列/refill/writeback）。
- `rtl/lcvex_c2_l1_coherent.sv`、`rtl/lcvex_core_wrap.sv`、`rtl/lcvex_cluster_top.sv`、`rtl/lcvex_cluster_pkg.sv`。
- 可能引入 per-core probe pending/multi-cast 状态、目录编码优化、不同 line 事务表。

**风险/难度**：很高。
- 一致性是正确性核心；并行 rename/probe 会暴露更多竞态。
- 当前 C2/C3 正确性尚未完全关闭；不能以 synthetic smoke 替代完整内存模型。
- 必须保持 `CORE_COUNT=1` 和旧单事务路径可回归。

**验证/度量**：
- 保持并扩展目录不变式 SVA：M owner 唯一、S 无 owner、每 line 单 pending、fault/abort 不产生新 M。
- C2/C3 全回归；双/四核真实 core 的同 line 竞争、不同 line 并行、M→S/S→M、dirty owner 迁移、probe fault。
- 8/16/32 synthetic 趋势；记录 PoC beat、probe 次数、line latency、cluster 吞吐。
- 扩展 P-MC：mailbox、reduction、cacheline ping-pong、barrier、不同 line 并行。

**P-line 对应**：现有 14 项单核不直接覆盖；未来多核性能线（P-MC）可沿用 `t_mc_*`。

**依赖**：先关闭 C2/C3 正确性缺口；F3 事务 ID/排队契约；F0 多核测量模板。

---

### F6：仲裁、backpressure、维护/异常 QoS（P0/P1）

**目标**：在不改变架构顺序的前提下，减少固定优先级导致的 PTW/I/D 饥饿和系统指令/维护路径的过长冻结。

**当前结构/证据**：
- `lcvex_mem_arb.sv` 端口 0=PTW、1=D、2=I，固定 PTW 最高；单 outstanding。
- `commit_ready` 背压会传播到 `stall_wb` 与上游所有级。
- 系统指令（MSR/ERET/异常/屏障/维护）在 ID 级要求前方全排空；DC ZVA 需 8 次 8B 写；TLBI 一次全表失效。
- 维护、异常、IRQ 的恢复路径会短暂清空前端/访存。

**瓶颈假设**：
- PTW 密集/随机的负载可能让取指或数据长期等待；公平性缺少 aging。
- 屏障/维护/异常路径的排空周期在当前单发射系统中开销较大，可能影响中断延迟和上下文切换。

**预期收益方向**：
- 减少饥饿和停顿，改善 MMU/页表密集、Linux 启动、维护密集负载的尾延迟。
- 不改变内存顺序，只改善调度和资源利用。
- 为 F3 多 outstanding 提供更合理的仲裁/响应路径。

**改动范围**：
- `rtl/lcvex_mem_arb.sv`：可配置公平/aging/配额。
- `lcvex_core.sv` 的 commit/maintenance sequencer：独立响应槽或 micro-queue。
- 可能需要响应优先级/QoS sideband。

**风险/难度**：中。
- 改变优先级可能影响 PTW 活锁、观察顺序、锁步可重放性。
- 任何背压变化都不能破坏 valid/ready 稳定性和无重复提交。

**验证/度量**：
- PTW/I/D 饥饿上界、commit stall 周期、系统指令 drain 周期。
- TLBI/IC/DC/DC ZVA/AT 定向测试、WFI/WFE/IRQ、随机延迟。
- SVA 证明无 stale response、无丢请求、无重复提交。
- 与 `kernel_*`、MMU 开启的 lockstep 回归。

**P-line 对应**：`mem_random`、`kernel_*`、MMU/TLB 相关；对 Linux 启动类间接负载尤其重要。

**依赖**：F0 计数器；可在 F1/F3 之前做低风险公平性/观测改造，但不能与 F3 同时改 core 写集。

---

### F7：总线 line packet、突发与多 ID（P1/P2）

**目标**：把 8 个独立 8B M1-B 事务聚合为 line-level burst，并让 AXI/Avalon 支持多个 outstanding/多 ID。

**当前结构/证据**：
- M1-B 下游为 8B beat；`mem_arb/router/delay/ram` 均为单 outstanding。
- `lcvex_axi4_master.sv` 为 AXI4 Full 128-bit、单 ID、单 outstanding；`lcvex_catapult_soc_axi_bridge.sv` 只对行首读合并 4-beat，写仍逐 8B 单 beat。
- `lcvex_axi4_avalon_adapter.sv` 把 4×128-bit 合成 512-bit Avalon word，但 `burstcount=1`；异步 FIFO 深度 4 只做 CDC，不提供真正事务并行。

**瓶颈假设**：
- line refill/writeback 的 8 次握手开销大，尤其 FPGA EMIF/DDR 延迟下。
- 单 outstanding 使读写无法交错，DDR/EMIF 利用率低。
- CDC FIFO 深度不等于 MLP。

**预期收益方向**：
- 减少每 line 握手次数，提高有效带宽。
- 多 ID/多 outstanding 可隐藏 EMIF/DDR 延迟，改善顺序流和未来多核 PoC。
- 对 `mem_seq`、大 buffer、kernel 访存、多核共享内存有直接帮助；随机单链帮助有限。

**改动范围**：
- `rtl/lcvex_pkg.sv`（事务包/ID/数据宽度）。
- `rtl/lcvex_mem_arb.sv`、`lcvex_mem_router.sv`、`lcvex_mem_delay.sv`、`lcvex_mem_ram.sv`。
- `lcvex_l1_i.sv`、`lcvex_l1_d_wb.sv`、`lcvex_l2_wb.sv` refill/writeback。
- `lcvex_axi4_master.sv`、`lcvex_axi4_avalon_adapter.sv`、`lcvex_async_fifo.sv`、`lcvex_catapult_soc_axi.sv`。
- 相关 SVA/BFM 需同步更新。

**风险/难度**：高。
- 协议级改动：字节使能、4 KiB boundary、乱序响应、fault、reset/CDC epoch、Avalon waitrequest/readdatavalid 都要重新验证。
- 若在单 outstanding core 上先做，收益会被上游卡住；建议在 F3 事务 ID 后实施。

**验证/度量**：
- 配置矩阵 8B/16B/64B；AXI AW/W/AR/B/R 独立握手与多 ID 乱序。
- Avalon burstcount>1、CDC 双时钟、reset/calibration、跨行/跨页 fault。
- 报告每 line 握手数、有效带宽、outstanding 占用。
- `mem_seq/random/ldst`、kernel、未来多核 PoC。

**P-line 对应**：`mem_seq/random/ldst`、`kernel_matmul/sort/hash/crc`。

**依赖**：F0、F3 事务 ID、F4 line buffer；F5 多核 PoC 也受益。

---

### F8：多 bank、更宽 line、预取（P2）

**目标**：在已有多个 outstanding 后，提高缓存 data RAM 带宽，评估 128B line 和 next-line prefetch。

**当前结构/证据**：
- 各 cache data 为 byte-array 单端口；没有 bank/子阵列。
- 当前核心/仲裁本身单 outstanding，单纯 bank 化不能增加并行度。
- line 宽度固定 64B，影响所有 probe/维护/AXI 契约。

**瓶颈假设**：
- 顺序/流式访问受单端口数组和 narrow refill 限制。
- 预取可能改善顺序负载，但随机负载可能引起污染和带宽浪费。

**预期收益方向**：
- 多 bank 可让 refill 与命中读并行；128B line 可提高顺序带宽；next-line prefetch 可降低连续 I/D miss。
- 需以仿真和 FPGA RAM 映射/时序数据验证，不能只看 Verilator cycle。

**改动范围**：
- L1/L2 数据阵列分 bank、tag/data 流水化。
- line 宽度/预取策略。
- 涉及 probe/line/AXI 契约，范围大。

**风险/难度**：中高。
- bank 化可能与 MSHR/写缓冲交互复杂；宽行改变所有一致性消息和 AXI burst；预取错误会放大 PoC 流量。
- 随机访问可能负收益。

**验证/度量**：
- bank conflict、预取有用性/准确率、容量/污染、跨 64B/4KiB 边界。
- 与无预取配置对照，report false prefetch / extra PoC.
- `mem_seq`、`kernel_matmul`、`neon_vect` 向量流，`mem_random` 确认负收益。

**P-line 对应**：`mem_seq`、`kernel_matmul`、`neon_vect`；`mem_random` 作为负向对照。

**依赖**：F0、F3、F7；需 FPGA RAM/时序报告。

---

### F9：更深流水线（P2）

**目标**：在 Quartus/STA 证明关键路径后可提高 Fmax。

**当前结构/证据**：
- 当前寄存器级为 IF/ID、ID/EX、EX/MEM、MEM/WB，共 4 级；没有独立 AGU/预译码。
- 没有面积/频率测量证据表明 ALU/decode 是当前瓶颈。
- 更深流水会让分支恢复、前递、异常、系统排空更复杂。

**瓶颈假设**：
- 若 FPGA 综合报告显示关键路径在 decode/ALU/访存地址，拆分可能提升 Fmax。
- 对 Verilator IPC 不会直接有帮助，甚至可能放大分支/访存气泡。

**预期收益方向**：
- 频率/时序余量；不是 IPC 提升。

**改动范围**：
- `lcvex_core.sv`、`lcvex_decode.sv`、`lcvex_pkg.sv` 流水线字段、forwarding/flush/exception。

**风险/难度**：高。
- 所有精确异常、分支恢复、系统指令排空、提交包对齐都要重新验证。
- 无 STA 前不值得投入。

**验证/度量**：
- 先有 Quartus/STA 关键路径、资源、功耗目标。
- 随后 QEMU 全量 lockstep、随机 delay、异常/维护/IRQ、长依赖链/分支压力。
- 可增加长依赖链 microbench 作为延迟敏感回归。

**P-line 对应**：间接（所有）；主要是 Fmax。

**依赖**：F1 前端、F3 访存稳定；等 FPGA/STA。

---

### F10：顺序 2-wide（P2）

**目标**：在前端、访存、提交协议全部稳定后，实现两路 in-order issue/双执行/双写回（或单拍双提交）。

**当前结构/证据**：
- `lcvex_core.sv` 每周期最多一条指令从 IF/ID 进入 ID/EX；单发射。
- `lcvex_regfile.sv` 及 core 内 GPR 数组只有一个组合前递视图；无多读端口。
- `commit_packet_t`、QEMU 锁步协议假设每周期至多一条提交；FP/NEON 多结果路径复杂。
- `alu_ilp_add2/4/8` 显示独立 ADD 链被串行化；这是未来 2-wide 的动机，但不是当前可承诺 2x 的依据。

**瓶颈假设**：
- ILP 工作负载有可回收并行的空间，但当前取指、分支、访存等待、多周期乘除、单提交会稀释收益。
- 双发射会显著增加验证面积和协议改动。

**预期收益方向**：
- 对独立整数/FP/NEON 链理论上可接近 2x 吞吐；实际受分支/访存/结构冲突限制。
- 需要新增 `alu_ilp` 以外的配对/冲突 microbench 验证。

**改动范围**：
- `lcvex_core.sv`、`lcvex_decode.sv`、`lcvex_pkg.sv`、寄存器文件/旁路网络。
- 可能新增执行单元和双提交包；QEMU difftest 协议/协调器需同步。
- 若选择单拍双提交，需定义 `commit_packet` 多条目或两个带 seq 的事件；若只双执行单提交，则收益受限。

**风险/难度**：极高。
- 异常、store 顺序、exclusive/原子、维护、IRQ、FP/NEON 多结果都要精确。
- 不得绕过 QEMU 逐条 PRE/COMMIT 对应；任何多提交扩展都必须先冻结协议版本。
- 建议先从“两条独立 ALU、禁止 load/store/branch/system 配对”开始，逐步扩展。

**验证/度量**：
- 双发射定向测试：独立/依赖/结构冲突、load-use、分支、FP/NEON 多写回。
- `alu_ilp_add2/4/8` 作为吞吐代理；`ctrl_branch`、`mem_*` 作为限制约束。
- QEMU lockstep 每条指令提交序列；backpressure 下无丢/重。

**P-line 对应**：`alu_ilp`、`fp_scalar`、`fp_fp16`、`neon_vect`；`ctrl_branch`、`mem_*` 作为负向/边界。

**依赖**：F1 前端带宽、F3 访存并行、F6 仲裁/提交、双提交/锁步协议冻结。不早于这些。

---

## 4. 实施 DAG / 顺序

### 4.1 阶段定义

- **A（测量与封闭）**：F0
- **B（前端与调度）**：F1 → F2；F6 可独立做低风险 fairness/观测，但若与 F1 同写 core 则串行。
- **C（单核内存并行）**：F3 → F4；F3 设计可提前，但合入需 F0 + 契约。
- **D（多核与总线）**：F5、F7；依赖 C 的事务 ID/数据阵列基础。
- **E（远期结构）**：F8、F9、F10；依赖 B/C/D 和 STA/FPGA 数据。

### 4.2 DAG

```text
                ┌──────────────────────┐
                │ F0 测量/缓存矩阵     │  P0，无 RTL 依赖
                └──────────┬───────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
   F1 取指FIFO/early   F6 仲裁/backpressure  F3 受限MSHR/store
        │  (P0)             (P0/P1)            buffer (P1)
        │                  │                  │
        ▼                  │                  ▼
   F2 BTB/RAS (P1)        │              F4 refill/writeback (P1)
        │                  │                  │
        └────────┬─────────┘                  │
                 │                            ▼
                 │                    F5 共享L2数据+probe并行 (P1)
                 │                            │
                 │                            ▼
                 │                    F7 总线line burst/多ID (P1/P2)
                 │                            │
                 └────────────┬───────────────┘
                              │
                              ▼
              F8 多bank/宽行/预取 (P2)
              F9 更深流水 (P2, 需STA)
              F10 顺序2-wide (P2, 需协议)
```

### 4.3 串行/并行说明

| 并行性 | 说明 |
|---|---|
| F0 与任何 RTL 任务可并行。 | 它是测量/脚本，不碰 RTL 核心；先完成 F0 以便所有后续有基线。 |
| F1 与 F6 可在不同 worktree 并行设计，但都改 `lcvex_core.sv`，合入建议串行。 | 若 F6 只改仲裁器/观测且不改 core，则可以并行。 |
| F1 与 F3 是实际核心改动，禁止同一写集并行提交。 | F3 可与 F1 在不同 worktree 设计，但集成前必须串行跑全量回归。 |
| F2 必须等在 F1 之后。 | 依赖取指 FIFO/epoch/flush 语义。 |
| F4 依赖 F3 事务 ID/MSHR。 | 单独 critical-word-first 可先于 F3 小范围做，但收益受限于单 outstanding。 |
| F5 依赖 C2/C3 正确性关闭 + F3。 | 多核每核仍需要 MSHR 才真正受益。 |
| F7 依赖 F3 和 F4 的 line/ID 设计。 | 不能在单 outstanding core 上先做大协议改写。 |
| F8/F9/F10 依赖上述稳定和外部数据。 | 不建议提前启动。 |

### 4.4 推荐首批任务拆分（供集成者参考）

| 建议任务 | 内容 | 写集边界 | 优先级 |
|---|---|---|---|
| PE-0 | F0：测量/缓存矩阵/计数器 schema | Makefile、scripts、sim/microbench、docs | P0 |
| PE-1 | F1：可取指 FIFO/early restart | core、I-L1、docs、TB | P0 |
| PE-2 | F2：BTB/方向/RAS | core、新预测模块 | P1 |
| PE-3 | F3：2-entry MSHR/store buffer | core、pkg、cache、arb/router/ram | P1 |
| PE-4 | F4：refill/writeback/critical-word-first | L1/L2、cache TB | P1 |
| PE-5 | F5：共享 L2 数据阵列/probe 并行 | cluster/coh/core_wrap | P1 |
| PE-6 | F7：总线 burst/多 ID | pkg/arb/cache/axi/avalon | P1/P2 |
| PE-7 | F6：仲裁/backpressure/维护 QoS | arb/core | P0/P1 |

## 5. P-line 14 workload 映射

| workload | 主要瓶颈 | 最敏感方向 |
|---|---|---|
| `alu_latency` | 依赖链、循环分支、取指供给 | F1、F2、F9/F10（远期） |
| `alu_ilp` | 独立指令被单发射串行 | F10、F1；需新增 retired/IPC |
| `ctrl_branch` | 分支频率、取指重定向 | F1、F2 |
| `muldiv` | 多周期 EX、前端冻结 | F1、F6、F10 |
| `mem_seq` | 顺序访存、cache、总线、单 outstanding | F0、F3、F4、F7、F8 |
| `mem_random` | 随机访存延迟、MLP、TLB | F3、F0；F8 作为负向 |
| `mem_ldst` | load-use、pair、store 路径 | F1、F3、F4、F6 |
| `fp_scalar` | FP 链、前端供给 | F1、F10 |
| `fp_fp16` | FP16 吞吐 | F1、F10 |
| `neon_vect` | SIMD 吞吐、向量访存 | F1、F3、F10、F8 |
| `kernel_crc` | 循环、查表、前端/内存 | F1、F2、F3、F4 |
| `kernel_hash` | 小循环、控制流 | F1、F2 |
| `kernel_matmul` | 循环、规则访存、算访重叠 | F1、F2、F3、F4、F7 |
| `kernel_sort` | 分支、不规则访存 | F1、F2、F3、F4 |

> 多核 P-MC 不在 14 项内；需新增双核/四核性能 workload 与 F5/F7 对应。

## 6. 统一验证、度量与回退策略

### 6.1 安全不变式（所有 RTL 性能改动必须保持）

1. 架构状态只在 commit 边界更新；预取/分支预测数据不得产生提交或内存副作用。
2. 多 outstanding 请求/响应必须有 transaction ID；fault、reset、checkpoint、drain 后不得错配或重放。
3. store 的架构可见顺序、exclusive/atomic 线性化点、DMB/DSB/ISB 语义不因性能队列改变。
4. `CORE_COUNT=1`、C2/C3 已有 correctness smoke 和旧单事务路径必须独立可复现。
5. 任何性能报告必须同时给出配置、源码/镜像 SHA、工具版本、cycle、retired、计数器和限制。

### 6.2 每项改动的验证层级

- **L0**：静态检查、定向 microbench、报告 schema。
- **L1**：相关 cache/arbiter/cluster SVA、随机延迟、故障注入。
- **L2**：QEMU 单步/锁步，逐条提交严格对应，覆盖 MMU、原子、维护、异常、IRQ。
- **L3**：同一合并 SHA 的 Gate D 子集和性能矩阵；FPGA 频率/资源另由 Gate F。

### 6.3 回退方式

- 每个性能结构用参数/宏开关隔离，默认关闭时与现行为一致。
- 保留旧 SVA/测试不变，新增断言只补充不删除。
- 若某项 RTL 优化导致功能回归，回退到对应开关关闭状态并保留计数/报告。
- 合入前先跑 F0 基线，合入后跑同一镜像/参数矩阵对比。

## 7. 最终路线图的验收与后续

- 本文件是最终合并版规划；不启动任何性能增强 RTL 实施。
- 集成者应在同一 SHA 上复跑 F0 矩阵并冻结“当前无优化基线”。
- 后续任务按 PE-0/PE-1/... 拆分；每个任务在独立 worktree/分支实施并回填 evidence。
- T-20260830-035 handoff/evidence 已更新记录本轮“综合结论”，任务状态仍由集成者处理。
