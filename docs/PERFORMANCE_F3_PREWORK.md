# F3 事务身份、精确顺序与实施切片预研

> 任务：`T-20260830-040`（PE-F3-PRE）
> 基线：`e3d9fa5e9f5bad4d01cb75433046926e5daac4e7`
> 状态：review（仅冻结契约和任务切片；没有修改 RTL/TB/sim，没有性能实现）
> 时间：2026-08-30，Asia/Shanghai

```text
task=T-20260830-040 state=review
base=e3d9fa5e9f5bad4d01cb75433046926e5daac4e7 head=786d96ff6fcd7c2992aa87a090d8dd0fdd3ba705
branch=feature/T-20260830-040-pe-f3-prework worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-040
sent_at=2026-08-30T15:30:28+08:00 received_at=2026-08-30T15:32:46+08:00 reported_at=2026-08-30T16:02:18+08:00
```

本文是 F3a/F3b/F3c/F3d 的实施前冻结件。它不把设计意图写成已实现功能，也不
承诺性能收益。后续实现必须从本文逐项登记 child task；任何未满足的接口门都将
使后续 child 保持 blocked。

## 0. 结论和边界

当前路径是单发射、顺序执行、单核核心，取指、数据和 PTW 共用一个单
outstanding 仲裁器。缓存即使已经把下游事务数降下来，也不能隐藏一次 miss 的
延迟；F0 的矩阵因此把 F3 定为内存密集 workload 的主要候选方向，但只对独立链、
双独立链和流式 copy 分开测量。单 pointer chase 不得包装成 MLP 收益。

本次冻结的硬边界如下：

- F3a 只加入身份、epoch、kill 和 stale-response 处理；深度仍为 1，默认关闭时
  与现路径行为等价。
- F3b 才允许最多两个不同 line 的读 miss，并且仍为按年龄顺序退休；它不是
  通用乱序执行、不是四项队列，也不是 AXI 多 ID 实现。
- F3c 只在 store fault 的精确性可以由接口证明时评估一个 entry 的 store
  buffer/forwarding。证明不了时，store buffer 只能保存“未退休请求”，不得
  提前产生架构可见写入。
- F3d 只做 F0 同口径的测量和负向对照，不修改架构语义。
- F1 和 F3 都会修改 `rtl/lcvex_core.sv`，设计可以并行，但 RTL 合入、回归和
  任何共享 core/pkg 接线必须串行。
- T-20260830-038（G5）正在做同步 cache RAM；本文不读取其 worktree，只采用任务
  记录已冻结的“同步读、单口或简单双口、有效位边界可见”约束。

## 1. 基线审计：请求从哪里来、在哪里阻塞

### 1.1 当前端到端生命周期

| 阶段 | 当前行为和阻塞点 | 源码引用 |
| --- | --- | --- |
| ID/翻译 | 数据翻译只服务当前 `ifid` 指令；`data_trans_active`、`trans_done_flag`、`dabt_pending` 以一个上下文保存结果。LSE128 跨页时还要第二次翻译，期间冻结流水。 | `rtl/lcvex_core.sv:430-482,2058-2114`；`rtl/lcvex_mmu.sv:269-456` |
| 普通取指 | 只有 `fetch_pending`、`fetch_got_data`、`fetch_translated` 一个上下文；响应到达后才缓冲 32-bit 指令。`imem_rsp_ready` 恒为 1，旧响应靠清除 pending 后不捕获来丢弃。 | `rtl/lcvex_core.sv:354-360,1570-1599,2137-2195` |
| 数据请求 | EX/MEM 中的 load/store/atomic 只在 `!dmem_req_issued && !dmem_done` 时发请求；接受后置 `dmem_req_issued`，响应被消费才清除。 | `rtl/lcvex_core.sv:1668-1729,2030-2103` |
| 核心阻塞 | `dmem_pending`、`mem_busy`、MMU walk 和 WB 背压共同进入 `stall_id/stall_if`；数据响应期间 EX/MEM、MEM/WB 以及上游保持。 | `rtl/lcvex_core.sv:1488-1560,2460-2555` |
| 仲裁 | 端口 0=PTW、1=数据、2=取指，固定 PTW>数据>取指；只有 `in_flight=0` 时接受请求，响应按锁存的 `sel_r` 路由。 | `rtl/lcvex_mem_arb.sv:1-5,33-81` |
| 延迟注入 | mode 1/2 会锁存一个请求和一个响应；响应未消费前不能接受下一请求。 | `rtl/lcvex_mem_delay.sv:1-9,50-109` |
| 地址路由 | 只锁存一个 `tgt_r`；目标从 RAM、PL011/GIC/PL061/C++ fabric 中选一个，响应保持到上游 ready。 | `rtl/lcvex_mem_router.sv:1-7,82-149` |
| RAM | 一个 `rsp_pending`；请求接受时同步读下一拍形成数据，写在请求接受拍发生；越界/跨顶在写入前预检并返回 fault，响应在 ready 前保持。 | `rtl/lcvex_mem_ram.sv:1-9,44-59,77-118` |
| 基础 L1/L2 | `S_IDLE` 之外不接上游；miss 顺序发 8 个 8B refill beat，最后一个 beat 成功才发布 valid/tag；写通或旁路仍单请求。 | `rtl/lcvex_l1_d.sv:1-16,48-119,137-249`；`rtl/lcvex_l2.sv:1-11,46-125,127-258` |
| WB L1/L2/probe | 写回、填充、probe、maintenance 共用一个状态机。接口参数已有 `SOURCE_ID_W=4`、`TRANSACTION_ID_W=8`，但下游 M1-B `mem_req_t/mem_rsp_t` 没有身份字段。脏 probe 在 8 个 PoC beat 成功前不释放 response。 | `rtl/lcvex_l1_d_wb.sv:20-92,217-259,402-549`；`rtl/lcvex_l2_wb.sv:1-12,36-107,361-438,707-869`；`docs/L1_L2_PROBE_CONTRACT.md:1-47` |
| C2 shared L2 | 目录是 I/S/M、一次一个 `state`、一次 probe；响应按 `cur_core` 路由并保存 source/transaction，但 `lcvex_cluster_top` 给所有 core 的 line 请求把两类 ID tie 为 0。 | `rtl/lcvex_l2_cluster.sv:1-14,118-158,227-242,340-450,458-650`；`rtl/lcvex_cluster_top.sv:159-170,278-335` |
| WB/COMMIT | `commit_fire=memwb_valid && !memwb_committed_r && commit_ready`；正常、DABT、取指 fault merge、ID 系统指令是互斥提交源，提交包每周期最多一条。 | `rtl/lcvex_core.sv:712-725,2657-2725,3171-3357,3673-3683`；`docs/COMMIT_PACKET.md:1-75` |

