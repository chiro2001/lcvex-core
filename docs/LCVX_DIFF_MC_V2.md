# LCVX-DIFF-MC-v2 多核差分协议可行性

- 任务：T-20260829-077（D0，LCVX-DIFF-MC-v2 可行性）
- 状态：review
- 日期：2026-08-29
- 基线：`base=3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2`
- 分支：`feature/T-20260829-077-d0-mc-diff-feasibility`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-077`
- 关联方案：`docs/T-20260828-071-073-parallel-lines-plan-v2.md` 第 8.2 节 D0、第 8.3 节
- 关联 ADR：`docs/decisions/ADR-20260829-005-v82-profile-parallel-lines.md`

## 1. 目标

把现有单 vCPU/单核 `LCVX-DIFF-v1` 差分协议扩展为多核可审计的
`LCVX-DIFF-MC-v2`。本任务只做可行性、协议字段和 fallback 设计，不修改共享
QEMU fork、不修改共享 commit/checkpoint/plugin 热点代码。

### 1.1 验收问题

1. v2 envelope 的 `version/core_id/global_seq/vcpu_seq/event_kind/commit`
   是否定义清楚，v1 单核数据是否仍可被 v1 工具解析。
2. `PRE/GO/COMMIT/ACK/ASYNC/STOP` 的事件边界是否明确，是否错误地把
   before-instruction callback 当作通用 after-retirement hook。
3. QEMU 11.1.0 多 vCPU/插件回调能力如何：能否区分核、能否拿到每核预期提交、
   是否只有 before 回调、能否做确定性 round-robin/token scheduler。
4. 两核最小可重放序列是否存在；否则给出明确 fallback。
5. 多核 checkpoint 最小扩展是否覆盖每核 GPR/PSTATE/system/timer、L1、
   目录、GIC/IPI/event、全局调度 token。

## 2. 结论先行

| 问题 | 结论 |
| --- | --- |
| v1 兼容 | v1 线格式、消息类型、trace/checkpoint 旧链完全不变；v2 用新消息类型 + payload 内 envelope 扩展。 |
| 能区分核 | 能。所有 vCPU 相关插件回调都带 `vcpu_index`，`qemu_info_t` 提供 `smp_vcpus/max_vcpus`。 |
| 能拿到真正的逐核退休回调 | **不能**。官方插件 API 没有通用 after-instruction/retirement 回调；普通指令只能靠“同一 vCPU 的下一条指令前回调”或 idle/async 边界合成 COMMIT。 |
| 每核预期提交 | 部分可行。每核可以维护 per-core pending 和 per-core 状态，但“退休”是观测推导，不是 QEMU 给出的精确事件。 |
| 确定性 round-robin/token | 当前项目使用的 `thread=single` + icount **不能**在插件层做到逐指令 token 轮转；`thread=multi`（MTTCG）在原理上可通过 per-vCPU 插件阻塞做 token scheduler，但与 icount 互斥，且仍没有真正 after-retirement API。 |
| 两核严格逐指令锁步 | 不建议在第一版声明为“已支持多核 strict lockstep”。推荐先做 v2 事件流 + reference-model/litmus fallback。 |
| 本任务交付 | 协议设计、能力矩阵、两核标准序列、fallback、checkpoint 扩展、阻塞清单。 |

## 3. v1 冻结与 v2 envelope

### 3.1 v1 不变的规则

以下内容在 v2 中**不得改动**：

- `LCVEX_MSG_MAGIC == 0x5446444c`（'LDFT'）不变。
- `lcvex_msg_header` 的 24B 布局不变；`LCVEX_MSG_VERSION` 仍为 1，作为
  LCVEX 传输层的稳定版本。
- 既有消息类型 1..18 的 payload 长度、字段顺序、字节序、对齐不变：
  `HELLO/CONFIG/INIT/PRE/GO/COMMIT/ACK/DISCON/STOP/EXIT/CKPT_REQ/`
  `CKPT_READY/ASYNC/WAIT/WAIT_RESUME/FP_INIT/FP_COMMIT/P7_REJECT`。
- v1 trace 头 `# lcvex-qemu-trace v1`、v1 `commit` 行字段、既有
  `manifest.tsv` 列、v1/v2/v3 系统 sidecar、timer/GIC/MMIO/FP sidecar
  的解析规则继续保留。

