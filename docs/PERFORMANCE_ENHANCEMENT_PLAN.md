# LCVEX 性能增强静态审计与优化规划（PE-A / T-20260830-034）

> 任务：T-20260830-034 PE-A
> 类型：只读/静态审计，不修改 RTL/测试，不启动 Quartus。
> 审计基线：任务派单基线 `e42bf7442044f74b41b4d96584f774116c533069`；审计过程中最新 HEAD 推进到 `03a99725f8e323b5b9f0fb44bb9008451934b741`（新增 T-20260830-035 PE-EXT 独立审计请求）。本文件是内部 **PE-A** 规划，后续需与 `docs/PERFORMANCE_ENHANCEMENT_PLAN_INDEPENDENT.md` 综合成最终性能增强计划。
> 结论性质：**规划与假设**，不是已实现性能收益，不构成 A10/Fmax/架构签核。

## 0. 执行摘要

当前 LCVEX 的核心是：

- **单发射、顺序、顺序提交**，没有乱序/多发射/寄存器重命名；
- 前端只有“单在途取指请求 + 1 拍响应缓冲 + 1 拍 IF/ID 捕获”，取指与执行之间没有真正的取指缓冲/预取；
- 分支在 ID 级解析，命中需要冲刷 IF/ID 并重定向取指，且没有分支预测/BTB/返回栈；
- 访存只有单 outstanding；任何 load/store 在 EX/MEM 等待响应时冻结整条流水线（含取指）；
- 现有 P-line 的 `lcvex_soc_tb` 默认 **I-L1/D-L1/L2 全部关闭**（`D_L1_ENABLE=0`, `I_L1_ENABLE=0`, `L2_ENABLE=0`），因此当前 14 个 workload 快照测的是“无缓存 + 1-cycle RAM”的核心代理，不是缓存层次性能；
- 多核 C2/C3/C4 路径使用“共享 L2 目录 + 每核统一直连式 L1”，但**共享 L2 目前没有数据阵列**，且全局单事务、逐核串行 probe、目录位图 one-hot，是已知多核扩展瓶颈。

**审计中看到的最大瓶颈：前端（取指/分支）与单 outstanding 访存共同压低了 IPC；在无缓存 P-line 基线中，前端尤其突出。** 由于流水线是单发射且无取指缓冲，即使 ALU 只有 1 周期延迟，绝大多数周期仍花在指令交付、分支清零和访存等待上。

**Top 3 优化方向（建议实施顺序）：**

| 优先级 | 方向 | 为什么先做 | 预期收益方向 |
|---|---|---|---|
| P0-1 | 前端/分支/取指缓冲 | 改动集中在 core 前端，不改变缓存/总线协议；现有 ctrl/alu workload 最能体现 | IPC 提升，循环/分支密集负载最明显 |
| P0-2 | 测量与真实缓存层次 | 先把现有 I/D-L1/L2 接入 P-line 并建立基线，才能量化后续缓存优化；风险低 | 延迟/带宽可测量；为 MSHR/多 outstanding 提供决策依据 |
| P1 | 访存 outstanding / MSHR 与非阻塞缓存 | 当前任何访存都冻结全流水，是 stream/random/多核内存密集型最大短板 | 内存带宽、流式/随机访存 IPC、多核内存并行度 |
| P1 | 多核共享 L2 数据阵列与 probe 并行化 | C2+ 当前没有真实共享 L2 数据，且 probe 串行导致核数扩展吞吐下降 | 多核共享数据局部性、事务延迟、N 核扩展性 |
| P2 | 双发射、更深流水、总线更宽/多 ID | 需要大量改写核心/通信协议，且应先有前端和访存收益后才有足够性价比 | 长远 IPC/Fmax/带宽上限 |

详细候选、改动范围、难度、风险、测试与 P-line 对应见第 4 节。

---

## 1. 审计范围与方法

### 1.1 审计对象

- 核心流水线：`rtl/lcvex_core.sv`、`rtl/lcvex_decode.sv`、`rtl/lcvex_alu.sv`、`rtl/lcvex_muldiv.sv`、`rtl/lcvex_fp_scalar.sv`、`rtl/lcvex_neon_*.sv`
- 单核缓存：`rtl/lcvex_l1_i.sv`、`rtl/lcvex_l1_d.sv`、`rtl/lcvex_l2.sv`、`rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l2_wb.sv`、`rtl/lcvex_l1_coherence.sv`
- 总线/内存：`rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_delay.sv`、`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_axi4_master.sv`、`rtl/lcvex_axi4_avalon_adapter.sv`、`rtl/lcvex_async_fifo.sv`
- 多核：`rtl/lcvex_cluster_pkg.sv`、`rtl/lcvex_cluster_top.sv`、`rtl/lcvex_core_wrap.sv`、`rtl/lcvex_l2_cluster.sv`
- 现有性能线：`docs/PERFORMANCE_WORKLOAD_PLAN.md`、`docs/PERFORMANCE_SNAPSHOT.md`、`baremetal/perf/t_*.c`

### 1.2 方法

- 以 RTL 状态机/信号连接为依据，静态梳理执行路径、握手、outstanding 数量和 stall 条件。
- 以现有 P-line 14 workload 的整程序 cycle 作为“代理数据”参照；不把 cycle 数当 IPC/架构签核。
- 不运行重型 Verilator/Quartus；不声称任何候选已有实测性能收益。

---

## 2. 现状审计

### 2.1 Core 流水线

#### 2.1.1 流水级

