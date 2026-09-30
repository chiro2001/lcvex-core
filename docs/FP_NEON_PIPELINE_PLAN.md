# FP/NEON 流水化与多周期执行优化计划

> 状态：**已审核，可进入任务拆分；首选方案已收敛，量化结果仍待后续任务验证**
> 日期：2026-09-03
> 审核代码基线：`feature/p7-final` @ `d892ba7820cd6db39a1144d8d4b3236a43a11891`
> 最新 full-FP 综合输入：`87777425e0a23c65763b847d39a2074f9bc77962`
> 目标范围：`rtl/lcvex_fp_scalar.sv`、`rtl/lcvex_neon_fp.sv` 与
> `rtl/lcvex_core.sv` 的 FP/Advanced SIMD 浮点执行路径
> 文档性质：本文件是实施计划，不代表共享执行单元、A10 fit、STA 或性能收益已经完成。

## 0. 执行摘要

当前首要问题是 **full-FP 资源估计超过器件容量**，不是已经由 STA 证明的某条
FP 关键路径。T-20260902-010 的正式 RTL synthesis 结果为 482,334 ALM，目标
10AX115N4F40E3SG 有 427,200 ALM，估计超出 55,134 ALM（112.91%）；尚未运行
full-FP fitter/STA。当前 `lcvex_neon_fp` 又组合例化 4 个完整
`lcvex_fp_scalar`，core 另有 1 个 scalar 实例，因此应先消除结构复制，再谈吞吐。

本计划冻结以下首选路线：

1. **先面积、后时序、最后吞吐。** 先让 full-FP 在相同参数、相同工具和相同 SHA
   下具备可布线余量；只有 fit/STA 给出关键路径后才增加寄存器级。
2. **首版采用单在途、阻塞式 FP transaction。** core 在一条 FP/NEON FP 指令
   完成前不让年轻指令越过它执行，保持单发射、顺序执行、顺序提交和精确异常。
3. **首选一个共享 64-bit lane engine。** 标量 H/S/D 使用一个 slot；NEON FP
   按 32-bit/64-bit slot 分时，整条向量指令只产生一次原子 V/FPSR effect。
4. **先把现有组合接口变成请求/响应握手。** request 接受时锁存操作数、FPCR 和
   元数据；response 在 backpressure 下保持稳定；reset/kill 清除未提交 transaction。
5. **scoreboard、年轻整数指令绕过和多 FP 在途不属于首版。** 当前核心没有覆盖
   所有指令的顺序退休队列；仅增加 FP scoreboard 不能保证年轻整数结果、异常、
   IRQ、store 和 FP 结果按序退休，且会越过项目“非 OoO”边界。
6. **第二 lane 或可流水吞吐只作为后续条件分支。** 一 lane 版本通过功能门和
   A10 fit/STA 后，再用同一 PPA/性能矩阵比较二 lane；没有量化收益不立项。

## 1. 审核依据与纠正项

### 1.1 已验证事实

| 项目 | 当前事实 | 证据/代码 |
| --- | --- | --- |
| A10 full-FP synthesis | 正式仓库 RTL synthesis PASS；482,334 ALM、720,722 combinational ALUT、80,925 registers、247,276 block-memory bits、186 DSP | [`T-20260902-010.json`](tasks/evidence/T-20260902-010.json) |
| 器件与参数 | 10AX115N4F40E3SG；synthesis 输入为 `A64_FP_SIMD=1`、L1 64 sets、L2 64×1、FPGA top `FETCH_FIFO_ENABLE=1` | [`lcvex_catapult_a10_top.sv`](../fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv) |
| physical implementation | full-FP 未运行 fitter、STA、assembler 或板测；不能宣称 fit 或 Fmax | [`T-20260902-010 handoff`](handoffs/T-20260902-010-a10-full-fp-synth-merge.md) |
| scalar FP | H/S/D 大部分运算是组合函数；FDIV 使用 256 次 bit-serial divider；FSQRT 仍是 64 轮恢复平方根组合展开 | [`lcvex_fp_scalar.sv`](../rtl/lcvex_fp_scalar.sv) |
| NEON FP | 组合例化 4 个完整 scalar 单元；NEON 当前不发 FDIV；每个 lane 的 flags 在模块内 OR | [`lcvex_neon_fp.sv`](../rtl/lcvex_neon_fp.sv) |
| core 执行控制 | 只有乘除和 scalar FDIV 驱动 `ex_busy`；忙时保持 ID/EX 并冻结前端；其它 FP/NEON FP 在 EX 组合求值 | [`lcvex_core.sv`](../rtl/lcvex_core.sv) |
| 架构状态 | V/FPCR/FPSR 只在 commit 边界更新；FPCR/FPSR reset、权限、mask 和 raw-bit 差分契约已冻结 | [`P7_FP_NEON_PROTOCOL.md`](P7_FP_NEON_PROTOCOL.md) |
| 性能代理 | 已有 `fp_scalar`、`fp_fp16`、`neon_vect` 整程序 cycle 数据，但来自旧 SHA，且是 Verilator 代理，不是 A10/Fmax 证据 | [`PERFORMANCE_SNAPSHOT.md`](PERFORMANCE_SNAPSHOT.md) |