因此，当前“事务”实际上是流水线某一级的隐含状态，而不是可在各层配对的
identity。F3a 的第一目标是让这个隐含状态成为显式、可验证的身份；不能先把
`in_flight` 改成两个而不先完成配对。

### 1.2 当前可观察的路径差异

- 默认 `lcvex_soc_tb` 通过参数选择无缓存、D-L1、I-L1 和 L2；每条路径最终仍回到
  同一个 M1-B arb/router/delay/RAM，且基础 `mem_req_t` 没有 ID。
  `tb/sv/lcvex_soc_tb.sv:1-12,342-525` 显示了这些 mux 和固定的 PTW>数据>取指
  仲裁顺序。
- `lcvex_l1_coherence` 是独立的 B4 endpoint，core/PTW 客户端在 `C_IDLE` 外不能
  并行，维护请求等本地响应后才进入 L2；其 client source/transaction 会回传，
  但 L1 refill 到 L2 时仍使用零 ID。见 `rtl/lcvex_l1_coherence.sv:129-193,375-419`。
- C2 `lcvex_c2_l1_coherent` 只有一条 line-level 请求/响应状态机；`cl_req` 类型
  本身没有 source/transaction 字段。`lcvex_cluster_top` 的 `tie_cl_source` 和
  `tie_cl_transaction` 全为零，所以现有 C2 smoke 只能证明“当前 owner 的单事务
  路径”，不能证明未来不同 core 的请求身份配对。

### 1.3 现有测试给出的语义锚点（只读审阅）

- M1-B 测试覆盖 RAM 写读、响应背压保持、越界/跨顶 fault、延迟和仲裁路由：
  `tb/sv/lcvex_mem_if_tb.sv:156-319`。
- 基础 D-L1/L2 测试覆盖 refill、命中、写通、旁路、冲突替换和 fault：
  `tb/sv/lcvex_l1_d_tb.sv:85-185`、`tb/sv/lcvex_l2_tb.sv:86-190`。
- WB L1/L2 测试覆盖 ID round-trip、response hold、partial store、脏 victim、
  refill/writeback fault、重试、probe、全局 invalidate 和计数一致：
  `tb/sv/lcvex_l1_d_wb_tb.sv:116-271`、`tb/sv/lcvex_l2_wb_tb.sv:272-612`。
- B4 联合 endpoint 要求 L1 drain 先于 L2 drain，ack 在 backpressure 下保持，
  fault 不产生成功 ack：`tb/sv/lcvex_l2_l1_probe_tb.sv:90-100,230-263`。
- MMU 测试覆盖 TLB miss/hit、权限 fault、MAIR non-cacheable、取指、TLBI、
  MMIO 窗口和 PAN：`tb/sv/lcvex_mmu_tb.sv:185-291`。
- C2 synthetic/系统测试覆盖 I/S/M 转移、脏 owner 下刷、probe abort、reset 无
  stale response、LDXR/STXR 成败、DMB/DSB/ISB 与维护：
  `tb/sv/lcvex_c2_cluster_tb.sv:331-440`、
  `tb/sv/lcvex_c2_l1_msi_tb.sv:265-392`、
  `tb/sv/lcvex_c2_atomic_ok_tb.sv:225-235`、
  `tb/sv/lcvex_c2_atomic_fail_tb.sv:328-343`、
  `tb/sv/lcvex_c2_maint_barrier_tb.sv:241-258`。
- 核心 commit backpressure 测试证明 `commit_ready=0` 时普通 WB 和 ID-level
  MSR/FP state 都不能提前更新：`tb/sv/lcvex_commit_backpressure_tb.sv:255-418`。
- checkpoint sidecar 工具要求 pending manifest 不可作为恢复输入、artifact 和
  parent hash 完整校验，并以 seq 选择包含的提交窗口：
  `sim/difftest/checkpoint.py:225-447,450-529,592-720`；DUT restore 明确先复位、
  冲刷流水线，再经 sideband 注入系统/定时器/FP 状态：
  `sim/difftest/lockstep_coordinator.cc:1498-1640`、
  `rtl/lcvex_core.sv:3382-3460`。

## 2. F3a 身份、epoch、kill 和响应协议（冻结提案）

### 2.1 位宽与命名

F3a/F3b/F3c 统一采用以下位宽；不能由各 child 自行缩窄或另起一套编码。

| 字段 | 位宽 | 分配/含义 |
| --- | ---: | --- |
| `source_id` | 4 | 一个 M1-B arb 域内的发起端：`0=PTW`、`1=D`、`2=I`、`3=maintenance`，`4..15` 保留。C2 的 core index 是 tuple 的独立字段，不挤进 source。 |
| `transaction_id` | 8 | 每个 source 域的请求身份；同一 epoch、source 下，未收到终结 response 前不得复用。`0` 合法，测试必须覆盖 0 和回绕边界。 |
| `epoch` | 8 | reset/checkpoint generation；冷上电 reset 值为 0。warm core reset、checkpoint restore 各递增一次；溢出前必须停在 quarantine，不能静默回到旧 epoch。 |
| `age` | 16 | 核心提交年龄，ID/EX 接收一条指令时递增并锁存；仅用于 F3b oldest-first 和 kill 年龄比较。窗口最多 2 项，使用无符号环比较时要求 live age 距离小于 `2^15`。 |
| `beat_idx` | 3 | 64B line 的 8 个 8B beat，普通请求为 0；它是父事务的子序号，不重新分配 transaction ID。 |