| 级 | 职责 | 关键实现 |
|---|---|---|
| IF | 取指、MMU 翻译、imem 请求/响应缓冲 | `fetch_pending/fetch_got_data/fetch_translated` FSM；一次只取 4 字节 |
| IF/ID | 指令锁存、译码、寄存器前递视图、分支目标计算 | `ifid_valid/ifid_pc/ifid_insn`；`lcvex_decode` 组合译码 |
| ID/EX | 操作数锁存、ALU/乘除/FP/NEON 执行启动 | `idex_valid/idex_d`；`ex_busy` |
| EX/MEM | ALU/乘除完成、数据地址/翻译结果、发起 dmem 请求 | `exmem_valid`；LSE/STXR 多阶段 |
| MEM/WB | load 数据扩展、写回、提交包、架构状态更新 | `memwb_valid/commit_fire` |

顶层注释为 `IF → ID → EX → MEM → WB/COMMIT`，实际寄存器段为 4 级（IF/ID、ID/EX、EX/MEM、MEM/WB）。没有 OoO、寄存器重命名、多发射、乱序提交。

#### 2.1.2 发射宽度与顺序性

- 单发射：每个周期最多一条指令从 IF/ID 进入 ID/EX。
- 顺序执行、顺序提交：架构状态只在 `commit_fire`（WB 级）或 ID 级系统指令提交更新。
- 没有双发射/超标量。
- `lcvex_regfile.sv` 虽有独立模块，但 `lcvex_core` 内部维护 GPR 数组；若要双发射需要重新评估读端口/前递网络。

#### 2.1.3 Stall 来源

| 来源 | 机制 | 影响 |
|---|---|---|
| load-use | `load_use/fp_load_use`：EX/MEM 的 load 结果未到，ID 若读取则停顿 | 单发射 + 无 load 前递，增加访存相关延迟 |
| 数据翻译 | MMU 数据翻译在 ID 发起，`data_trans_active` 冻结流水线；PTW 优先 | 页表遍历/随机访问时全流水停顿 |
| dmem pending | `dmem_pending` 使 `exmem_can_adv=0`，进一步令 `stall_id`/`stall_if` 成立 | 单 outstanding 访存：等待响应期间取指/译码也停 |
| 乘除/FP 除法 busy | `ex_busy` 冻结 IF/ID 与 ID/EX | 32/64 周期乘除直接暂停前端 |
| 系统指令/异常 | `sys_hold/excl_hold` 要求前方排空，ID 级提交 | 屏障/MSR/维护/异常代价高 |
| 分支 | `flush_id` 清 IF/ID，重定向取指 | 没有预测/取指缓冲，分支气泡明显 |
| 取指延迟 | 单请求/单响应缓冲，不能与执行重叠持续拉取 | 即使无 stall，前端吞吐也被请求-响应-捕获串行化限制 |

#### 2.1.4 分支处理与前端

- 分支在 decode 阶段用前递后的寄存器/NZCV 计算目标与方向。
- `flush_id` 在条件满足时清空 IF/ID，并把 `if_pc` 重定向到 `d.next_pc`；同时取消在途取指。
- 没有 BTB、分支历史、随机预测或 RAS；无条件直接/间接分支也走同样 flush。
- 取指固定 4 字节（一条指令）请求；没有 8/16/32 字节取指宽度，没有取指队列。
- 具体表现：`ctrl_branch` 的循环/条件分支负载在 20k 次迭代下整程序约 2.33M cycles，说明分支/循环开销占主导。
- `alu_latency` 5×50k 条 ALU 链约 2.50M cycles，平均每迭代约 10 cycles；即使 ALU 延迟为 1 cycle，多余周期主要来自循环分支、调用开销和前端交付。

#### 2.1.5 更深流水线/多发射空间

- **更深流水线**：当前 4 个寄存器级已经足够简单；继续拆分 decode/EX/访存可提高 Fmax，但会增加前递、flush、系统指令排空和异常边界复杂度。由于单发射且前端已有瓶颈，单纯加深流水线可能不会带来明显 IPC，反而扩大分支代价。
- **顺序双发射（2-wide）**：需要 2 路取指/译码、多读端口/多端口前递、最多 2 个 ID/EX 执行槽、2 个 WB/提交通道。ALU ILP/FP/NEON workload 有明确独立指令；但当前前端（取指缓冲/分支）未解决前，双发射收益会被取指和分支气泡吃掉很大一部分。

### 2.2 Cache 系统

#### 2.2.1 仿真顶层中的可选缓存（P-line 当前未启用）

`tb/sv/lcvex_soc_tb.sv` 参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `D_L1_ENABLE` | 0 | D-L1 写通直接映射，64B line / 64 组 / 4 KiB |
| `I_L1_ENABLE` | 0 | I-L1 只读直接映射，64B line / 64 组 / 4 KiB |
| `L2_ENABLE` | 0 | 统一 2-way 32 KiB，写通，单阻塞 miss |
| `MEM_DELAY_MODE` | 0 | 1-cycle RAM / 直通 |

`make microbench-build` 没有传 `-G*_ENABLE=1`，所以 **P-SNAPSHOT 的 14 个 workload 没有经过任何缓存**。这是后续所有 cache 优化必须首先修正的测量口径。

#### 2.2.2 L1I（`lcvex_l1_i.sv`）