### 1.2 原草案的主要问题

| 原表述/缺口 | 审核结论 | 本版处理 |
| --- | --- | --- |
| “FP/NEON 关键路径已经确定” | 尚无 full-FP post-fit STA；只能确认当前 RTL 存在很宽的组合结构 | 把 STA 关键路径识别放到 fit 后，不预判路径归属 |
| “FP 实例约占全设计 83% ALUT” | 当前仓内 evidence 没有可复核的 hierarchy 占比 | 删除该结论；Phase 0 强制做 hierarchy/standalone 资源分解 |
| 直接为现有 scalar “保留 valid/ready” | 现有接口没有 `ready`，只有 `valid/div_busy/div_done` | 先冻结新的 transaction 接口，再迁移算术实现 |
| 默认推荐二 lane | 没有一/二 lane 同 SHA PPA 与 workload 对比 | 首选一 lane；二 lane只作为 fit 后的受控 sweep |
| “二 lane下 2D 需要两拍” | 二个 64-bit lane engine 可在一个 slot wave 处理 2D；原拍数不一致 | 用 slot 数和实测 `T_op` 公式表达，不先写死总 latency |
| scoreboard 即可让独立标量绕过 | scoreboard 只解决相关，不解决全局顺序退休、异常和 store 可见性 | 首版禁止绕过；未来另开退休结构架构评审 |
| MEM/WB 加 tag 即可接收乱序结果 | 不同时延操作可能乱序完成，且年轻非 FP 也可能先到 WB | 首版只允许一个 transaction，天然按序完成 |
| 所有 FP load/store 都需新 fence | 当前 load/store 继续走既有 MEM 路径；FPCR/FPSR MSR 已通过 ID system commit 排空 | 不新增无依据 fence；只验证现有 drain 与新 engine 的交界 |

## 2. 范围与非目标

### 2.1 本计划包含

- scalar H/S/D 已支持运算的 transaction 化和多周期实现；
- NEON FP 2S/4S/2D/4H/8H 的 lane/slot 分时；
- scalar FCMP 的 NZCV、FP→整数的 GPR 结果、V 写回与 FPSR flags；
- core 的请求、等待、响应保持、flush/kill、EX/MEM 接收和 commit backpressure；
- 现有 P7 raw-bit/SV/Cocotb/QEMU lockstep 回归；
- 相同参数的资源分解、full-FP synthesis、fitter、STA 和性能对比。

### 2.2 本计划不包含

- 新增 ISA、扩大 P7 指令矩阵、SVE/SME、NEON 整数单元重构；
- FP exception-enable trap、FEAT_AFP、改变 FPCR/FPSR mask；
- OoO、年轻整数/访存绕过未完成 FP、通用 ROB、双发射或多提交；
- 修改 QEMU 参考结果、放宽 raw-bit/NaN/FPSR 比较或关闭断言；
- 在通用 RTL 中引入 Intel/Altera 厂商 FP IP；
- 用 `A64_FP_SIMD=0` 作为 P7 发布回退。该开关仅用于 no-FP 实验，关闭后软件
  不得执行 FP/Advanced SIMD，不能替代 full-FP 功能验收。

## 3. 不可变架构与时序契约

### 3.1 架构状态