建议在 `lcvex_pkg` 中把以上字段放入 `mem_req_t`，并由 `mem_rsp_t` 回显
`source_id/transaction_id/epoch/age/beat_idx`，另加 `cancelled`（或等价的
tombstone）位。F3a 不得以“只在某一个模块层级保留 ID”替代端到端字段。现有
WB/probe 的参数化 ID 可保留为兼容端口，但必须与包字段逐拍相等，不能存在两个
独立真值源。`commit_packet_t` 的已有 scalar 字段和每周期一条提交 ABI 不变；
事务 ID 是内部/缓存调试身份，不直接取代 QEMU 的 commit `seq`。

跨 core 的唯一键是
`(core_id, source_id, epoch, transaction_id)`；同一 core 内的 line/cache
endpoint 还要用 `beat_idx` 区分 refill beat。`lcvex_c2_l1_coherent` 的 line
请求必须新增等价的身份 sideband，否则不能进入 F3b。

### 2.2 kill sideband

`kill` 不是普通 response，也不改变 `mem_req_t.we`。每个有队列的边界增加一个
匹配 sideband（命名可实现为 `mem_kill_t`）：

```text
kill_valid, kill_core_id, kill_source_id, kill_transaction_id,
kill_epoch, kill_age, kill_reason
```

其中 `kill_reason` 至少区分 branch/exception、maintenance/TLBI、reset/restore
和 checkpoint。规则固定如下：

1. kill 只匹配相同 epoch 且 `age > kill_age` 的年轻项；老项不得被分支或年轻
   fault 错误清除。
2. 请求还没有被下游接受时，endpoint 可丢弃请求，但必须生成一个带原身份的
   `cancelled=1, fault=0` 终结响应；这样 allocator 能回收，不留下隐含 pending。
3. 请求已经被下游接受时，物理读不能撤回，endpoint 仍必须排空下游响应并向上游
   回传 `cancelled=1`。核心消费后只回收，不写 GPR/NZCV/SP，不产生 commit。
4. `killable=0` 的 store、Device/MMIO、atomic/exclusive 和已开始的 maintenance
   事务不能被普通 branch kill；它们只能通过完成、fault 或 reset quarantine
   结束。已写入外部可见位置的 store 绝不靠 kill 回滚。
5. epoch 不用于普通 taken-branch flush；否则会把分支之前的老数据请求误判成 stale。
   分支/异常用 `kill_age`，reset/checkpoint 才改变 epoch。F1 的取指 FIFO 也须
   采用同一 reset epoch，并以 fetch age/kill 处理错误路径。

### 2.3 分配和回收状态机

每个发起 source 的最小表项为
`FREE → ALLOCATED → ISSUED → RESPONSE_HELD → RECYCLED`，另有
`CANCEL_PENDING` 和 `QUARANTINED` 终态。具体时机：

- `ALLOCATED`：核心/endpoint 在 `req_valid && req_ready` 接受请求的时钟沿分配；
  同拍锁存 address、we、strb、cacheability、age、epoch 和所有 atomic/forwarding
  元数据。
- `ISSUED`：下游接受请求后进入；仅保留一份父 transaction context，refill 的
  `beat_idx` 每次握手更新。
- `RESPONSE_HELD`：响应 `valid=1` 但 `ready=0` 时进入；所有数据、fault、身份和
  beat 字段保持，不能因为上游背压重发或换路由。
- `RECYCLED`：且仅在匹配响应 `valid && ready`（包括 `cancelled`）后回收；不得在
  request forward、内部 cache metadata 更新或 `rsp_valid` 拉高时提前回收。
- 不匹配的 response：若 epoch 旧，作为 stale 消费并丢弃，不上报架构 fault；若
  epoch 相同但 source/transaction/age/beat 不匹配，置 `protocol_error`、停止
  接受新请求并保留诊断上下文，不能猜测归属。

F3a 单深度时每个 source 只有一项，`transaction_id` allocator 可用 8-bit
递增计数器；若下一个 ID 等于仍 active 的 ID，必须停发而不是复用。F3b 扩为
两个 MSHR 后仍由同一 allocator 分配，两个 active 项不得同 UID；同 line 合并的
多个 waiter 各自保留自己的 transaction/age，不能把年轻 waiter 的 commit 伪装
成父 MSHR 的年龄。

### 2.4 响应配对与异常处理的 SVA 要求

F3a 至少加入下列断言（名称可不同，但语义不能削弱）：

- `req_fire` 后，最终恰有一个同 UID、同 epoch、同 source 的 `rsp_fire` 或
  `cancel_fire`；不允许零次、两次或改 UID。
- `rsp_valid && !rsp_ready |=> rsp_valid && $stable(all_payload_and_id)`。
- stale epoch response 不得改变 cache valid/tag/dirty、MSHR、store buffer、
  `exmem_*`、`memwb_*` 或任何架构寄存器。
- response 的 `beat_idx` 只可属于该 parent 当前期待集合；重复 beat、越界 beat
  和同一 beat 二次写入 fill buffer 必须报协议错误。
- 同一 endpoint 在 F3a `DEPTH=1` 时 `outstanding_count <= 1`；任何 feature-off
  legacy path 保留当前 `in_flight/rsp_pending/busy` 不变量。
- 任何 `commit.valid` 都必须对应一个尚未退休的 age；`commit_ready=0` 时所有
  架构 state、store buffer retire pointer 和 monitor state 保持。

## 3. 内存类型、可并行性和序列化矩阵