- 只读、直接映射、64B line、64 组、物理地址。
- 命中：请求接受后下一拍返回（约 2 拍从请求到响应）。
- 未命中：单阻塞，8 次 8B 下游读填整行；填充期间不接受新请求。
- 无 tag/data 流水化、无多 outstanding、无预取、无 bank 化。
- 维护：IC IVAU/IALLU 直接清有效位并响应，不下发。

#### 2.2.3 L1D（`lcvex_l1_d.sv`）

- 写通 + no-write-allocate，直接映射，64B line / 64 组 / 4 KiB。
- 读命中 1 拍后返回；写命中同步更新行并立即写下游，未命中不分配。
- 未命中/写通都是单阻塞单 outstanding；填行 8 beats，每次 beat 占一个下游事务。
- 无写缓冲、无 MSHR、无多 bank。

#### 2.2.4 旧统一 L2（`lcvex_l2.sv`，用于 `lcvex_soc_tb` 可选路径）

- 2-way 组相联，256 组 × 2 way = 32 KiB，64B line。
- 读 miss 8 次 8B refill；写通且 miss 不分配。
- 单阻塞单 outstanding，LRU 只有 1 bit/组（2-way）。
- 如果启用到 P-line，它是 I/D/PTW 共享的**统一 L2**，会串行化 I-L1 miss、D-L1 miss、PTW。

#### 2.2.5 新单核写回层次（B4/B5，`lcvex_l1_d_wb.sv` + `lcvex_l2_wb.sv`）

- D-L1 为写回/写分配，64B line，直接映射，单阻塞。
- L2 为 2-way 写回，含 dirty victim 写回和 `CORE_COUNT=1` 的 D-L1 probe/drain。
- 下游仍是 8B M1-B；也是单 outstanding、单事务、8-beat refill/writeback。
- 这是 Catapult SoC/FPGA 的目标单核缓存层次，但尚未接入 P-line 的 `lcvex_soc_tb`，也不是 C2 多核路径。

#### 2.2.6 C2 多核路径（`lcvex_c2_l1_coherent` + `lcvex_l2_cluster`）

- 每核是**统一直连式 L1**（非独立 I/D L1），直接映射，64B line，`S/M/I` 状态，单 outstanding。
- `lcvex_l2_cluster` 是**目录式 MSI 元数据**：“C2 uses the backing PoC as the data source, so this table only records coherence metadata, not the line data itself.”
- 因此共享 L2 **没有数据阵列**：每次核心 miss/refill 都必须从 PoC 读取；共享数据局部性无法被 L2 吸收。
- 每核单 outstanding，cluster 全局单事务；Upgrade/ReadUnique 需要串行 probe 所有其他 sharer。
- 目录 owner 为 one-hot 位图，sharers 为 CORE_COUNT 位；C4 规模测量显示 8/16/32 核的事务吞吐随 N 下降（0.0521→0.0490→0.0473 tx/cycle），且 16 核 default-FP 全 cluster lint/elab 极慢（见 T-018/T-019）。

#### 2.2.7 数据阵列访问模式/bank 化可能性

- 所有缓存 data RAM 是单端口 `logic [7:0] data[...]` 大数组，每次读/写一个 8B chunk，未按 bank/子阵列划分。
- L1D 与 L1I 共享下游仲裁器，但各自独立阵列；在 `lcvex_soc_tb` 中可选独立开启。
- 可 bank 化的点：
  - I-L1 与 D-L1 本来就该物理独立（已有独立模块），可在 P-line 启用后并行服务 I/D；
  - L2 data 可按 set/way/字节 lane 分 bank，支持 refill 与上游命中并行；
  - 但当前**核心/仲裁器也只有一个 outstanding**，单纯 bank 化不能凭空增加单核访存并行度。

### 2.3 总线 / 内存系统

#### 2.3.1 M1-B 内存协议路径

| 模块 | 现状 |
|---|---|
| `lcvex_mem_arb` | 3 端口（PTW/D/IMEM），单 outstanding；优先级 PTW > D > IMEM |
| `lcvex_mem_delay` | 单 outstanding；mode 0 直通，mode 1 延迟 1，mode 2 随机 |
| `lcvex_mem_router` | 单 outstanding；组合解码到 RAM/MMIO；接受当拍锁存目标，响应 hold |
| `lcvex_mem_ram` | 单 outstanding；8B 请求，1 周期响应 |
| `lcvex_axi4_master` | AXI4 Full 128-bit；单 ID、单 outstanding；可 LEN 到 15 但 canonical 64B line 为 LEN=3 |
| `lcvex_axi4_avalon_adapter` | AXI 128-bit 4 beats → Avalon 512-bit 单 word；request/response FIFO 深度 4（ADDR_WIDTH=2）；单 outstanding |
| `lcvex_async_fifo` | Gray 指针异步 FIFO，供 Avalon CDC |

#### 2.3.2 关键瓶颈

- **所有层次都是单 outstanding**：从核心 dmem/imem 到 cache、仲裁、路由、RAM、AXI、Avalon/EMIF，没有二级流水或多事务缓冲（FIFO 只用于 CDC，不提供真正的 outstanding 并行）。
- **8B beat 宽度**：缓存 refill/writeback 使用 8 个 8B 请求，每次要经过单 outstanding 链路；AXI 虽为 128-bit，但只有聚合到 line 后再发，未缩短拍数，且 AXI 本身单 outstanding。
- **仲裁优先**：PTW 永远优先，访存/取指排队；在 MMU/页表遍历时可能长时间饥饿取指。
- **Avalon 适配**：把 64B line 聚合成一次 512-bit Avalon 访问是合理的，但要求整条 line 不跨 64B 边界；首版 `burstcount=1`，没有多 line 流水。
- **可加宽/可流水/可增加 outstanding 的点**：
  - 把 M1-B 从 8B beat 提升到 16B/64B 请求；
  - 给仲裁器/router/RAM/cache 增加 tag 队列/MSHR，允许同一线多 beat 或不同地址的多个事务并发；
  - AXI 侧从单 ID 扩到多 ID/多 outstanding；
  - Avalon 侧允许 burstcount>1 或多个 pending line；
  - 异步 FIFO 加深（4→8/16）以容忍 CDC 抖动。