| 状态 | reset | 权限 | 唯一更新点 | 新执行单元要求 |
| --- | --- | --- | --- | --- |
| V0–V31 | 全零 | 受 CPACR_EL1.FPEN | 普通 commit | response 只携带候选结果；busy/done 不写 V |
| FPCR | `0x00000000` | EL0/EL1 MRS/MSR，受 FPEN | ID system commit | request 接受时锁存 FPCR；执行中不得重读实时 FPCR |
| FPSR | `0x00000000` | EL0/EL1 MRS/MSR，受 FPEN | MSR commit 或运算 commit | 各 slot 仅 OR 本指令 flags；与旧 FPSR 的 sticky OR 仍在 commit |
| CPACR_EL1.FPEN | `0b00` | CPACR 仅 EL1 MRS/MSR | ID system commit | trap 在发 request 前确定；被 trap 指令不得启动 engine |
| scalar NZCV | 既有 reset | FCMP/系统语义 | commit | FCMP response 携带本指令 NZCV，未完成时不得旁路为有效值 |

FPCR/FPSR mask、FPEN trap syndrome、NaN payload、signed zero、DN/FZ/FZ16、
RMode/AHP 和 raw-bit 比较均以 [`P7_FP_NEON_PROTOCOL.md`](P7_FP_NEON_PROTOCOL.md)
为唯一规范。优化不得重新解释浮点语义。

### 3.2 顺序与提交

- 每周期至多一个 commit packet；QEMU `PRE(N) → COMMIT(N) → FP_COMMIT(N)` 与
  RTL `seq` 继续一一对应。
- FP/NEON FP 指令从 ID/EX 启动后，core 必须保持该指令及其前端 token，直到
  response 被 EX/MEM 原子接收；不得重复 issue 或重复 retirement。
- 在首版单在途模式下，年轻指令不得越过未完成 FP transaction。结果天然按程序
  顺序到达，因此不需要 completion reorder queue。
- V 写回、scalar FP 写回和整条 NEON FP 的 lane 聚合都只产生一个架构提交；
  不得把每个 lane 暴露为多条 commit。
- FP load/store 与 NEON load/store继续走既有内存流水线。新 engine 不拥有 store
  副作用，也不改变单 Q load/store 的预检和提交 ABI。

### 3.3 backpressure、kill 与 reset

- request 只在 `req_valid && req_ready` 接受一次；接受时锁存所有输入，随后不依赖
  ID 组合信号变化。
- response 的 payload 在 `rsp_valid && !rsp_ready` 时逐位稳定；只有
  `rsp_valid && rsp_ready` 才释放 transaction。
- `commit_ready=0` 可让结果停在 EX/MEM 或 MEM/WB，但不得使 engine 重发、V/FPSR
  提前更新或 response 被覆盖。
- reset 必须把 engine 状态、slot index、部分结果、flags accumulator、request
  ownership 和 response valid 清零；reset 后不得出现幽灵 response。
- 由更老指令触发的 `fetch_merge_wb`、`wb_exc_commit`、restore 或其它 core kill
  必须取消年轻 FP transaction；被 kill 的 transaction 之后不得产生 response/
  commit effect。分支本身不得越过一个更老的 busy FP transaction。

## 4. 首选微架构

### 4.1 结构

```text
ID/EX
  │  one request (scalar or vector FP)
  ▼
lcvex_fp_exec ── request latch / one owner / slot sequencer
  │
  ├─ classify + unpack
  ├─ one shared 64-bit lane engine
  │    ├─ add/sub/mul/fma/convert/minmax/rint/compare
  │    ├─ iterative divide
  │    └─ iterative square root
  ├─ normalize + round + pack
  └─ 128-bit result accumulator + per-instruction flags OR
  │
  ▼  one held response
EX/MEM → MEM/WB → commit → V/GPR/NZCV/FPSR
```

core 最终只例化一个 FP 执行入口。`lcvex_neon_fp` 可在迁移期作为纯
formatter/reference wrapper，不能继续在发布配置中拥有 4 个完整 scalar 实例。
NEON 整数 `lcvex_neon_int` 保持独立。

### 4.2 transaction 接口

建议定义 `fp_exec_req_t` / `fp_exec_rsp_t`（具体字段名由实现任务在 package 中
冻结），至少包含：

- request：scalar/vector 类型、op、H/S/D、arrangement、quad、rd、是否写 V/GPR/
  NZCV/FPSR、三个 raw operand、整数转换输入/scale、rint mode、FPCR snapshot、
  PC/insn 或 core 内部 ownership tag；