下表是架构允许的最高并行度，不代表当前模块已经支持。`同线合并` 只对同一
版本、同一 cacheability/属性且无 fault 的读 miss 有效；`全局排空` 包含所有
更老 MSHR、未完成 response 和 store buffer。

| 类型/操作 | 不同 line Normal read | 同 line/同地址 | Normal store | Device/MMIO/bypass | PTW | atomic/exclusive | maintenance/barrier |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Normal cacheable load hit | 可与另一条独立读并行（受 RAM port） | 可读 cache 或已确认的老 store forwarding | 只能观察已完成且年龄更老的 store | 不可跨越 Device | 可与不别名的 PTW 并行；同 PTE line 禁止猜测 | 不跨 atomic 保留线 | 不跨 maintenance；ISB 后请求必须是新 fetch epoch |
| Normal cacheable load miss | F3b 最多 2 个 MSHR；F3a 仍 1 个 | 允许多个 waiter 合并，单 fill；partial bytes 未齐时不得返回 | 对重叠老 store 按 byte forwarding；未覆盖 bytes 等 fill | 不合并、不把 Device 数据填入 Normal line | 与单独 PTW 条件并行；PTW fault/属性不能被吞 | atomic/exclusive 保留 line，禁止合并 | DMB/DSB/ISB 前后由 age 隔离 |
| Normal cacheable store | F3a 与其它内存保持顺序；F3c 才能占 1-entry SB | 可与老同线 store 合并仅在 fault/strb 契约通过 | 不早于 commit/validated response 产生架构副作用；partial byte 按 strb | 不得进入 SB，按 Device 规则单独完成 | PTE store 与 PTW 同 line 必须序列化 | 不进入 atomic/exclusive line | DSB 等 SB drain；DMB 至少保证此前 store 顺序 |
| Device / MMIO / `bypass=1` | 不允许 | 不允许合并或 speculative read | 不允许提前写或 forwarding | 全局单项，接受后不可 kill；响应/副作用按程序顺序 | 不与 PTW 交错 | 不与 atomic 交错 | 任何 DMB/DSB/ISB 都作为全局序列点 |
| PTW | 当前一个 walker；F3b 可与不别名 Normal read 条件并行 | 不与 data request 偷合并；必须看到已提交/已 drain 的 PTE | 同 PTE line 的 store 先完成再 walk | 不与 Device 混合 | 结果只归属触发 load/store/fetch，PTW 自身不提交 | 不跨 atomic line | TLBI/maintenance 前后必须清 walk 或重启 |
| LDXR/LDAXR/STXR/STLXR、LSE | 不与别的 line 的可见写入乱序；首版按全局 atomic slot 串行 | 保留整 line；不合并、不 forwarding | STXR 条件写与 monitor 比较/清除是一个原子年龄 | Device atomic 也必须全局串行 | 不让 PTW 改变 monitor 比较值 | 读-比较-写不可拆成可见的两条；失败仍是正常提交、无 mem side effect | 维护/屏障作为外部序列点 |
| IC/DC/TLBI maintenance | 不并行 | line maintenance 独占目标 line；global op 全局排空 | 先 drain 老 store；不取消已可见写 | 不通过 Device bypass 假装完成 | TLBI 必须清除/重启 walk | 不跨 atomic | ID-level commit；DMB/DSB/ISB 不能被 MSHR 绕过 |
| DMB | 只允许老请求先于年轻请求观察；现顺序核保守地 drain 所有老 memory | 不改变数据 | 不能把老 store 排到年轻 load 后 | 与 Device 同一顺序 | PTW/页表访问属于老 memory 时不跨越 | 不跨 atomic | 在 ID 排空后提交，commit point 仍受 ready |
| DSB | 不允许任何老 memory 未完成 | 不允许 | SB 必须清空并确认 PoC 可见 | Device response 必须完成 | walk 完成或被明确 fault | atomic 完整结束 | 全局排空后 ID commit |
| ISB | 清理年轻 fetch，建立新的 fetch age/epoch；不让 data MSHR 被误杀 | 不改变 data line | 不跨越未完成 store | 不跨 MMIO | walk 需取消/重启 | 不跨 atomic | ID commit 后重新取指 |

当前 `lcvex_mmu` 将 Device/Normal-NC 输出为 `cacheable=0`，核心在 MMU 关闭时
也按 MMIO 窗口强制 bypass；PTW 请求目前 `bypass=0` 并由 arb port 0 优先，
这些行为是 F3a 的兼容基线，不能因增加 ID 而改变。

## 4. 精确异常、提交和可见性规则

### 4.1 年龄和 oldest-first

每一条进入 memory window 的指令都有 `age`；cache hit 也必须经过该年龄的
completion entry，不能在 response 到达时直接写架构状态。F3b 允许 response
乱序，但 retirement 只看最老 entry：

```text
oldest entry ready -> commit/fire -> retire/recycle
oldest entry waiting -> younger ready 只能保存，不得 commit
oldest entry fault -> 先提交该 fault；所有更年轻 entry kill/quarantine
```

commit packet 仍按 `docs/COMMIT_PACKET.md` 的一条指令一个 packet，至少含 PC、
写回、NZCV、next PC、memory effect 和 exception。MSR/ERET/异常/维护仍是 ID-level
commit，必须等更老 memory age 完成并受 `commit_ready` 门控。事务 ID/age 不替代
QEMU PRE/COMMIT 一一对应。

### 4.2 load、PTW 和取指 fault

- load response `fault=1` 归属其 age；该 load 不写 GPR/SP/NZCV，最老时通过
  DABT commit（EL/ESR/FAR 规则沿用当前 core）。更老 entry 先正常退休；更年轻
  response 即便已到，也只能保持或被 kill，不能先写回。
- PTW fault 不作为独立架构提交；它归并为触发它的 load/store 的 DABT 或 fetch
  的 IABT。PTW response 需带 parent UID/age，不能把另一个 walk 的 fault 送入
  当前指令。