### 2.4 多核

#### 2.4.1 拓扑

- `lcvex_cluster_top`：每核 `lcvex_core_wrap` → 统一 L1 → `lcvex_l2_cluster` → 共享 PoC RAM/系统控制。
- 每核一个请求端口，但 cluster 只允许 S_IDLE 时接受一个请求，全局单事务。
- round-robin 仲裁：`rr_ptr`；若当前轮询核无请求则找下一个有效请求（有 liveness fallback）。

#### 2.4.2 串行化/扩展性

| 现象 | 证据/代码 |
|---|---|
| 全局单事务 | `lcvex_l2_cluster` 状态机一次只有 `cur_core/cur_addr/cur_idx`，S_IDLE 才 `req_ready` |
| probe 串行 | `S_PROBE_REQ → S_PROBE_WAIT → S_PROBE_COMMIT` 按 `probe_pending_mask` 逐个目标；dirty owner 下刷也是先写 PoC 再释放 probe |
| 共享 L2 无数据阵列 | cluster 只维护目录；缺省从 PoC 填充，或从 dirty L1 probe 拿整行，不缓存 |
| 目录位图 one-hot | owner/sharer 都是 `CORE_COUNT` 位；面积/延迟随核数线性增加 |
| 每核单 outstanding | 即使 cluster 允许并行，单核也无法同时发出多个 L1 miss |
| 默认 FP 全 cluster 综合/elab 资源 | T-018/T-019：8 核约 347s/2.76GB，16 核 32min+ 未完成 |

#### 2.4.3 与 P-line 14 个 workload 的关系

- 现有 14 个 workload 全部是单核，不直接覆盖 C2/C3/C4。
- `P-MC` 有双核 mailbox/reduction/contention workload（`tb/sv/lcvex_c2_perf_mc.S`），但未接入 `perf_runner.py` JSON，只有 C2 SV TB stdout。
- 多核优化需要新增加：双核/四核共享 line 带宽、目录 probe 延迟、同 line 竞争、不同 line 并行、barrier、cacheline ping-pong 等可重复测量。

---

## 3. 测量缺口与必要前置工作

在实施任何 RTL 优化前，建议先补齐测量基础设施；否则无法判断收益来源与回归风险。

### 3.1 P-line 应增加“缓存配置矩阵”

```
make microbench-build  # 当前无缓存基线（已存在）
make microbench-build cache=...  # 未来：-GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1
```

建议使用现有 `lcvex_soc_tb` 参数直接生成多个 runner/配置，不修改 RTL：
- `nocache`（当前快照）
- `l1i_only`
- `l1d_only`
- `l1i_l1d`
- `l1i_l1d_l2`
- 可选 `mem_delay=1/2` 模拟 DDR 延迟

### 3.2 workload 内部分相

- 当前 perf 只输出总 cycle，无法区分 ALU、分支、load-use、cache miss、PTW、FF 等。
- 建议新增微基准或 wrapper 在关键循环边界写 MAGIC/计数器，记录分相 cycle。
- 候选：`t_mem_random` 增加 miss 率估计、`t_ctrl_branch` 区分 taken/not-taken、`t_mem_seq` 分读/写/拷贝。
- 可在 C++ runner 里增加非架构统计（如提交数、内存事务数、取指请求数）而不改 RTL；但若要 cycle-accurate 分相需要 RTL 调试计数器，应作为独立小任务。

### 3.3 IPC/每指令周期基础

- 当前 P-line cycle 数是“到 MAGIC 的整程序周期”，没有指令数快照。
- 增加一个 `retired_insn` 统计（由提交包计数或 runner 接收 commit）即可得到代理 IPC。
- 建议在 P-INFRA 后续任务中把 `cycles` 与 `retired_instructions` 一起输出，避免把不同 workload 的周期数直接比较。

---

## 4. 候选优化方向评估

> 优先级定义：P0 = 建议下一个实施；P1 = 高价值但有中等以上改动/风险；P2 = 远期或依赖前置。
> “预期收益”均为方向性假设，需以新增测量验证；本文件不宣称已实现。

### 4.1 C1. 前端取指缓冲、分支预测/分支折叠（P0）

**现状问题**  
- 单在途取指 + 单响应缓冲，取指与执行不能持续重叠；
- 分支在 ID 解析，任何跳转都冲刷 IF/ID 并重新取指；
- 没有 BTB/RAS/方向预测，循环和函数返回都按顺序取到错误路径再清空。

**候选子项**
1. 增加 2–8 条取指队列（FIFO），在 ID 被 load-use/系统/乘除 stall 时继续取指；
2. 支持 8/16/32 字节取指宽度（目前一次只取 4 字节），但需要先处理跨页/跨行/MMU 翻译；
3. 简单 BTB（直接映射，记录目标地址）+ 2-bit 方向预测 + 返回栈；
4. 分支目标提前到 IF 计算（立即数分支），条件分支在 EX 早期解析；
5. 若不做完整预测，至少实现“顺序预取下一行”或“空闲时预取 PC+8/PC+16”。