- response：128-bit V/raw FP result、64-bit integer result、NZCV、每指令 FPSR flags、
  对应写使能和 ownership tag；
- control：`req_valid/req_ready`、`rsp_valid/rsp_ready`、`kill`、`busy`（仅观测）。

接口规则：

1. `req_ready` 只在 engine 无 owner 且无待消费 response 时为 1；首版 outstanding
   深度严格为 1。
2. request 接受后，slot 选择、操作数、FPCR 和目的元数据全部来自内部寄存器。
3. 特殊值可走较短内部路径，但首版建议按 op/format 固定可预测 latency；若启用
   data-dependent early-out，测试和计数器必须记录允许范围，不能悄然改变协议。
4. response 可以早于 commit 产生，但其任何架构 effect 只能随原指令 commit。
5. `kill` 优先于内部推进和 response 产生；`reset` 优先级最高。

### 4.3 lane/slot 调度

首选一个 engine，继续利用当前 FP16 “一个 32-bit slot 含两个 H lane”的表示：

| 形式 | 每条指令的 slot 数 | 原子结果 |
| --- | ---: | --- |
| scalar H/S/D | 1 | scalar 低 16/32/64 位语义不变 |
| NEON 2S | 2 | Vd[63:0]，高 64 位清零 |
| NEON 4S | 4 | Vd[127:0] |
| NEON 2D | 2 | Vd[127:0] |
| NEON 4H | 2 × 32-bit H slot | Vd[63:0]，高 64 位清零 |
| NEON 8H | 4 × 32-bit H slot | Vd[127:0] |

指令 latency 不在计划阶段伪造为固定拍数。实现后统一按下式记录：

```text
T_instruction = T_accept + Σ T_op(format, slot) + T_finalize
```

slot 完成时把结果写入内部 accumulator 的确定切片，并执行
`flags_acc_next = flags_acc | slot_flags`。最后一个 slot 完成后才置 `rsp_valid`。
任意中间结果不得通过 forwarding 或 commit packet 可见。

若后续评估二 lane，2S/2D/4H 为一个 slot wave，4S/8H 为两个 wave；是否采用二
lane 只能由 §7 的同 SHA 面积、STA 与 workload 门决定，不能只按理论拍数决定。

### 4.4 运算内部优化顺序

1. **结构共享先行**：先确认只有一个发布态 lane engine，取得最大的确定性面积收益。
2. **FSQRT 改迭代**：当前 64 轮 restoring sqrt 是组合展开；改为有寄存器的逐步
   迭代，特殊值分类与最终 round/pack 保持 bit-exact。
3. **FDIV 收敛为一个 divider**：移除 scalar H 双 divider 的并行复制，由 slot
   调度处理两个 H lane；保留除零、NaN、Inf、subnormal 和 sticky 语义。
4. **共享 classify/normalize/round/pack**：不同 op 族复用公共级，避免每个 case
   分支综合成重复宽逻辑；以 hierarchy 报告验证是否真的共享。
5. **寄存器切级由 STA 驱动**：若 fit 后路径落在 unpack/align、multiply/FMA、
   normalize/round 或 result mux，再在对应边界加寄存器。单 transaction 内部切级
   不等于允许多 transaction 在途。
6. **吞吐流水后置**：只有一 lane fit/STA 通过且 workload 显示 FP execute busy
   是主要瓶颈，才评审 initiation interval < latency；此时仍须保证按序完成，
   不允许年轻整数/访存越过。

## 5. 分阶段实施与依赖

```text
FP-P0 基线/资源分解
        ↓
FP-P1 transaction wrapper + core 单在途握手（仍用 legacy 运算语义）
        ↓
FP-P2 单 lane + NEON slot 分时（消除 4-lane 复制）
        ↓
FP-P3 iterative sqrt/div + 公共 round/pack 收敛
        ↓
FP-P4 全量功能/性能 + 一/二 lane 受控 PPA sweep
        ↓
FP-P5 full-FP synthesis → fitter → STA → Gate F 候选
        └─ STA 红 → FP-P3T 定向切级 → 重新执行 FP-P4/P5
        └──────────────→ [条件满足才开] FP-P6 吞吐流水/二 lane
```