因此，旧 v1 数据（trace、socket 流、checkpoint 链）仍可被现有 v1 工具
解析。v2 不是去改写 v1 字段，而是在 v1 传输头之后增加独立的新消息类型。

### 3.2 新增 v2 能力位

```c
/* 在现有 LCVEX_CFG_CAP_FP_NEON (0x80000000) 之外新增 */
#define LCVEX_CFG_CAP_MC_V2   UINT32_C(0x40000000)
```

`HELLO.api_version` 在 v2 握手时至少为 2；`CONFIG.state_mask` 必须带
`LCVEX_CFG_CAP_MC_V2` 才允许 v2 多核消息。

### 3.3 v2 envelope 结构

```c
enum lcvex_mc_event_kind {
    LCVEX_MC_EV_INIT        = 1,
    LCVEX_MC_EV_PRE         = 2,
    LCVEX_MC_EV_GO          = 3,
    LCVEX_MC_EV_COMMIT      = 4,
    LCVEX_MC_EV_ACK         = 5,
    LCVEX_MC_EV_ASYNC       = 6,
    LCVEX_MC_EV_WAIT        = 7,
    LCVEX_MC_EV_WAIT_RESUME = 8,
    LCVEX_MC_EV_STOP        = 9,
    LCVEX_MC_EV_DISCON      = 10,
    LCVEX_MC_EV_EXIT        = 11,
};

#pragma pack(push, 1)
struct lcvex_mc_envelope {
    uint32_t version;      /* 2：LCVX-DIFF-MC-v2 */
    uint32_t core_id;      /* QEMU vcpu_index / RTL core_id */
    uint32_t event_kind;   /* lcvex_mc_event_kind */
    uint32_t flags;        /* 保留，必须为 0 */
    uint64_t global_seq;   /* 协调器定义的全序事件号 */
    uint64_t vcpu_seq;     /* 本核架构指令/退休序号 */
};
#pragma pack(pop)
```

- `version`：v2 envelope 版本，固定为 2。
- `core_id`：逻辑核编号，与 QEMU `vcpu_index` 和 RTL `core_id` 一致。
- `global_seq`：协调器接受的全局单调事件号。它不是宿主线程执行顺序，而是
  测试/回放工具定义的确定性全序。
- `vcpu_seq`：每个 core 独立、从 0 开始的架构指令序号。
- `event_kind`：区分事件类型，避免只靠消息类型猜测语义。
- `commit`：v2 的 COMMIT/ASYNC 载荷中继续嵌入 v1 的 `struct lcvex_commit`
  （PC/next_pc/GPR/NZCV/stores/exc/monitor 等），不另造一套提交字段。

### 3.4 v2 新消息类型

为不与 v1 消息类型冲突，新类型从 32 开始：

| 类型 | 名称 | 方向 | 载荷 |
| --- | --- | --- | --- |
| 32 | `LCVEX_MSG_MC_INIT` | QEMU→Host | `mc_envelope + lcvex_state` |
| 33 | `LCVEX_MSG_MC_PRE` | QEMU→Host | `mc_envelope + lcvex_state` |
| 34 | `LCVEX_MSG_MC_GO` | Host→QEMU | `mc_envelope` |
| 35 | `LCVEX_MSG_MC_COMMIT` | QEMU→Host | `mc_envelope + lcvex_commit` |
| 36 | `LCVEX_MSG_MC_ACK` | Host→QEMU | `mc_envelope + status/error/detail` |
| 37 | `LCVEX_MSG_MC_ASYNC` | QEMU→Host | `mc_envelope + lcvex_commit` |
| 38 | `LCVEX_MSG_MC_WAIT` | QEMU→Host | `mc_envelope` |
| 39 | `LCVEX_MSG_MC_WAIT_RESUME` | QEMU→Host | `mc_envelope + lcvex_wait_resume` |
| 40 | `LCVEX_MSG_MC_STOP` | Host→QEMU | `mc_envelope + reason` |
| 41 | `LCVEX_MSG_MC_DISCON` | QEMU→Host | `mc_envelope + lcvex_discon` |
| 42 | `LCVEX_MSG_MC_EXIT` | QEMU→Host | `mc_envelope + lcvex_exit` |

`lcvex_mc_commit` 可定义为：

```c
struct lcvex_mc_commit {
    struct lcvex_mc_envelope env;
    struct lcvex_commit       commit;   /* 与 v1 完全相同 */
};
```

这样 v2 解析器把 `commit` 字段交给现有 `check_commit`/比较逻辑复用即可。