**预期收益方向**  
- IPC：循环/分支/调用密集 workload（`ctrl_branch`、`alu_latency`、kernel_sort/matmul/crc）预计受益最大；
- 降低分支气泡和取指等待，可能使现 P-line 中受前端限制的 workload 周期数下降；
- 为未来双发射提供前端带宽基础。

**改动范围**  
- `rtl/lcvex_core.sv`（IF/IFID 控制、flush 逻辑、取指请求）；
- 可能需要新模块 `rtl/lcvex_fetch_buffer.sv` / `rtl/lcvex_branch_predict.sv`；
- `rtl/lcvex_decode.sv` 或 core 内分支目标早期计算。

**难度/风险**  
- 中高。分支预测若引入推测，必须保证错误路径不产生提交/内存副作用；当前无 OoO，风险相对可控，但 flush/MMU 取指 fault 合并逻辑敏感。
- 取指队列会改变在途请求清空/响应丢弃语义，需要重新验证 IABT 合并、TLBI、系统指令排空。
- 不能破坏“架构状态只在 commit 更新”。

**新增测试/测量**  
- `t_ctrl_branch` 扩展：独立 taken/not-taken 循环、函数调用/返回、间接跳转；测量每分支周期；
- 新增前端压力 microbench：密集无条件跳转、密集返回、长依赖链间无分支；
- SVA：flush 后无 stale 响应、取指队列在有 stall 时仍满但无重复/丢指；
- QEMU 锁步全量回归（尤其 MMU/异常/TLBI 场景）。

**与 P-line 14 关系**  
- 直接影响：`alu_latency`、`alu_ilp`、`ctrl_branch`、`muldiv`、`kernel_crc`、`kernel_sort`、`kernel_matmul`、部分 `mem_ldst`（循环控制）。
- 间接：所有 workload 因 fetch 交付更快都可能受益。

### 4.2 C2. 把现有缓存接入 P-line 并建立真实缓存基线（P0）

**现状问题**  
- 当前 P-line 使用无缓存默认配置，导致 cache 相关优化无法量化；
- 已有 I/D L1、旧 L2、B4/B5 写回层次，但没有统一测量入口。

**候选子项**
1. 为 `microbench-build` 增加参数化缓存配置（不改 RTL，只改 Makefile/脚本/顶层参数）；
2. 用 `-GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1` 跑出 14 workload 的新基线；
3. 增加 cache 命中/缺失统计（可在 BFM/内存侧计数，或加非架构 debug 计数）；
4. 比较 no-cache vs L1 vs L1+L2，确定真实访存瓶颈。

**预期收益方向**  
- 对顺序访存/循环 kernel，L1/L2 命中可显著降低内存延迟；
- 为后续是否做 MSHR/多 outstanding/加宽提供数据支撑；
- 该方向本身不是 RTL 性能收益，而是把“不可见收益”变成可验证。

**改动范围**  
- `Makefile`、`sim/microbench/perf_runner.py`、`scripts/build-microbench.sh` 或新增 `scripts/run_perf_matrix.sh`；
- 不修改 RTL（除非需要暴露计数信号，见 P1）。

**难度/风险**  
- 低（仅构建/测量脚本）；不要改变现有 `make microbench-build` 默认行为，避免破坏当前 lockstep/测试。

**新增测试/测量**
- 生成配置矩阵 JSON：`nocache/l1/l1l2`；
- 对每个 workload 输出 `cycles`、`retired_insn`（如果可统计）、内存请求/命中计数；
- 至少跑一次 P-SNAPSHOT 并在同 SHA 下比较。

**与 P-line 14 关系**  
- `mem_seq/random/ldst`、`kernel_*` 直接相关；ALU/FP/NEON 间接相关（指令 fetch 也可命中 I-L1）。

### 4.3 C3. 访存 outstanding / MSHR / 非阻塞缓存（P1）

**现状问题**  
- 单 outstanding 贯穿核心到总线；load/store 等待期间整个流水线冻结；
- 缓存 miss 8-beat refill 期间不能发起其他访问；
- 没有写缓冲/合并缓冲，store 也要等下游响应。

**候选子项**
1. 核心支持每核 2–4 个 dmem outstanding（需要 `mem_req` 带 transaction ID、响应重排序/按序返回）；
2. L1D/L2 增加 MSHR，处理多个 miss 并对同 line 合并；
3. 增加写合并缓冲，store 在提交后异步写回（需保持内存序/异常语义）；
4. 增加 store buffer 或 load queue，允许后续不相关指令在 load 等待时继续执行（顺序核需要小心访存序）；
5. 不立即做完整 OoO，可以先做“访存指令不冻结前端”的轻量版本，例如仅当后续指令与在途 load 无依赖且无 store 屏障时才继续。

**预期收益方向**  
- 内存带宽/延迟隐藏；`mem_seq`、`mem_random`、`mem_ldst`、`kernel_*` 和未来多核工作负载；
- 提高 memory-level parallelism，尤其随机 pointer chase（多个 chase 可并行）和流式拷贝。

**改动范围**
- `rtl/lcvex_core.sv`（dmem 状态机、exmem_can_adv、对 multiple outstanding 的 ID 管理）；
- `rtl/lcvex_pkg.sv`（mem_req/mem_rsp 或 sideband ID）；
- `rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_ram.sv`（事务表）；
- `rtl/lcvex_l1_d.sv`/`lcvex_l1_d_wb.sv`/`lcvex_l2.sv`/`lcvex_l2_wb.sv`（MSHR/非阻塞）。