每个实现任务都必须同时提交 RTL、定向测试、必要文档、handoff 和 evidence；下游
任务只依赖已 `done` 的上游任务。

### FP-P0：基线与资源分解

进入条件：冻结一个 candidate SHA、Quartus 21.4 Build 67、10AX115N4F40E3SG 和
与 T-010 相同的顶层参数；先确认当前 P7 测试没有未解释红项。

工作项：

- 复用 T-010 作为历史 full-top 锚点，在当前冻结 SHA 重建至少 no-FP、scalar
  standalone、4-lane NEON FP standalone 和 full-FP 四组报告；
- 保存 hierarchy 资源、DSP 映射、寄存器、comb ALUT、fanout 和综合 wall/峰值；
- 重新运行 `fp_scalar`、`fp_fp16`、`neon_vect`，另增加无访存的 op/format 依赖链
  与独立链 microbench；
- 增加或导出 `fp_issue`、`fp_busy_cycles`、`fp_rsp_wait_cycles`、各 op/format
  计数，避免用 `muldiv_stall` 猜测 FP 延迟；
- T-010 已记录 P7-2 Cocotb 的 DUP/SQADD decode overlap 已知失败。Phase 0 必须在
  当前 SHA 复核并由独立任务修复，不能把它列为“允许红项”后继续签核。

退出门：基线命令、输入 SHA/参数和 artifact hash 完整；资源占比可复核；所有
进入后续任务的测试均为绿。

### FP-P1：单在途 transaction 与 core 握手

在不改变算术 raw-bit 结果的前提下增加 clocked wrapper，把现有组合 scalar/NEON
结果或 FDIV 完成转换为一次 request/一次 held response；core 增加 owner/issued
状态，把 `ex_busy` 泛化为 FP transaction wait。

必须验证：单次 issue、ID/EX 保持、EX/MEM backpressure、response hold、reset、
所有 kill 点、FPCR snapshot、FPEN trap 不启动、FCMP NZCV 和 FP→GPR 写回。该阶段
允许资源暂时无改善，但不允许功能或提交序列变化。

退出门：新 transaction 定向测试、现有 P7-1/3/4/5 L0–L2 和 commit
backpressure 全绿；legacy 与 transaction 路径的 active-payload commit digest
一致。

### FP-P2：单 lane 共享与 NEON 分时

在已经稳定的 transaction 接口内，用一个 lane engine 加 result/flags accumulator
替换 4-lane `lcvex_neon_fp` 和 core 独立 scalar 复制。scalar 与 vector 共享同一
执行资源，NEON 整数/访存路径不变。

退出门：所有 arrangement、lane 顺序、2S/4H 高位清零、FMA operand C、转换符号
扩展、FCMEQ mask 和 FPSR OR 的 unit/lockstep 测试全绿；standalone 与 full-top
synthesis 证明发布配置只保留一个 lane engine，并给出真实面积差值。

### FP-P3：迭代重构与公共路径收敛

先把 FSQRT/FDIV 变为可暂停、可 kill 的迭代状态机，再根据综合 hierarchy 收敛
共享 classify/round/pack。首轮不预判关键路径、也不为追求“看起来像流水线”而
增加寄存器；FP-P5 取得第一份 fitter/STA 报告后，如有时序红项，再登记
FP-P3T。FP-P3T 默认按 `docs/MULTI_AGENT_WORKFLOW.md` 的 Timing Batch 执行：把
top-N 按共享锥/端点族聚类，从中选择 2–3 个独立 cone lane 并行定向切级，先汇入
临时 batch candidate，再在合并 SHA 统一执行一次 FP-P4/P5。若 top-N 都属于同一
共享锥，则只开一个 lane，不机械批量加寄存器。

退出门：每个 op/format 的 request-to-response latency 表固定并被测试检查；特殊值
和所有四种 RMode raw-bit 不回归；每个状态都覆盖 reset/kill/response backpressure；
综合报告没有重新复制迭代器或 round/pack。

### FP-P4：功能、性能与 engine-count 决策

在同一冻结 SHA 上执行 §6 矩阵；对一 lane 的实际周期与 slot/operation 模型做核对。
可额外综合二 lane 变体，但默认配置保持一 lane，直到满足 §7 的晋级条件。