### 3.5 v1/v2 解析兼容规则

1. **v1 parser**：只认 `header.version==1` 且类型 1..18 的既有消息；遇到
   v2 新类型应明确报“未知/不兼容”，但不得误读既有 v1 数据。
2. **v2 parser**：对类型 1..18 走 v1 路径；对类型 32..42 必须校验
   `envelope.version==2`、`flags==0`、`core_id` 在合法范围、
   `global_seq` 和 `vcpu_seq` 满足单调规则。
3. **旧 trace**：v1 trace 文件不改写；新 v2 trace 使用独立头
   `# lcvex-qemu-trace v2`，字段在 v1 基础上增加
   `core_id/global_seq/vcpu_seq/event`，不要求 v1 工具解析 v2 行。
4. **旧 checkpoint**：现有 7/8/9/10/11/12/13 列 manifest 保持可读；
   v2 多核 checkpoint 使用新的 manifest 变体，见第 8 节。

## 4. 事件序列与边界

### 4.1 事件定义

| 事件 | 含义 | 是否可视为“退休” |
| --- | --- | --- |
| `PRE` | 本核即将执行第 `vcpu_seq` 条指令时的执行前状态。 | 否，这是 before-instruction。 |
| `GO` | 协调器允许该核执行该条指令。 | 否，只是调度授权。 |
| `COMMIT` | 本核第 `vcpu_seq` 条指令退休后的架构状态。 | 是（但在官方插件下是“下一条同核 before 回调推导出的退休后状态”，不是 QEMU 官方 after-retirement 回调）。 |
| `ACK` | 协调器确认该 COMMIT/ASYNC 比较结果。 | 否。 |
| `ASYNC` | 异步事件（IRQ/FIQ、WFI 唤醒等）导致的独立性退休/异常提交；`exc_code=0x40` 与 v1 对齐。 | 是，但属于特殊合成事件。 |
| `STOP` | 测试或窗口终止。 | 否。 |
| `WAIT` / `WAIT_RESUME` | WFI/WFE/WFxT 真实 idle 进入/恢复及虚拟计数。 | 不是架构指令退休；用于时间同步。 |

### 4.2 每次必须遵循的边界

- **严禁**把 `qemu_plugin_register_vcpu_insn_exec_cb` 的回调当作“本条指令已经
  退休”。该回调在插件生成代码的 `PLUGIN_GEN_FROM_INSN` 处触发，是执行前。
- 普通非异常指令的 v1 COMMIT 之所以可行，是因为“下一条同核指令前回调”能看到
  上一条已经退休后的 `pc/GPR/sp/nzcv`。多核 v2 必须为每个 core 维护独立 pending，
  不能沿用当前插件全局 `last_pc/last_insn/stores`。
- 若该核在退休后进入 WFI/WFE、CPU off 或直接退出而没有下一条指令回调，普通
  COMMIT 无法自然产生；必须用 `WAIT`、`ASYNC`、`DISCON`/`EXIT` 路径补足，并明确
  标记该窗口的边界。

### 4.3 单核路径（v1）与多核路径（v2）差异

| 状态 | v1（单核） | v2（多核） |
| --- | --- | --- |
| 全局 pending | 1 个 | N 个，按 `core_id` 索引 |
| 指令序列 | 单个 `msg_seq` | `vcpu_seq` 每核独立；`global_seq` 全序 |
| 寄存器句柄 | 全局句柄 | 可继续用架构级句柄，但读取必须发生在对应 vCPU 回调上下文 |
| store 列表 | 全局 | 每核独立 |
| 监视器 | 全局 | 每核独立（共享内存独占语义由参考模型/目录管） |
| WAIT/IRQ | 单核 | 每核独立 |
| STOP | 全局 | 可全局或按核；最终以协调器发 `MC_STOP` 结束 |

## 5. QEMU 11.1.0 多 vCPU/插件能力 probe

### 5.1 版本与审计方法

- QEMU release：`QEMU_VERSION=11.1.0`，上游 commit
  `84f07211cc5b4fc6a371559bf8a5de4fb068e648`，release 2026-08-11。
- 本地 fork 记录：`QEMU_FORK_BRANCH=lcvex-step-hook`，
  `QEMU_FORK_COMMIT=ccd819d`；已导出 patch 见 `qemu/patches/`。