- fetch fault 按当前的 `fetch_faulted/fetch_merge_wb` 语义处理：older 指令的
  写回保留，随后合并 IABT；被 flush 的错误路径 fetch 只产生 cancelled/stale
  response，不能产生 IABT commit。

### 4.3 store fault和store buffer门

当前核心注释已明确“Store 副作用=请求被接受”，而 commit packet 的 `mem_we`
在 WB 才上报（`rtl/lcvex_core.sv:1668-1670,3285-3298`）。这意味着不能把
现有提前可见写入直接当作 F3c store buffer 的精确语义。F3c 只有在以下契约全部
满足时才可打开：

1. 所有下游 RAM、L1/L2、PoC、MMIO/BFM 都保证“请求接受前已完成地址、权限、
   目标和 byte-range preflight”；返回 fault 时零字节已产生外部副作用。
2. store entry 在 `validated_no_fault` 前只能是未退休槽，不能清掉 oldest
   barrier，也不能被年轻 load 当作已提交值；若允许转发，必须逐 byte 记录。
3. store buffer 满、遇到 atomic/Device/maintenance/DSB 或不确定 fault 时，核心
   必须退回 F3a 的单 outstanding 路径，而不是丢弃或提前提交。
4. store fault 提交 DABT 时 `mem_we=0/mem2_we=0`，GPR/SP/NZCV 按指令是否已完成
   处理；部分 overlap、STP X 两个 8B effect 必须有 all-or-nothing 证明。

若任一条不能用 SVA 和 fault-injection test 证明，F3c 标记 blocked；可保留一个
“请求已分配但未退休”的槽，不得声称实现了 write buffering 性能。

### 4.4 同线合并、转发和 partial overlap

- 同 line 合并只合并同 epoch、同 Normal/cacheability、同权限结果、同方向读的
  miss。每个 waiter 仍保留自己的 age/transaction ID；fill buffer 的 byte-valid
  未覆盖请求范围前不能返回。
- 同地址 load 可以共享一个 fill，但不能共用另一个指令的 commit entry。若旧
  store 的某些字节已 validated，load 按 `strb` 每 byte 取 store；其余 byte 等
  cache/memory。多个老 store 重叠时取程序顺序中最后一个更老值。
- 不同 memory type、不同 shareability/cache attribute、权限未知、fault 中的
  line 不合并。Device/MMIO 不 forwarding、不填 cache；atomic/exclusive 和
  maintenance 不合并。
- 跨 8B、跨 64B line、跨 4 KiB 页的 partial access 不能因 MSHR 而拆成可独立退休
  的效果。LSE128 当前已有两次翻译和对齐/范围预检，F3 不得放宽；STP X 的
  `mem/mem2` 仍是一条 commit 的两个 effect。

### 4.5 atomic/exclusive

沿用当前监视器的 commit-only 语义：LDXR/LDAXR 在正常 commit 更新 monitor，
STXR/STLXR 无论成功失败都清 monitor；自身 DABT 时 monitor 不变；STXR 失败是
正常提交（状态寄存器=1、`mem_we=0`）。LSE/CAS 的读-比较-写在线性化点前
不能让另一个同线请求观察中间值。任何 MSHR/store buffer 命中 atomic line 都要
等待该 atomic 完整结束。

## 5. reset、checkpoint 和 response hold

### 5.1 reset/epoch

新增状态 reset 值和提交时机固定如下：

| 状态 | 冷 reset 值 | warm reset/checkpoint 行为 | 架构可见时机 |
| --- | --- | --- | --- |
| `epoch_r` | `8'h00` | 在接受新请求前递增；wrap 时进入 quarantine，不接受新流量 | 不属于 commit packet；作为事务域边界生效 |
| `txn_alloc_r` | `8'h00` | 保留旧计数但不能复用 active UID；restore 后从任意安全值继续 | 仅在 request fire 分配 |
| `age_r` | `16'h0000` | restore/reset 后从 0 开始；live window 不得跨 epoch | ID/EX 接收指令时递增 |
| active/kill table | invalid | reset、restore、TLBI/exception kill 后逐项 invalid/quarantine | response/cancel fire 后回收 |
| cache MSHR/fill buffer | invalid/zero | reset 清 metadata；stale data 不可由 valid=0 观察 | fill 全部成功且年龄 entry 完成后发布 |
| store buffer | empty | checkpoint 必须先 drain；reset fault 时不伪造成功 | validated 且 oldest commit 后 retire |

`rst_n=0` 期间所有 request/response valid 必须为 0。局部 core reset 不能只清
`lcvex_core` 而留下共享 cluster/arb 的旧 response：必须向所有下游 endpoint
广播 epoch bump/kill，或让它们同时进入 quarantine。旧 epoch response 到达时只
消费丢弃，绝不能改变新 core 的 `fetch_pending/dmem_req_issued`。

### 5.2 checkpoint drain/restore

当前 B4 顺序是事实基线：

```text
checkpoint_quiesce
  -> 停止 core/PTW 新请求
  -> 完成/取消年轻 memory entry，MSHR=0，store buffer=0
  -> D-L1 dirty line 全部成功写入 L2（l1_drain_done）
  -> L2 dirty line 全部成功写入 PoC（drain_ack_valid）
  -> arb/router/delay/RAM 无 in-flight，checkpoint_ack_valid
```

`lcvex_l1_coherence` 的 `CP_IDLE→CP_L2_REQ→CP_L2_WAIT→CP_ACK` 及
`lcvex_l2_l1_probe_tb` 的顺序/ack hold/fault negative test 是接口门，而不是
性能建议（`rtl/lcvex_l1_coherence.sv:313-369`；
`tb/sv/lcvex_l2_l1_probe_tb.sv:230-255`）。任意 writeback/probe/PoC fault 都
不产生成功 ack，保留可重试 metadata。