退出门：功能门全绿；无 workload timeout/摘要差异；一 lane 的完整数据及二 lane
探索版的 synthesis 面积、DSP、周期和 busy 分解齐全，形成 keep-1 或“二 lane
值得进入 FP-P6 physical implementation”的决策。此阶段不拿 synthesis 估计替代 STA。

### FP-P5：A10 physical implementation 与发布候选

只在 batch candidate 的联合 L0–L2 全绿、并以精确 candidate SHA 晋级长期 feature
分支后，按远端 Quartus 重型槽串行执行；若晋级改变 SHA，必须在新 SHA 重跑联合
L0–L2：

1. full-FP synthesis；
2. fitter；
3. signoff STA；
4. 通过后才进入 assembler/SOF 与既有 Gate F-BOARD 流程。

每一步都绑定相同 source/QSF/SDC/IP/参数；不能用历史 no-FP 或其它 cache geometry
的绿色报告替代。失败时保留报告和峰值资源，不在 probe 中打未回仓补丁后宣称通过。
每轮 STA 同时产出下一批所需的 top-N 聚类输入，并逐项核对本批各旧 cone 是否离开
top-N。远端 FP-P5 运行期间允许准备下一批只读分析/原型，但新报告返回前不得合入
下一 candidate；所有 speculative 原型必须按最新路径重新排序或丢弃。

### FP-P6：条件式吞吐优化

只有同时满足以下条件才登记：一 lane 已 fit/STA；L0–L3 全绿；性能计数证明目标
workload 的 `fp_busy_cycles` 是主要瓶颈；二 lane或更小 initiation interval 的收益
超过额外面积/时序成本；架构评审确认不需要年轻非 FP 绕过。

允许方向是“按序 issue、按序完成的内部 FP pipeline”。若方案需要年轻整数/访存
先执行或 variable-latency 结果乱序返回，必须另立通用顺序退休结构任务并重新审核，
不得作为本计划的自然扩项。

## 6. 验证矩阵

### 6.1 L0/L1：模块与 core 定向

现有 raw-bit 向量继续复用，但 testbench 必须从组合采样改为真实 clocked handshake，
不能在固定 `#1` 后直接读取多周期结果。

| 类别 | 必测内容 |
| --- | --- |
| handshake | req ready/accept、busy 重复 valid、response hold、ready 同拍、连续 transaction |
| reset/kill | IDLE、每个运算 state、最后 slot、response pending、commit backpressure 各点注入 |
| lane | 2S/4S/2D/4H/8H lane 顺序、slot index 边界、Q=0 高位清零、目的寄存器原子更新 |
| 相关 | FP→FP、NEON FP→FP、FP load-use、FMA 读旧 Vd、FCMP→条件指令、FP→GPR |
| 控制 | FPCR MSR drain/snapshot、FPSR MSR、FPEN 四态 trap、系统指令/异常/IRQ 等待边界 |
| 数值 | normal/subnormal/zero/Inf/QNaN/SNaN、DN/FZ/FZ16/AHP、四 RMode、sticky flags |
| 提交 | `commit_ready=0`、无提前 V/FPSR、无重复提交、kill 后无 effect、每周期至多一条 |

现有回归入口至少包括：

```sh
make compile
make sim-sv-fp-scalar
make sim-cocotb-fp-scalar
make sim-sv-p7-3-neon-fp
make sim-cocotb-p7-3-neon-fp
make sim-sv-p7-4-fma-convert
make sim-cocotb-p7-4-fma-convert
make sim-sv-p7-5-fp16-sqrt-minmax-round
make sim-cocotb-p7-5-fp16-sqrt-minmax-round
make sim-sv-backpressure
make sim-cocotb-backpressure
```

实现任务应新增独立的 `fp_exec` SV 与 Cocotb 入口，并让 Verilator、Cocotb 和
SystemVerilog testbench 都能独立复现 transaction 失败。

### 6.2 L2：A76 required 严格锁步

- P7-1 main/edge/rounding/sequence；
- P7-3 NEON FP；
- P7-4 main/edge/rounding/sequence；
- P7-5 main/edge/rounding/sequence；
- P7-0 FPEN/FPCR/FPSR/restore/checkpoint，以及 P7-2 NEON 整数/访存兼容回归；
- 新增长 latency、每个 slot 边界、kill 后下一条、FPCR/FPSR 紧邻、随机
  `commit_ready` 的定向镜像。