- 本 D0 为**只读源码审计**，不运行共享 QEMU、不写共享 socket/checkpoint，
  不改共享 fork。审计路径：
  - `include/plugins/qemu-plugin.h`
  - `plugins/api.c`、`plugins/core.c`、`plugins/system.c`
  - `accel/tcg/plugin-gen.c`
  - `accel/tcg/tcg-accel-ops-rr.c`、`accel/tcg/tcg-all.c`
  - `target/arm/tcg/lcvex-difftest.c`、`include/exec/lcvex-difftest.h`
  - 本项目 `qemu/plugins/lcvex_difftest.c`、`qemu/plugins/lcvex_protocol.h`

### 5.2 能力矩阵

| 能力 | 结论 | 证据/说明 |
| --- | --- | --- |
| 插件能否区分核 | **能** | `vcpu_insn_exec/vcpu_mem/vcpu_discon/vcpu_idle/vcpu_resume/vcpu_init` 回调均携带 `vcpu_index`；`plugins/core.c` 从 `cpu->cpu_index` 传入。 |
| 能否知道 vCPU 数量 | **能** | `qemu_info_t.system.smp_vcpus` / `max_vcpus`（`plugins/system.c`）；运行期 `qemu_plugin_num_vcpus()`。 |
| 是否只有 before 指令回调 | **是（通用指令级）** | `qemu_plugin_register_vcpu_insn_exec_cb` 在 `PLUGIN_GEN_FROM_INSN` 注入，见 `accel/tcg/plugin-gen.c`。公开 API 没有 after-instruction 用户回调；`PLUGIN_GEN_AFTER_INSN` 仅内部关闭内存 helper。 |
| 访存回调时机 | 成功访问后 | `qemu_plugin_register_vcpu_mem_cb` 在内存操作成功上报；faulting access 不产生成功回调。 |
| 能否拿到每核“预期提交” | **部分** | 可以每核维护 pending，在下一条同核 before 回调形成后状态；但这不是精确退休事件，且在 halt/exit 无下一条回调时需要 WAIT/ASYNC/EXIT 补边界。 |
| 能否直接修改架构状态/实现调度 | **不能可靠做外部调度** | 没有“请让当前 vCPU 回到调度器”的公开插件 API。`qemu_plugin_set_pc()` 会改 PC 并 `cpu_loop_exit()`，不是 token 调度原语。 |
| 单线程 RR 是否可逐指令轮转 | **否** | `thread=single` 是所有 vCPU 共用一个 host thread（`tcg-accel-ops-rr.c`）。插件在回调中阻塞会卡住整个 QEMU，协调器不能借此切换到另一个 vCPU。 |
| MTTCG 是否可做 token scheduler | **原理可行** | `thread=multi` 给每个 vCPU 一个 host thread；每核插件在 PRE/COMMIT 处阻塞，协调器可逐个发 `MC_GO` 形成确定性 token 顺序。但 MTTCG 与 `-icount` 互斥（`tcg-all.c`），虚拟时间确定性需要额外处理。 |
| 是否有官方逐核 retirement hook | **没有** | QEMU 官方 TCG plugin 只提供 before/after-success-mem/discon/idle 等；项目 fork 的 step hook 只补了异常/IRQ note、单指令 TB、timer sidecar，不是通用退休回调。 |

### 5.3 源码关键点

- `plugins/core.c`：所有 vCPU udata 回调以 `cpu->cpu_index` 作为第一个参数。
- `accel/tcg/plugin-gen.c`：
  - `PLUGIN_GEN_FROM_INSN` 在指令开始时注入 insn-exec 回调；
  - `PLUGIN_GEN_AFTER_INSN` 只用于 `gen_disable_mem_helper()`，没有注册给
    plugin 用户。
- `accel/tcg/tcg-accel-ops-rr.c`：
  - 单线程 RR 用一个共享 `ALL CPUs/TCG` 线程；
  - 多 vCPU 时有 kick timer，但不是逐指令可编程轮转；
  - `-icount` 下按 `icount_percpu_budget` 分配预算，不能保证每条指令都换核。
- `accel/tcg/tcg-all.c`：
  - `thread=multi` 时每 vCPU 一个线程；
  - `icount_enabled()` 时 MTTCG 被禁用。
- 本项目 `qemu/plugins/lcvex_difftest.c`：
  - 当前 `hello.vcpu_count=1`、`vcpu_init` 只保存一组寄存器句柄、全局
    `have_pending`、全局 `stores`。要支持 v2 必须改成 per-core 数组/结构。