checkpoint sidecar 选择的是 inclusive committed seq；当前 `checkpoint.py` 会
拒绝 pending manifest、校验每个 artifact 的 hash/size，并按 seq 重放 RAM
delta。现有 `difftest_restore_sys_valid` 在 reset 后清空 fetch、ID/EX、EX/MEM、
MEM/WB、commit 和 PAR pending，再写入系统/定时器/monitor state。F3a 必须在同一
边界递增 epoch，并保证 restore 前的 response 全部 stale/quarantine。当前 sidecar
没有 cache/MSHR/store-buffer 内容，因此 restore 只能使用“已 drain 到 PoC + cache
metadata 清空/失效”的状态；未批准新增 cache sidecar 前，不得保留 cache 中的
脏值声称可恢复。

仓库基线不存在 `docs/CHECKPOINT_PROTOCOL.md`（`git ls-tree -r --name-only HEAD`
和文件检索均未找到）。本预研不越过允许写集创建该文件；未来 F3a task 必须在
实现前补齐/指定该权威文档，或在任务记录中显式接受本文与
`docs/L1_L2_PROBE_CONTRACT.md`、checkpoint 工具源码的组合口径。

## 6. F3a→F3d DAG、child 写集和验收门

所有 child 均使用独立 sibling worktree、一个 topic branch 和单一逻辑提交。下表
的路径是精确写集；未列出的文件不可顺手格式化或重命名。所有 F3 开关默认 0，
feature-off 必须保留当前单 outstanding 行为。

### 6.1 F3a：端到端身份（深度 1）

| child | 精确写集 | 依赖/接口门 | SVA 与 L0-L2 验收 | 默认/rollback |
| --- | --- | --- | --- | --- |
| F3a-PKG | `rtl/lcvex_pkg.sv`、`rtl/lcvex_cluster_pkg.sv`、`docs/COMMIT_PACKET.md` | 无；冻结 `source=4/txn=8/epoch=8/age=16/beat=3`、`mem_rsp` echo 和 `mem_kill` 语义；commit packet 旧字段布局不变 | L0：struct/pack 静态核对；L1：非法 UID/epoch/beat 的断言样例；不得运行 QEMU | `F3A_ENABLE=0` 时新增字段置零；若包布局破坏 legacy 编译或 wire，整 child 回退 |
| F3a-CORE | `rtl/lcvex_core.sv`、`rtl/lcvex_core_wrap.sv` | 依赖 F3a-PKG；F1 若已合入则必须从其合并 SHA 重放；分配只在 request fire，commit/monitor 只在 commit fire | L1：`lcvex_core_tb`、`lcvex_commit_backpressure_tb` 加入 reset/flush/stale response；L2：标量 lockstep 的 PRE/COMMIT、DABT/IABT、IRQ、LDXR/STXR | `F3A_ENABLE=0` 保留旧 FSM；出现一次重复/错配/提前状态更新即关闭开关并回退 |
| F3a-TRANSPORT | `rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_delay.sv`、`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_axi4_master.sv` | 依赖 F3a-PKG；AXI 仍单 outstanding、AXI ID 只 pass-through，不做多 ID；stale response 必须可消费 | L1：`tb/sv/lcvex_mem_if_tb.sv`、`tb/sv/lcvex_axi4_tb.sv` 覆盖 random delay、backpressure、非法/旧 epoch；L2：锁步 memory side effect 一一对应 | `F3A_ENABLE=0` 不改握手；response hold 或 RAM write fault 语义改变即回退 |
| F3a-CACHE-M1 | `rtl/lcvex_l1_d.sv`、`rtl/lcvex_l2.sv` | 依赖 F3a-TRANSPORT；保留 8 beat、最后 beat 才发布 metadata、bypass 不分配 | L1：`lcvex_l1_d_tb`、`lcvex_l2_tb` 加 ID/epoch/beat echo、fault retry；L2：cache 配置锁步 smoke | `F3A_ENABLE=0` 继续单阻塞；任何 refill duplicate/tag premature publish 即回退 |
| F3a-CACHE-WB-COH | `rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l2_wb.sv`、`rtl/lcvex_l1_coherence.sv`、`rtl/lcvex_l2_cluster.sv` | 依赖 F3a-CACHE-M1；probe/response ready 前 payload+ID+epoch 保持；C2 不得再 tie 全零身份，core_id 作为独立 tuple 字段 | L1：`lcvex_l1_d_wb_tb`、`lcvex_l2_wb_tb`、`lcvex_l2_l1_probe_tb`、`lcvex_c2_cluster_tb`、`lcvex_c2_l1_msi_tb`；L2：C2 atomic/barrier/maintenance/reset fault | `F3A_ENABLE=0` 保留现参数和单事务；probe abort、旧 response 或 C2 owner 错配即回退 |
| F3a-VERIFY | `tb/sv/lcvex_soc_tb.sv`、`tb/sv/lcvex_core_tb.sv`、`tb/sv/lcvex_commit_backpressure_tb.sv`、`sim/cocotb/test_lcvex_core.py`、`sim/cocotb/test_commit_backpressure.py`、`sim/cocotb/test_axi4.py` | 依赖所有实现 child；只接线/验证，不改变 reference result；F1/F3 core 共享写集继续串行 | L0/L1：静态/lint/SVA/定向 SV+Cocotb；L2：`run_lockstep_step.sh` 受影响 hard_*，覆盖 fault、reset、checkpoint restore | 开关关闭时旧测试必须逐项通过；失败保留 trace/状态窗口，禁止删除断言 |

F3a 的合并门是：在 `DEPTH=1` 下，不同延迟、ready 背压、局部 reset、branch
kill、TLBI、DABT/IABT、C2 probe abort 都能证明同一 UID 只被消费一次；未达到这
个门，F3b 和 F3c 均不得派发实现。

### 6.2 F3b：2-entry miss table/MSHR（后置）