锁步只比较架构提交，不把 QEMU before-instruction callback 当作退休 hook。任何
失败必须保存 instruction encoding/disassembly、执行前状态、RTL/QEMU state、
latency/op/slot、最近提交记录和 fail-fp artifact。

### 6.3 L3 与性能

- 默认 `FETCH_FIFO_ENABLE=1` 的完整 Gate D；
- 显式 `FETCH_FIFO_ENABLE=0` 的受影响 L0–L2 兼容子集；
- Gate F-ISA 的 P7 raw-bit/required/checkpoint 套餐；
- `A64_FP_SIMD=0` 的 compile/no-FP smoke，证明 generate-off 不受影响，但不把它
  当 full-FP 验收；
- 当前 SHA 的 `fp_scalar`、`fp_fp16`、`neon_vect`，以及新增纯计算依赖链/独立链。

性能报告必须同时给出 retired、cycles/IPC、commit/memory digest、FP issue/busy/
response-wait、op/format 次数和 slot 数。Verilator cycle 只用于前后对比，不是
A10 Fmax/STA 证据。

### 6.4 FPGA

按相同 source/QSF/SDC/IP/参数保存：

- scalar/NEON FP standalone hierarchy synthesis；
- no-FP、legacy full-FP、shared-1-lane、可选 shared-2-lane full-top synthesis；
- 通过资源门后的 fitter utilization/congestion；
- signoff setup/hold slack、每个时钟 Fmax 与 top-N critical paths；
- wall time、Peak PM/WS/VM、工具版本、报告 SHA-256。

## 7. 量化优化门

以下数值是**后续任务的计划门槛**，不是当前已通过结果。

| 门 | 通过条件 | 失败处理 |
| --- | --- | --- |
| FP-O0 基线可信 | 同 SHA 功能基线全绿；资源与 cycle 输入可复核；无“允许红项” | 先修基线，不启动重构 |
| FP-O1 transaction 正确 | request/response/kill/backpressure SVA 与 L0–L2 全绿；commit digest 相同 | 保留 legacy 默认，修协议 |
| FP-O2 结构共享生效 | hierarchy 中发布配置只有目标 lane engine 数；NEON 不再拥有 4 份完整 scalar | 不以源码“看似共享”代替综合证据 |
| FP-O3 synthesis 资源 | hard gate：ALM estimate ≤ 90%（384,480），且其它硬资源均 ≤ 90%；优化目标：ALM ≤ 80%（341,760） | 超过 hard gate 不进入昂贵 fitter；继续共享/迭代 |
| FP-O4 physical fit | fitter exit 0、无资源超限；所有约束时钟 setup/hold slack ≥ 0 | 按 congestion/critical path 迭代，不生成发布 SOF |
| FP-O5 功能发布 | 默认 F1a Gate D、Gate F-ISA、P7 checkpoint/raw-bit 全绿 | 任何红项阻断晋级 |
| FP-O6 性能可解释 | 无 timeout/摘要差异；实际 latency 符合已登记 op×slot 模型；退化和收益能由 busy/slot 解释 | 不隐瞒退化；调整 engine count 或保留一 lane |

二 lane只有在 shared-1-lane 已通过 FP-O4，并且二 lane candidate 自身仍满足
FP-O3 的 **80% 优化目标**、完成 fitter 且 signoff slack 非负，同时对选定
FP/NEON workload 有稳定可复现收益时才能成为默认。否则一 lane保持发布基线。

## 8. 风险、缓解与回退