### 5.4 关于“确定性 round-robin/token scheduler”的可行性判定

1. **完全不改 QEMU、使用 stock plugin + `thread=single`**：
   无法做逐指令 token。原因：插件阻塞发生在唯一 vCPU 线程内，阻塞一个核就
   阻塞所有核；且没有插件 API 在 GO/ACK 后强制当前 vCPU 让出。
2. **不改 QEMU fork，改用 stock `thread=multi`（MTTCG）+ per-vCPU 插件**：
   可以在原理上由协调器通过 `MC_GO` 发放 token，实现确定性的逐核指令调度。
   代价：
   - 不能使用 `-icount`，因此 guest 时间、timer、IRQ 的“虚拟时间确定”需要
     额外由参考模型/checkpoint/事件注入来维护；
   - 需要 per-core 插件状态与 socket 并发收发，库内共享状态必须加锁或按核隔离；
   - 仍不能得到真正的 after-retirement 回调，只能得到 before/next-before 推导，
     与 v1 相同。
3. **需要真正精确 retirement + 可控调度的多核 strict lockstep**：
   这需要未来独立串行 QEMU fork 任务增加“每核退休回调 + 请求 vCPU 让出”的原语。
   D0 不修改共享 QEMU，因此把这列为 blocker，不在本任务宣称已具备。

## 6. 两核最小可重放序列

### 6.1 说明

下面给出的是 v2 协议的**规范序列（canonical sequence）**，不是已经跑通的端到端
实现结果。它定义了“如果未来实现 v2 插件/协调器，应产生/接受的顺序”；若当前
stock 单线程 QEMU 不能做到第 5 节的逐核 token，则该序列只能由 MTTCG token
参考实现或 reference-model 回放产生，不能宣称已被 QEMU 原生逐核退休证明。

### 6.2 序列

假设两核：
- core 0 在 `0x44000000` 执行 `movz x0, #1`；
- core 1 在 `0x44000100` 执行 `movz x1, #2`；
- 之后各自进入暂停，core 0 由 IPI 唤醒并触发 `ASYNC`。

```
# v2 handshake
HELLO       api_version=2 vcpu_count=2 arch=aarch64
CONFIG      vcpu_count=2 state_mask=MC_V2|... max_insns=...
MC_INIT     core=0 g=0 v=0 pc=0x44000000 sp=0 nzcv=4 ...
MC_INIT     core=1 g=1 v=0 pc=0x44000100 sp=0 nzcv=4 ...

# core 0 第一条
MC_PRE      core=0 g=2 v=0 event=PRE  pc=0x44000000 insn=0xd2800020
MC_GO       core=0 g=3 event=GO
MC_COMMIT   core=0 g=4 v=0 event=COMMIT pc=0x44000000 next=0x44000004 x0=1 ...
MC_ACK      core=0 g=5 event=ACK status=OK

# core 1 第一条
MC_PRE      core=1 g=6 v=0 event=PRE  pc=0x44000100 insn=0xd2800042
MC_GO       core=1 g=7 event=GO
MC_COMMIT   core=1 g=8 v=0 event=COMMIT pc=0x44000100 next=0x44000104 x1=2 ...
MC_ACK      core=1 g=9 event=ACK status=OK

# core 0 第二条（或继续交错，按协调器 token）
MC_PRE      core=0 g=10 v=1 ...
...
# core 0 WFI，先 WAIT 再 ASYNC 唤醒
MC_WAIT     core=0 g=N event=WAIT
MC_ASYNC    core=0 g=N+1 v=k event=ASYNC exc=0x40 next=irq_vector ...
MC_ACK      core=0 g=N+2 event=ACK status=OK

# 结束
MC_STOP     g=M event=STOP reason=max_insns
```

### 6.3 可重放条件

- 每条消息都有唯一 `global_seq`，必须严格递增。
- 每个 core 的 `vcpu_seq` 严格递增；`COMMIT`/`ASYNC` 的 `vcpu_seq` 与该核
  上一事件匹配。
- `MC_PRE` 必须在 `MC_GO` 之前；`MC_COMMIT`/`MC_ASYNC` 必须在同一 `core_id`
  且 `global_seq` 大于对应 `MC_GO` 后才能出现；`MC_ACK` 必须回填同一
  `global_seq`。
- 参考模型按该事件流重放时，共享内存线性化点由协调器明确记录，不能依赖
  QEMU/宿主线程执行顺序。