| child | 精确写集 | 依赖/接口门 | SVA 与 L0-L2 验收 | 默认/rollback |
| --- | --- | --- | --- | --- |
| F3b-RETIRE | `rtl/lcvex_core.sv`、`rtl/lcvex_core_wrap.sv` | 依赖 F3a-VERIFY、F1 已合入的 core SHA 和 G5；增加最多 2 个 memory completion entry，仍单发射、按 age 退休 | L1：oldest-first、年轻 fault hold/kill、年龄环比较；L2：双独立链和 fault-before-young-commit lockstep | `F3B_MSHR_ENABLE=0`；任何年轻 commit、错误 DABT 年龄或 stale writeback 即回退 |
| F3b-L1D | `rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l1_d.sv` | 依赖 F3b-RETIRE；2 个不同 line fill context、同 line read waiter 合并；必须遵守 G5 单口/简单双口同步延迟，不能假设异步 data RAM | L1：不同 line 乱序 response、同地址/同 line merge、fill byte-valid、冲突 set；L2：cache hierarchy lockstep + random delay | `MSHR_DEPTH=2` 但 enable 默认 0；partial/fault metadata 不可恢复时保持 blocked |
| F3b-L2/COH | `rtl/lcvex_l2_wb.sv`、`rtl/lcvex_l2.sv`、`rtl/lcvex_l2_cluster.sv`、`rtl/lcvex_l1_coherence.sv` | 依赖 F3b-L1D；不同 line 可排队，同 line/probe/owner/maintenance 仍锁线或全局序列化；C2 目录 pending 必须按事务 tuple | L1：dirty victim、probe abort、同 line merge；L2：C2 M→S/S→M、atomic/barrier/maintenance、不同 core response reorder | 默认关闭；目录状态、probe 或 PoC fault 一次不变量失败即回退整 child |
| F3b-VERIFY | `tb/sv/lcvex_l1_d_wb_tb.sv`、`tb/sv/lcvex_l2_wb_tb.sv`、`tb/sv/lcvex_l2_l1_probe_tb.sv`、`tb/sv/lcvex_c2_cluster_tb.sv`、`sim/cocotb/test_l1_d_wb.py`、`sim/cocotb/test_l2_wb.py`、`sim/difftest/run_lockstep_step.sh`（仅参数/调用） | 依赖上述三个实现 child；测试不得只检查最终 RAM，必须检查 response order、occupancy、age 和 fault | L0/L1：BFM 乱序/背压/故障注入；L2：双独立 pointer chain、同 line partial overlap、MMU/PTW；不跑 Gate D | 默认 0；失败现场含 UID/epoch/age/beat、cache metadata、QEMU/RTL commit window |

F3b 的接口门还有一条硬条件：G5 必须公开同步读 latency、single/simple-dual
port、read-during-write（read-first/write-first/no-change）和 byte-enable 规则。
若只剩单口且没有足够的 fill/response buffer，F3b 标记 blocked，不以“两个状态
机同时跑”代替真实两个 miss。

### 6.3 F3c：1-entry store buffer/forwarding（最后评估）

| child | 精确写集 | 依赖/接口门 | SVA 与 L0-L2 验收 | 默认/rollback |
| --- | --- | --- | --- | --- |
| F3c-CONTRACT | `docs/COMMIT_PACKET.md`、`docs/L1_L2_PROBE_CONTRACT.md` | 依赖 F3b 或明确的 F3a fallback；先证明 store accept/fault all-or-nothing 和 PoC 可见点，不能先改 RTL | L0：逐 byte strb、STP X all-or-nothing、Device negative matrix；没有证明则直接 blocked | `F3C_STOREBUF_ENABLE=0`；契约缺口不许用仿真“无 fault”替代证明 |
| F3c-CORE | `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv` | 依赖 F3c-CONTRACT；只允许 1 entry；store fault 未知时保持未退休，forwarding 仅按老 age/byte valid | L1：store/load overlap、load-use、commit_ready backpressure、DABT/IRQ/flush；L2：QEMU mem effect 逐 byte 对齐 | 默认 0；任何 store side effect 在 fault 前发生、年轻 load 观察未提交值或 mem_we 错报即回退 |
| F3c-PATH | `rtl/lcvex_l1_d.sv`、`rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l2.sv`、`rtl/lcvex_l2_wb.sv`、`rtl/lcvex_mem_router.sv`、`rtl/lcvex_mem_ram.sv` | 依赖 F3c-CONTRACT；所有 cache/PoC/Device path 对 fault 具有同一 preflight 语义；不能只修 RAM | L1：fault injection 每个 byte/beat、writeback/probe abort；L2：MMIO/Device、atomic/exclusive、maintenance/DSB | 默认 0；任何层无法提供 no-side-effect-on-fault 就保持 blocked |
| F3c-VERIFY | `tb/sv/lcvex_mem_if_tb.sv`、`tb/sv/lcvex_l1_d_tb.sv`、`tb/sv/lcvex_l1_d_wb_tb.sv`、`tb/sv/lcvex_l2_wb_tb.sv`、`tb/sv/lcvex_c2_atomic_fail_tb.sv`、`sim/cocotb/test_l1_d_wb.py`、`sim/difftest/run_lockstep_step.sh`（仅测试参数） | 依赖实现 child；必须覆盖 partial overlap、同地址、store fault age、STXR 失败和 checkpoint drain | L0/L1：SVA + BFM fault；L2：hard_* store/atomic/maintenance lockstep；不把最终 memory 一致当作精确性唯一证据 | 默认 0；失败立即关闭 SB，保留 F3b/F3a 路径 |

### 6.4 F3d：F0 同口径复测