| 风险 | 早期信号 | 缓解/回退 |
| --- | --- | --- |
| 资源主因判断错误 | hierarchy 显示其它模块或宽公共函数占主导 | FP-P0 先分解；按报告调整，不引用无证据的 83% |
| 共享后仍不可 fit | shared-1-lane ALM > 90% | 迭代 FSQRT/FDIV、收敛公共 round/pack；不直接砍 ISA 或关闭 FP |
| 多周期握手死锁/重发 | req count≠rsp count、ID/EX token 重复、WB 停止 | 单 owner 状态机 + SVA；保留 legacy compile-time 路径用于 bisect |
| kill 后幽灵结果 | 异常/restore 后出现旧 response 或 V effect | kill 清 owner/accumulator/rsp_valid；每个 state 定向注入 |
| FPSR 顺序错误 | back-to-back sticky 丢位或提前可见 | engine 只给本指令 flags；`fpsr_state | flags` 仍在 commit |
| FPCR 竞争 | MSR 后首条 FP 用旧/新值不确定 | request 锁存 snapshot；复用 system-commit drain，并做紧邻定向 |
| lane/高位语义错误 | 2S/4H 高位、H slot 或 FMA Vd 错 | slot 映射表 + 每 lane 唯一 pattern + raw-bit lockstep |
| 迭代特殊值回归 | NaN/subnormal/RMode 边界失败 | 先 classify，有限值才进入迭代；复用现有 golden vectors |
| 流水寄存器面积反增 | ALM/regs 增长但 slack无收益 | 只按 post-fit top-N 路径切级；逐级 PPA，失败回退该级 |
| 向量性能下降过大 | `neon_vect`/纯计算 busy 明显高于 slot 模型 | 检查控制开销；满足二 lane晋级门再启用，不绕过顺序语义 |
| 既有 P7-2 红项污染结论 | 无关 decode failure 混入回归 | 作为 FP-P0 blocker 单独修复，不跳过、不改参考结果 |

迁移期可以保留一个综合期常量选择 legacy/shared 实现，便于同 SHA A/B 与快速
回退。shared 路径完成 FP-O0～O5 并成为默认后，应另任务删除 legacy 大逻辑；不能
长期让两个实现同时进入发布 netlist。

## 9. 协作、写集与证据

- `rtl/lcvex_core.sv` 是性能 F1/F3/F9 与异常/内存路径的共享热点。FP-P1 进入 core
  写集后，必须与其它 core 修改串行；FP engine 内部任务可在接口冻结后与只读
  PPA/测试准备并行。
- 每个写任务使用唯一 topic branch 和 direct sibling worktree；不得在其它任务
  worktree 运行生成器或测试。
- FP-P3T timing batch 可在一个父任务下并行 2–3 个 cone lane。各 lane 从同一冻结
  base 分支，只在精确 `write_regions` 内修改；先汇入独立 batch candidate，联合
  L0–L2 全绿后才进入长期 feature 分支。公共状态/接口和同一组合锥不并行拆分。
- 本计划默认不修改 QEMU fork；若 RTL commit ABI 不变，QEMU 只作为既有 oracle。
  任何协议扩展都必须另开任务并保持 `PRE/COMMIT/FP_COMMIT/seq` 一一对应。
- Verilator 重型构建、QEMU 锁步、Quartus 和 Gate D 分别服从资源队列；本地 heavy
  必须先取得共享 `local` 锁，远端 Quartus 必须取得共享 `gamepc` 锁。持有本机
  独占锁后不强制 16 GiB cgroup 上限，实际准入、并行度和可选 cgroup 按资源快照
  决定并写入 evidence。输入/产物隔离时，本地与远端单路任务可以重叠，但同一
  资源锁内仍不并发。
- evidence 至少记录 source/merge SHA、工具版本、参数、seed、命令、退出码、
  latency 表、资源/Fmax、峰值资源与 artifact hash。完整日志、波形和 Quartus
  数据库放仓库外，不写系统 `/tmp`、不提交 Git。

## 10. 立即后续动作

1. 登记 FP-P0，只读收集 T-010 hierarchy 报告并在当前冻结 SHA 复核 P7 基线；
   同时把已知 P7-2 decode overlap 作为独立 blocker 闭合。
2. 产出 `docs/FP_NEON_PIPELINE_BASELINE.md`：同 SHA 资源分解、op/format latency、
   workload cycle 和 FP busy 计数。
3. 登记 FP-P1，冻结 transaction payload、reset/kill/hold SVA 和 core 单 owner
   状态机；先保持 legacy 数值实现，确认提交序列不变。
4. FP-P1 全绿后登记 FP-P2，把 scalar/vector 收敛为一个 lane engine 与 slot
   sequencer，先取得 shared-1-lane synthesis 数据。
5. 按 FP-P3 迭代 FSQRT/FDIV并形成第一个满足 FP-O3 的 candidate；随后才排队
   fitter/STA。
6. 只有 FP-P5 完成后，依据一/二 lane PPA 和 workload 数据决定是否启动 FP-P6；
   不预先承诺 scoreboard、非阻塞绕过或多在途。