- 如果使用 `thread=multi`，必须保证任一时刻只有一个核获得 `MC_GO`，
  否则不能称为确定性 token 序列；若未来加入非 token MTTCG 并发，应另用
  `linearization` 字段记录可观察顺序。

## 7. Fallback：reference-model + litmus 定向比较

由于 QEMU 没有通用逐核 after-retirement 回调，且单线程下无法做纯插件
token 调度，D0 推荐的第一版多核差分路径为：

### 7.1 每核 reference-model 重放

- 每个 core 的指令流用 v2 `PRE/COMMIT` 事件或 QEMU 单核 trace 分别在
  参考模型（Python/C++ 架构模型）中重放。
- 参考模型维护：
  - 每核 GPR/SP/NZCV/PSTATE/EL/PC；
  - 每核系统寄存器、timer、exclusive monitor；
  - 共享内存的软件维护的线性化点（例如 store 按 `global_seq` 顺序应用，
    对测试子集先用 SC 或选定的弱模型）。
- DUT 侧同样产生每核 commit 流，与参考模型逐事件比较；不要求 QEMU 在同一
  进程内提供逐核退休回调。

### 7.2 litmus 定向比较

- 用小型 litmus 测试覆盖：
  - message passing / store-buffering / load-buffering；
  - `LDXR/STXR`、`CAS/CASP`；
  - `DMB/DSB/ISB`；
  - 共享地址的写-写/读-读顺序。
- 每个 litmus 生成固定随机/受控交错集合；DUT 与参考模型在“允许结果集合”
  维度比较，而不是只比单条动态 trace。
- 对不满足的 allowed outcome，保存：
  - 每个核的指令/PC/寄存器；
  - 共享内存地址的读写顺序；
  - `global_seq` 线性化记录；
  - QEMU 参考模型结果和 DUT 结果。

### 7.3 确定性调度

- 裸机/无 timer 的最小多核：
  可尝试 `-accel tcg,thread=multi` + v2 per-vCPU 插件 token scheduler；
  该路径不依赖 QEMU fork 修改，但需要大量插件/协调器改造。
- 带 timer/GIC/虚拟时间的场景：
  优先使用 `thread=single` + `-icount` 得到确定性时间，再配合 reference-model
  重放，不把“并行执行顺序”当成架构顺序。
- 未来若需要真正 strict lockstep：
  由集成者另开串行 QEMU fork 任务，增加 per-vCPU retirement callback + vCPU
  让出原语，并在 v2 中增加对应事件类型。本 D0 不实现。

### 7.4 已知无法覆盖的清单（第一版 fallback）

- 无法声称“完整 ARM 内存模型已由 QEMU 逐核 strict lockstep 验证”。
- 无法覆盖 QEMU 未建模或插件不可观测的微架构乱序/弱序内部事件。
- 无法覆盖真正并发的共享内存强序/弱序结果，除非由 reference-model/litmus
  和显式线性化点验证。
- 无法覆盖跨核 MMIO/GIC IPI 的精确墙钟/虚拟时钟竞态，除非用
  checkpoint + 参考模型定向事件注入。
- 无法覆盖 vCPU 在没有下一条指令的情况下被热拔/关闭的自然退休事件，
  除非使用 fork `DISCON`/`EXIT` 或未来 retirement hook。
- 无法把“多核 lockstep 通过”写成“多核架构合规”或“Linux SMP 已验证”。

## 8. Checkpoint 最小扩展

### 8.1 原则

- 单核 checkpoint 格式、manifest 列和 sidecar magic 保持不变，旧链继续可读。
- 多核 v2 checkpoint 以**新增 per-core sidecar + 共享状态 sidecar** 为最小
  扩展，不把 `core_id` 塞进旧字段的隐含位。
- 所有新 sidecar 必须带版本、size、`core_id`（或 `core_count`）、`global_seq`，
  拒绝用缺失文件或旧版文件冒充多核完整状态。
- 建议使用独立的 `manifest.mc.json`（或 `manifest-v4.tsv`）保存 v2 链，
  不改写现有 `manifest.tsv`，避免旧工具误读额外列。

### 8.2 必须包含的状态