**难度/风险**  
- **高**。访存序、异常顺序、exclusive/原子、页表自修改、checkpoint/drain 都依赖单事务顺序；多 outstanding 必须严格定义线性化点。
- 现有很多 SVA 假设单 outstanding；需同步更新。

**新增测试**  
- 新增 2 路/4 路独立 pointer chase，比较串行 vs 并行延迟；
- 背压/多响应乱序测试、同地址合并、fault 后响应配对、原子/独占在多 outstanding 下不丢失；
- L1/L2 MSHR 定向 SV/Cocotb；QEMU 锁步含 Linux 内存压力场景。

**与 P-line 14 关系**  
- `mem_seq`（拷贝/读写）、`mem_random`、`mem_ldst`、`kernel_matmul/sort/hash/crc` 的访存部分；
- 当前无缓存基线可能让收益显得很大，需先做 C2 缓存基线后再判断真实收益。

### 4.4 C4. 多核共享 L2 数据阵列、probe 并行化、目录位图优化（P1）

**现状问题**  
- 共享 L2 只有目录，没有数据阵列；
- 全局单事务 + 串行 probe，核数增加吞吐下降；
- owner/sharer one-hot 位图，面积和 probe 遍历线性增长。

**候选子项**
1. 在 `lcvex_l2_cluster` 或新的 cluster L2 数据缓存中增加真实数据阵列（复用 `lcvex_l2_wb`），使 S 状态共享行可从 L2 直接填充，不必每次读 PoC；
2. 增加多事务/多 outstanding cluster：至少允许不同 line 的事务并行，同 line 仍串行；
3. 并行/多播 probe：Upgrade/Invalidate 可同时向所有 sharer 发 probe（需要每核 probe 通道状态缓存），而不是逐个；
4. 目录 owner 编码压缩（`$clog2(CORE_COUNT)`）或使用共享者集合位图但优化遍历；
5. 每核 I-L1 与 D-L1 分离（当前 C2 共用统一 L1），避免取指和数据 miss 互相干扰；
6. 每核每线程多个 outstanding（依赖 C3）。

**预期收益方向**  
- 多核共享数据/同步工作负载的事务延迟、吞吐、扩展性；
- 减少 PoC 流量；降低 N 核 probe 串行成本。

**改动范围**  
- `rtl/lcvex_l2_cluster.sv`、`rtl/lcvex_l1_coherence.sv`（c2_l1_coherent）、`rtl/lcvex_core_wrap.sv`、`rtl/lcvex_cluster_top.sv`；
- 可能需要新的 `rtl/lcvex_l2_cluster_wb.sv` 或复用 `lcvex_l2_wb.sv`；
- `rtl/lcvex_cluster_pkg.sv`。

**难度/风险**  
- **很高**。目录一致性是所有多核正确性的核心；多 outstanding/并行 probe 会暴露更多竞态。
- 当前 C2/C3/C4 验收只是语义子集，不是完整 ARM 内存模型；不能以“通过 synthetic smoke”代替。
- 需保持 `CORE_COUNT=1` 单核锚点不回归。

**新增测试**  
- 扩展 `lcvex_c4_cluster_scale_tb` 的事务/probe 并行断言；
- 新增 P-MC workload：两个核交替读写同一/不同 line，测量同 line 竞争与不同 line 并行；
- 增加目录不变式 SVA：M owner 唯一、S 无 owner、probe 完成后无 stale reply；
- 在 2/4/8/16 核跑 synthetic 和（如果资源允许）更真实的双核 lockstep。

**与 P-line 14 关系**  
- 单核 P-line 不直接覆盖；但 C2 缓存/多 outstanding 的基础会影响未来把 P-line 扩展到双核/四核。
- 现有 `P-MC` 双核 workload 可扩展为性能报告。

### 4.5 C5. 总线加宽、AXI 多 ID/多 outstanding、Avalon 多 burst、异步 FIFO 加深（P1/P2）

**现状问题**  
- M1-B 8B beat 使 cache refill/writeback 需 8 次串行事务；
- AXI4 canonical 128-bit 但单 ID/单 outstanding；Avalon 一次只发一个 64B word；
- FIFO 深度 4 只用于 CDC，不是多 outstanding 缓冲。

**候选子项**
1. 将 M1-B 下游数据宽度提升到 16B 或 64B（cache line 一次/两次传输）；
2. AXI4 master 支持多 ID 和多个 outstanding；Avalon adapter 支持 `burstcount>1` 或多个 pending line；
3. 内存仲裁器支持事务表与乱序返回（尤其不同地址）；
4. 加深异步 FIFO 并增加 credit 流控；
5. 若保持 64B line，至少让 refill 请求以 burst/block 形式发出，而不是 8 个独立 M1-B 事务。

**预期收益方向**  
- 内存带宽、长延迟隐藏、DDR/EMIF 利用率；
- 对 `mem_seq`、`mem_random`、大 buffer workload 和未来多核内存压力直接有益。

**改动范围**  
- `rtl/lcvex_pkg.sv`（mem_req/mem_rsp 数据宽度/ID）；
- `rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_mem_delay.sv`；
- `rtl/lcvex_l1_i/l1_d/l2/l2_wb` 的 refill 路径；
- `rtl/lcvex_axi4_master.sv`、`rtl/lcvex_axi4_avalon_adapter.sv`、`rtl/lcvex_async_fifo.sv`。