| child | 精确写集 | 依赖/验收 |
| --- | --- | --- |
| F3d-MEASURE | `scripts/run_perf_matrix.py`、`sim/microbench/perf_runner.py`、新建 `docs/PERFORMANCE_F3_RESULTS.md` | 依赖 F3a/F3b/F3c 已分别验收；对同一镜像、同一工具和 delay 0/1/2 复测 `mem_seq`、`mem_random`、`mem_ldst`、`kernel_matmul/sort/hash/crc` |
| F3d-WORKLOAD | 只允许新增/修改 `baremetal/perf/t_f3_*.c`（若确需 workload）；不改现有 P-line 期望结果 | 必须有 single dependent chain、dual independent chain、stream copy 三组；另有 same-line/partial/Device negative 对照 |
| F3d-REPORT | `docs/tasks/evidence/<新 F3d id>.json`（由 owner 创建） | 报告 cycles、retired、IPC、MSHR occupancy、隐藏周期、响应乱序、fault/rollback；单 pointer chase 仅作 latency baseline |

## 7. G5、F1 和串行集成依赖

### 7.1 G5 同步 RAM

G5 任务记录冻结的边界是：64B line 可组织成 packed 512-bit word，综合路径为
显式同步 RAM，reset 只清 valid/dirty/tag/事务状态，data 在 valid=0 时不可见；
同步读至少多一拍，单口或简单双口，不提前引入 MSHR。F3b 必须因此：

- 锁存 set/way/offset/request 后等待 RAM read response，不能用组合数组读掩盖延迟；
- 明确 refill write 与 hit read 的端口仲裁、byte-enable 和 read-during-write；
- 每个 MSHR 有独立 fill buffer/beat-valid，metadata 仍在全 line 成功后发布；
- 若单口无法在两个 miss 之间保存两个 response，就不得宣称 two-real-miss；
- G5 standalone 失败只阻塞 F3b/F4，不可为了 F3 反向削弱 G5 的 fault/probe 边界。

### 7.2 F1 取指 FIFO/early restart

F1 会修改 core 前端和 I-L1，涉及 `fetch_pending`、flush、IABT、TLBI/维护。
F3a 的 `source/transaction/epoch/age/kill` 必须成为 F1 的共同基础：

- F1 FIFO 中每个 fetch entry 带 UID、fetch age 和 reset epoch；错误路径只 kill，
  不把 IABT/fault 写入架构 commit。
- F1 的 early restart 不能改变 F3 data memory 的 oldest-first；I/D/PTW 在 arb
  中仍按已冻结的类型优先级和 backpressure 工作。
- 推荐集成顺序：F1 先合入并完成 core 回归，再从其 merge SHA 串行合入 F3a-CORE；
  若 F3a 先完成设计，必须在 F1 merge 后 rebase/重放并重新跑 core L1/L2，不能
  拼接两个 dirty core 文件。

### 7.3 其它交叉点

- MMU/PTW：F3b 的第二个 MSHR 不能让一个 walk 的 `ptw_rsp` 被另一个 age 消费；
  同 PTE line 的老 store、TLBI 和 DSB 仍是序列点。
- checkpoint：F3 queue drain 要插在 B4 的 L1 drain 之前；sidecar 只记录已提交
  状态，不能把未退休 MSHR 当成可恢复架构状态。
- QEMU/AXI：F3a 不修改 QEMU fork，不实现 AXI 多 ID；QEMU lockstep 仍一条
  PRE→DUT commit→GO→QEMU COMMIT。AXI `req_id` 只做单请求的端到端 echo，F7
  才讨论 burst/multi-ID。

## 8. 停止、阻断和回退条件

出现任意一项即停止当前 child，保留失败现场并回退开关；不得关闭断言或修改
参考结果“修绿”：

1. 同一 UID 出现零次/两次 response、response 在 ready=0 时 payload/ID 改变，
   或旧 epoch response 改变架构/cache 状态。
2. 较年轻 fault 先于老指令 commit，较年轻指令在老 fault 后写 GPR/NZCV/SP，或
   `memwb_committed_r`/MSR/ERET 被背压绕过。
3. store fault 前已有外部字节写入，STP X 只完成一半，或 forwarding 观察到
   未 validated store。
4. atomic/exclusive monitor 在指令未 commit 时更新、STXR 失败产生内存 effect，
   或同 line MSHR 与 probe/maintenance 交叠。
5. reset/checkpoint 后出现 stale response、未 drain 的 dirty line、成功 ack 与
   fault 同时出现，或恢复后 caches/MSHR 观察到 sidecar 没有的状态。
6. G5 端口/延迟/读写语义未冻结，F3b 只能依赖组合 data array，或测量只跑单链
   就把 cycle 下降写成 MLP。
7. C2 line request 仍全 tie zero、source/transaction/epoch 无法区分不同 core，
   或加入 MSHR 后 directory invariants（M owner 唯一、S 无 owner）失败。

回退操作限定为：关闭对应 `F3*_ENABLE`、保留旧单 outstanding路径、保留新增
diagnostic counter/SVA 和失败 evidence，然后由集成者重新登记 regression task。
不得在同一提交中重命名/格式化热点文件，也不得删除失败现场。

## 9. 交付检查

- [x] 当前事务生命周期、阻塞点和源码行号已列出。
- [x] ID 位宽、分配/回收、epoch、kill、乱序 response 和 oldest-first 已冻结。
- [x] Normal/Device/PTW/atomic/exclusive/maintenance/barrier 的并行/序列化矩阵已冻结。
- [x] load/store fault 年龄、年轻取消、forwarding、同线合并和 partial overlap 已冻结。
- [x] F3a-d DAG、每个 child 精确写集、依赖、SVA、L0-L2、默认关闭和 rollback 已列出。
- [x] G5 同步 RAM/F1 core 交叉依赖和串行合入门已列出。
- [x] checkpoint 协议缺失文件已明确记录，未越过允许写集补建。
- [x] 未运行构建、仿真、QEMU、生成器或 Quartus；本任务没有任何 test pass 声明。

下一步可直接登记 `F3a-PKG → F3a-CORE/TRANSPORT → F3a-CACHE-M1 →
F3a-CACHE-WB-COH → F3a-VERIFY`；F3b/F3c 继续保持后置，直到 F3a 的响应配对、
reset/checkpoint 和精确异常门全部通过。