| 类别 | 内容 | 建议载体 |
| --- | --- | --- |
| 每核架构 | GPR、SP/SP bank、PSTATE/DAIF/EL、PC/next_pc、NZCV、ELR/SPSR、VBT/系统寄存器、exclusive monitor | `per_core/<core_id>/arch.<ver>.gz`（或扩展 `LCVXSYS` v4） |
| 每核 timer | `cntpct/cntvct` 基准、CNTP/CNTV CVAL/CTL、CNTFRQ、offset | `per_core/<core_id>/timer.<ver>.gz` |
| 每核 L1 | I/D L1 metadata（tag/state/valid/dirty）、data、victim/替换状态 | `per_core/<core_id>/l1i.*`、`l1d.*` |
| 共享 L2/目录 | line metadata、MSI/MESI 状态、dirty owner、pending probe/transaction、队列深度 | `shared/l2dir.<ver>.gz`、`shared/l2data.*` |
| GIC/IPI/event | 每核 GICC（PMR/BPR/CPU interface）、共享 GICD、SGI pending、IPI/event 位图 | `per_core/<core_id>/gic.<ver>.gz`、`shared/gicd.<ver>.gz` |
| 全局调度 token | 当前被授权的 core_id、下一 token、全局事件序、每核 vcpu_seq 水位、停发新请求标志 | `scheduler.token.<ver>.gz` 或 manifest 字段 |
| 每核 pending 协议 | 每个核未完成的 PRE/COMMIT/store 列表、WAIT 状态 | `per_core/<core_id>/proto.<ver>.gz` |
| 内存 | 共享 RAM 差分链（沿用现有 diff RAM 机制） | 现有 `*.ram.gz` |

### 8.3 恢复顺序

1. 停发新的全局/核请求（冻结 scheduler token）。
2. 恢复共享 L2/目录状态（先建立内存一致性状态）。
3. 恢复每核 L1 metadata/data（必须与目录状态一致）。
4. 恢复每核架构状态（GPR/PSTATE/system/timer/exclusive）。
5. 恢复 GIC/IPI/event 和每核 GICC。
6. 恢复全局调度 token 和每核协议 pending。
7. 从对应 `global_seq` 的下一事件恢复比较，不得静默跳到新的全局起点。

### 8.4 版本/证明

- v2 checkpoint manifest 必须记录：
  - `format_version=2`、`core_count`、`core_id` 列表；
  - 每个 sidecar 的 SHA256、`global_seq`、`vcpu_seq`；
  - parent 全局映射（沿用 `global_seq_offset = parent_global+1`）。
- 旧链没有 per-core sidecar 时，只能作为单核/历史链读取，不能作为多核恢复证据。
- 任何每核状态缺失都拒绝恢复，不能把 reset 值误当成功恢复。

## 9. 阻塞清单与下一步

### 9.1 阻塞/需决策项

| ID | 级别 | 内容 |
| --- | --- | --- |
| B1 | 高 | QEMU 官方插件无 after-retirement 回调；当前项目 fork 也未提供通用多核退休回调。 |
| B2 | 高 | 单线程 RR + stock plugin 无法做逐核 token 调度；若选 MTTCG token 路径需重写 plugin/coordinator 且不能与 icount 同用。 |
| B3 | 中 | 多核 checkpoint 需要新 sidecar/magic/version；现有工具未实现。 |
| B4 | 中 | 多核 GIC/timer/IPI 的确定性虚拟时间口径未定，需 ADR 或 litmus 子集决策。 |
| B5 | 中 | 共享内存线性化点/允许结果集合未冻结，不能宣称遵循完整 ARM memory model。 |

### 9.2 建议下一步

1. C1 双核壳层先把每核独立提交、每核 IRQ/复位、`CORE_COUNT=1` 兼容实现出来，
   同时开始 v2 Python/C++ 协议骨架（仅在独立任务内）。
2. 如果 C1 只需“每核提交可记录 + 参考模型比较”，采用第 7 节 fallback；
   不等待 QEMU 退休回调。
3. 如果需要未来真正 strict lockstep，由集成者登记一个新的共享 QEMU fork
   串行任务（per-vCPU retirement + vCPU yield 原语），D0 不修改 QEMU。
4. 多核 checkpoint 由后续 C 线 checkpoint 任务按第 8 节实现，并保持旧链只读兼容。

## 10. 本 D0 未宣称事项

- 未宣称多核 RTL 已实现。
- 未宣称 QEMU 多核逐核退休已支持。
- 未宣称多核 Linux SMP 已支持。
- 未宣称完整 ARM 内存模型已验证。
- 未修改共享 QEMU fork、共享 checkpoint/plugin/commit 热点代码。