**难度/风险**  
- **高**（协议级改动），尤其涉及现有 M1-B 大量测试和 AXI/Avalon SVA。
- 8B 是当前模型/RAM 的稳定边界，扩大后需要重新验证字节使能/跨行/fault。

**新增测试**  
- 大块顺序读/写带宽；AXI 多 ID 乱序返回；
- M1-B 多 outstanding 背压、fault、原子/独占配对；
- Avalon adapter burstcount、CDC 双时钟、reset/calibration。

**与 P-line 14 关系**  
- 主要作用于 `mem_seq/random/ldst` 与 kernel 内存繁忙部分；但单核单 outstanding 会限制收益，建议先做 C3（MSHR/outstanding）或至少同时做。

### 4.6 C6. 更深流水线（P2）

**候选**
- 将 decode 拆为“预译码/译码”，或将 EX 拆为 ALU/AGU + 访存地址阶段；
- 提高 target Fmax，为后续双发射/更复杂前端提供时序余量。

**预期收益方向**  
- 主要是频率/时序收益，不是直接 IPC；
- 在 Verilator 仿真中不会体现，在 FPGA 上才有意义。

**改动范围**  
- `rtl/lcvex_core.sv`、`rtl/lcvex_decode.sv`、`rtl/lcvex_pkg.sv` 流水线字段。

**难度/风险**  
- 高：所有 forwarding、hazard、flush、系统指令排空、异常合并都需要重新验证。

**测试**  
- QEMU 锁步全量；新增长依赖链/分支压力。
- 如果目标是 FPGA 性能，还需 Quartus/STA（本任务不启动）。

### 4.7 C7. 顺序双发射 / 2-wide（P2）

**候选**
- 前端 2-wide fetch/decode，双 ALU/FP 执行槽，双写回/双 commit 或多写回到统一提交包；
- 优先支持两条无依赖、无访存冲突的整数/FP 指令配对。

**预期收益方向**  
- `alu_ilp`、`neon_vect`、`fp_scalar/fp16` 等 ILP workload 可接近 2x；
- 但分支和访存等待仍会限制，需先解决 C1/C3。

**改动范围**  
- `rtl/lcvex_core.sv`、`rtl/lcvex_decode.sv`、`rtl/lcvex_pkg.sv`、可能新增执行单元，重构提交包多写回；
- 寄存器文件多读端口/多写端口或旁路网络。

**难度/风险**  
- 极高。当前提交包/锁步协议、FP/NEON 多结果路径、异常/系统指令顺序都假设每周期至多一条提交；
- 多发射若共享一个提交包需定义字段扩展；若每周期多条提交，则 QEMU difftest 协议需同步改。

**测试**  
- 全新双发射定向测试、QEMU lockstep 每条指令提交序列、FP/NEON 多写回；
- P-line 的 `alu_ilp_add2/4/8` 可直接作为吞吐代理。

### 4.8 C8. Cache 多 bank/更宽行/预取（P2）

**候选**
- L1/L2 数据阵列分为多个 bank，使 refill 写入与命中读并行；
- 行宽从 64B 扩到 128B（会改变 AXI/line/probe 契约）；
- 增加 I/D prefetch（顺序预取、next-line）。

**预期收益方向**  
- 降低 miss 延迟、提升顺序访问带宽；
- 对 `mem_seq`/kernel 有利；对随机访问有限。

**改动范围**  
- `lcvex_l1_i/l1_d/l2/l1_d_wb/l2_wb` 及总线协议。

**难度/风险**  
- 中高；与 C3/C5 有依赖。预取需避免污染和错误预测。

### 4.9 候选汇总

| ID | 方向 | 收益方向 | 改动范围 | 难度/风险 | 新增验证 | P-line 关系 | 优先级 |
|---|---|---|---|---|---|---|---|
| C1 | 前端取指缓冲/分支预测 | IPC | core/decode | 中高 | 分支/前端 SVA、ctrl 扩展 | 全部，尤其 ALU/CTRL/kernel | **P0** |
| C2 | 缓存配置接入 P-line | 可测量性 | Makefile/脚本 | 低 | 配置矩阵 | 全部（mem/kernel 直接） | **P0** |
| C3 | MSHR/多 outstanding | 带宽/MLP | core/cache/arb/router | 高 | 多 outstanding/原子/序 | mem_*、kernel_* | P1（建议 C2 后） |
| C4 | 共享 L2 数据+probe 并行 | 多核扩展 | cluster/L1/coh | 很高 | C2/C3/C4 synthetic、P-MC | 未来多核线 | P1 |
| C5 | 总线加宽/AXI 多 ID | 带宽/延迟 | pkg/arb/cache/axi/avalon | 高 | 总线/CDC/多 outstanding | mem_*、kernel_* | P1/P2 |
| C6 | 更深流水 | Fmax | core/decode | 高 | 全量 lockstep、STA | 间接 | P2 |
| C7 | 双发射 | ILP/IPC | core/decode/commit | 极高 | 双发定向、协议扩展 | alu_ilp/fp/neon | P2 |
| C8 | cache bank/宽行/预取 | 带宽/延迟 | cache/总线 | 中高 | cache SVA、stream | mem_*、kernel_* | P2 |

---

## 5. 建议实施顺序

### 5.1 第一梯队（先建立测量，再做前端）

1. **C2：P-line 缓存矩阵**  
   - 不修改 RTL，先把 `nocache` 与 `l1/l1+l2` 基线跑出来。
   - 产出：新 baseline JSON、cache 配置说明。
2. **C1：前端取指缓冲 + 简单分支目标/预测**  
   - 先加取指队列，再评估分支预测；用 `ctrl_branch`、`alu_ilp` 验证。
   - 建议拆成更小任务：PE-1 取指队列/预取；PE-2 简单 BTB/RAS。
3. **C3：访存 outstanding/MSHR**  
   - 在 C1/C2 数据上确认内存瓶颈，再动核心/缓存协议。
   - 建议先做“store buffer + 2 个 load outstanding”的受限版本。

### 5.2 第二梯队（多核与总线）

4. **C4：共享 L2 数据阵列 + 并行/多播 probe**  
   - 先做数据阵列，再做 probe 并行，避免同时引入两个大变量。
5. **C5：总线加宽/多 ID/多 burst**  
   - 和 C3 配套，最好在 C3 稳定后实施，避免单点同时改协议。

### 5.3 远期

6. **C6/C7/C8**：双发射、更深流水、cache bank/宽行/预取。
   - 需要有前端和访存基础，且根据 FPGA 频率/面积目标决定优先级。

---

## 6. 风险与回归策略

### 6.1 不改动验证红线

- 架构状态只在 commit 更新；系统指令 ID 提交、异常合并、MMU 取指 fault 合并语义不能变。
- QEMU lockstep 的 PRE/COMMIT 严格一一对应；新增多提交/预测路径前必须约定协议扩展。
- 单核非相干路径（`lcvex_soc_tb`、`lcvex_catapult_soc_top`）必须保持可编译/可回归。

### 6.2 每个优化任务的建议回退方式

- 用参数/宏开关隔离：新前端/缓存/MSHR 可关闭时，旧路径仍为默认。
- 保留原 SVA/测试不变，新增断言只补充不删除。
- 每次 RTL 改动：
  1. L0：`git diff --check` + 定向 lint；
  2. L1：相关 SV/Cocotb 单元（core/l1d/l2/mmu/axi/mc）；
  3. L2：QEMU 锁步定向集；
  4. L3：Gate D 回归；
  5. 性能：跑同 SHA 的 P-line baseline。

### 6.3 已知不能做的

- 不启动 Quartus，不宣称 A10/Fmax；
- 不把 Verilator cycle 当架构签核；
- 不引入 SVE/ACE/CHI；
- 不破坏单核/多核正确性回归。

---

## 7. P-line 14 workload 映射与测量计划

| workload | 主要瓶颈代理 | 对哪个候选最敏感 |
|---|---|---|
| alu_latency | 依赖链 + 循环分支/前端 | C1 前端 |
| alu_ilp | 独立指令被单发射串行 | C7 双发射（远期）；C1 前端 |
| ctrl_branch | 分支频率 | C1 分支预测/取指缓冲 |
| muldiv | 乘除多周期阻塞 | C6/C1 前端；也许未来执行单元 |
| mem_seq | 访存吞吐、缓存 | C2/C3/C5/C8 |
| mem_random | 随机访存延迟、MLP | C3/C4/C5 |
| mem_ldst | load-use、LDP/STP、store-forward | C1/C3 |
| fp_scalar | FP 链/吞吐 | C7（双发射）；C1 前端 |
| fp_fp16 | FP16 吞吐 | C7；C1 |
| neon_vect | SIMD 吞吐/访存 | C7；C3/C8 |
| kernel_crc | 循环/查表/内存 | C1/C2/C3 |
| kernel_hash | 循环/内存 | C1/C2/C3 |
| kernel_matmul | 循环/访存 | C1/C2/C3/C7 |
| kernel_sort | 分支/访存 | C1/C2/C3/C4 |

---

## 8. 下一步任务建议（供集成者拆分）

- **PE-0（测量）**：P-line 缓存矩阵 + retired instruction 统计；写集 `Makefile`/`scripts`/`sim/microbench`/`docs`。
- **PE-1（前端）**：取指队列/预取；写集 `rtl/lcvex_core.sv`、可能新增 fetch buffer；验证 QEMU 锁步 + `ctrl_branch`。
- **PE-2（前端）**：简单 BTB/RAS/分支方向预测；写集 core + 新模块；验证 QEMU + 分支压力。
- **PE-3（访存）**：受限多 outstanding/store buffer；写集 core/cache/arb/pkg；验证 mem_* + 原子/独占。
- **PE-4（多核）**：cluster 共享 L2 数据阵列；写集 cluster/L1；验证 C2/C3/C4 synthetic + P-MC。
- **PE-5（多核）**：probe 并行/多播与目录编码优化；写集 cluster。
- **PE-6（总线）**：M1-B/AXI 多 outstanding/加宽；写集 pkg/arb/cache/axi/avalon。

---

## 9. 结论

- **最大瓶颈**：单发射、顺序、无取指缓冲、无分支预测、单 outstanding 访存的组合使得前端和内存等待成为 IPC 天花板；当前 P-line 又是在无缓存默认配置下测得，无法直接指导缓存优化。
- **Top 3**：
  1. 前端/分支/取指缓冲（P0）
  2. 缓存接入 P-line + 访存 outstanding/MSHR（P0/P1）
  3. 多核共享 L2 数据阵列与 probe 并行化（P1）
- **建议实施顺序**：先测量（C2）→ 前端（C1）→ 访存并行（C3）→ 多核（C4）→ 总线（C5）→ 远期双发射/更深流水（C6/C7/C8）。
