# F1 取指 FIFO、epoch 与 early-restart 实施前契约

> 任务：`T-20260830-039`（PE-F1-PRE）
> 基线：`e3d9fa5e9f5bad4d01cb75433046926e5daac4e7`
> 分支：`feature/T-20260830-039-pe-f1-prework`
> worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260830-039`
> 性质：只读预研和可派发契约；本文件不表示 F1 已实现，也不表示已有性能收益。

## 0. 结论和决策门

建议把 F1 拆成三个互相可验收的切片：

1. **F1a**：core 内 2-entry fetch FIFO、fetch epoch 和 stale-response quarantine；I-L1
   继续整行 refill 完成后才响应，且 core 到 I-L1 仍只允许一个在途请求。F1a 是当前
   唯一建议立即登记的实现任务。
2. **F1b**：I-L1 critical-word-first/early-restart。它必须等待 F1a 的 epoch/flush 回归
   通过，并先通过本文件 §7 的 fault/metadata 风险门；在当前接口下不能直接打开。
3. **F1c**：独立性能复测。F1a 和 F1b 的结果分开报告，使用相同 workload、镜像、工具
   和源码口径，不把静态推断写成收益。

关键阻断是：当前 `mem_rsp_t` 只有 `rdata/fault`，没有 response ID、epoch 或“关键字已
返回/后台 refill fault”分类（`rtl/lcvex_pkg.sv:699-718`）。因此 F1a 必须保持**单个
I-L1 请求、单个 MMU 取指翻译在途**，并在 flush 后先消费/丢弃旧响应再发新请求；如果
实现试图同时挂起两个没有显式身份的取指事务，任务应立即退回，不得靠 PC 猜测响应归属。

F1b 的 later refill beat 若返回 fault，而 critical word 已被消费，现有协议没有安全的
精确异常表示：忽略 fault 会改变错误路径语义，重新发异常会把未被执行的相邻 beat 错报
成当前指令异常，提前发布 tag/valid 又会暴露不完整行。故本预研的明确建议是：**先实施
F1a；F1b 保持默认关闭，直到增加并验证 background fault/line-completion 契约，或证明
整行所有 beat 在发布 critical word 前均不会 fault。**

## 1. 范围、非目标和架构边界

目标固定为单核、AArch64、单发射、顺序执行和顺序提交。F1a/F1b 不引入 BTB、RAS、
方向预测、2-wide、寄存器重命名、推测提交、多个数据 outstanding 或 MSHR；这些属于
其它后续方向。

F1 只优化取指交付：预取数据只能进入 FIFO/cache，不能更新 GPR、SP、NZCV、系统寄存器，
也不能产生 store、原子或其它架构内存副作用。`commit_packet_t` 的每周期至多一个提交、
PC/next-PC/写回/NZCV/内存副作用字段保持不变，遵循 `docs/COMMIT_PACKET.md`。

当前没有 F1 参数；下面的参数是未来实现任务必须冻结的初值：

| 参数 | 建议值 | 语义 |
|---|---:|---|
| `FETCH_FIFO_ENABLE` | `0` | F1a 总开关，默认旧路径 |
| `FETCH_FIFO_DEPTH` | `2` | 仅允许值 0/2；2-entry FIFO |
| `FETCH_EPOCH_W` | `8` | 非架构 fetch generation 宽度 |
| `FETCH_EARLY_RESTART_ENABLE` | `0` | F1b 开关；没有 F1b gate 不得置 1 |
| `FETCH_DEBUG_ENABLE` | `0` | 只读计数/内部观测，默认不改变端口行为 |

F1a 不改 `mem_req_t/mem_rsp_t` 的公共 ABI，不改 I-L1、MMU 和仲裁器的通用状态机。
如果 quarantine 不能在目标入口上成立，必须另立“取指事务 ID/epoch sideband”协议任务，
把 `rtl/lcvex_pkg.sv`、`rtl/lcvex_l1_i.sv`、`rtl/lcvex_mmu.sv`、
`rtl/lcvex_mem_arb.sv` 等写集纳入该任务，而不是扩大 F1a 的隐含范围。

## 2. 当前取指和内存生命周期

### 2.1 当前 core 取指逻辑状态

当前 core 没有显式 fetch enum，而是由多个 flag 组合出生命周期。`if_pc` 是当前取指
虚拟地址；它只在捕获或重定向时推进（`rtl/lcvex_core.sv:351-360`、
`2116-2135`）。下表把组合 flag 映射为审阅时使用的逻辑状态。

```text
 RESET/IDLE
     │ MMU on: fetch_req_accept
     ▼
 MMU_TRANSLATE_WAIT ── mmu_done ──> TRANSLATED
     │                                   │ imem_req_accept
     │                                   ▼
     └──────────────────────────────> IMEM_WAIT
                                         │ imem_rsp_valid
                    fault ──────────────┴──────────────> FETCH_FAULT_HOLD
                    data  ─────────────────────────────> DATA_HOLD
                                                          │ capture_now
                                                          ▼
                                                       IF/ID
                                                          │ branch/system/IRQ/reset
                                                          └────────> FLUSH/DROP + redirect
```

| 逻辑状态/事件 | 当前判定与动作 | 主要源码引用 |
|---|---|---|
| `RESET/IDLE` | 复位时 `if_pc=RESET_PC`，`fetch_pending/fetch_translated/fetch_got_data/fetch_faulted` 清零；正常情况下只有没有在途状态时才发请求 | `rtl/lcvex_core.sv:1772-1779`、`2009-2016` |
| `MMU_TRANSLATE_WAIT` | MMU 开启且取指空闲时 `fetch_req_valid`；`mmu_req_valid` 对数据翻译优先；接受后置 `fetch_trans_busy` | `rtl/lcvex_core.sv:1104-1117`、`1118-1139`、`2155-2161` |
| `TRANSLATED` | `mmu_done` 锁存 `fetch_pa_r/fetch_cacheable_r/fetch_fsc_r` 和原 VA；成功后下周期发 I-L1/内存读，fault 则置 `fetch_faulted` | `rtl/lcvex_core.sv:2155-2169` |
| `IMEM_WAIT` | `fetch_imem_req_valid` 要求无 pending/got/fault/flush；接受后置 `fetch_pending`，MMU off 同时登记 `fetch_pc_r=if_pc` | `rtl/lcvex_core.sv:1570-1582`、`2171-2177` |
| `DATA_HOLD` | `imem_rsp_ready=1`；pending 响应成功写 `fetch_data_r` 并置 `fetch_got_data`，不成功置 fault | `rtl/lcvex_core.sv:1593-1599`、`2179-2191` |
| `IF/ID capture` | 只有 `fetch_got_data`、`if_pc==fetch_pc_r` 且无 flush/stall 才 `capture_now`；捕获后 IF/ID 有效且 `if_pc+=4` | `rtl/lcvex_core.sv:1598-1599`、`2192-2212` |
| 分支 flush | `flush_id` 在 ID 计算目标，要求无 load-use、EX busy、dmem pending、WB 背压和 fetch walk；重定向并清理取指上下文 | `rtl/lcvex_core.sv:1561-1569`、`2127-2134`、`2145-2153` |
| 系统提前重定向 | ERET/异常/屏障/维护/MSR 等在 MMU on 时由 `sys_fetch_redirect` 提前把 `if_pc` 设为 `d.next_pc`；系统提交时再统一清理 | `rtl/lcvex_core.sv:1267-1281`、`2127-2129` |
| fault hold/合并 | `fetch_faulted` 只能在 `fetch_pc_r==memwb_next_pc` 时和 older WB 合并为 IABT，或在 `sys_commit` 时与系统指令合并；合并保留 older 写回 | `rtl/lcvex_core.sv:1257-1288`、`3067-3170` |
| stall | `stall_id` 包含数据翻译、fetch walk、dmem pending、EX/MEM/WB 阻塞和系统排空；`stall_if=stall_id||ex_busy||wfi_idle` | `rtl/lcvex_core.sv:1513-1560` |

当前响应接口没有 tag，之所以可工作，是因为取指路径在 core 侧一次只有一个
`fetch_pending`；但 flush 后原响应仍可能从下游返回，当前代码通过清除 pending 并保持
`imem_rsp_ready=1` 将其消费而丢弃（`rtl/lcvex_core.sv:2145-2189`）。这个隐含的单事务
前提必须被 F1a 显式写成契约。

### 2.2 I-L1 生命周期

I-L1 是 64B line、64 sets、直接映射、阻塞式单事务。`S_IDLE` 接受普通请求；miss 进入
`S_REFILL/S_REFILL_WAIT`，每次发一个 8B beat；只有第 8 个 beat 成功才写 `tag/valid`
并进入 `S_RSP`（`rtl/lcvex_l1_i.sv:42-100`、`152-181`）。hit、旁路和维护的行为为：

| I-L1 状态 | 当前行为 |
|---|---|
| `S_IDLE` | `u_req_ready=1`；hit 直接锁存旋转后的数据；IC IALLU 清全部 valid，IC IVAU 清目标 set |
| `S_REFILL` / `S_REFILL_WAIT` | 每拍最多一个下游请求/响应；目标 beat 的数据暂存在 `rsp_data_r`，但不会提前响应 |
| `S_BYPASS` / `S_BYPASS_WAIT` | Device/不可缓存读直通，不分配 line |
| `S_RSP` | `u_rsp_valid=1`，等待 `u_rsp_ready` 后回到 idle |

下游 fault 会作废该 set 并向上游返回 fault（`rtl/lcvex_l1_i.sv:158-180`）；维护请求被
接受后直接响应（`rtl/lcvex_l1_i.sv:117-135`）。现有 I-L1 SVA 只证明单 outstanding、
响应状态和维护响应（`rtl/lcvex_l1_i.sv:210-227`）。

### 2.3 MMU 和共享仲裁

MMU 的 `S_IDLE` 仅接受一个请求；TLB hit/直通在一个结果周期完成，miss 经过
`S_L[0-3]_REQ/WAIT` 和 `S_COMPLETE`，`done=busy&&(state==S_IDLE)`，TLBI 会清 TLB、
中止在途遍历且不保证返回 `done`（`rtl/lcvex_mmu.sv:84-131`、`269-301`、
`360-458`、`493-510`）。F1a 因此要保存取指翻译 context，遇 flush 时忽略旧 epoch 的
`mmu_done`，并在 MMU 回到 idle 前禁止新取指翻译。

`lcvex_mem_arb` 端口固定为 PTW(0)>data(1)>instruction(2)，`in_flight` 期间完全不接收
新请求，响应按锁存的 `sel_r` 路由（`rtl/lcvex_mem_arb.sv:33-82`）。F1a 只在 I-L1
上游增加队列，不改变 PTW/data/I 的公共单 outstanding；PTW 优先级和可变延迟仍须覆盖。

### 2.4 维护、异常和等待边界

维护状态机为 `MS_IDLE/TRANSLATE/REQ/WAIT/DONE/DCZVA_WRITE`；IC IVAU/IALLU 和 TLBI
在 ID 排空后提交，TLBI 同拍发 `tlb_invalidate`，DC ZVA 做 8 次 8B 清零
（`rtl/lcvex_core.sv:3517-3648`）。系统提交要求 `!idex_valid&&!exmem_valid&&!memwb_valid`
和 `commit_ready`，维护/MSR/WFI 等还要求 next-PC 翻译 settled（`1513-1543`）。

WFI/WFE/WFIT/WFET 在系统提交后进入 idle；wake 由 IRQ、事件、计时器或测试 sideband
触发，等待 IRQ 会生成异步异常提交（`rtl/lcvex_core.sv:1175-1185`、`2674-2722`、
`2864-2914`）。普通 IRQ 在 commit 边界取走并跳向量，ID 系统指令解开 DAIF 后也可在
同一系统提交边界取 IRQ（`1183-1203`、`3323-3352`）。ERET 在 ID 提交，恢复 SPSR/EL/SP
并跳 `ELR_EL1`，目标取指 fault 合并回 ERET（`2722-2863`、`3025-3032`）。这些边界
都必须丢弃 FIFO 中的年轻取指，并提升 epoch。

复位清空 core 的所有取指 flag；C1 wrapper 的 `core_rst_n` 同时复位 core、arbiter 和
私有 RAM/cache，STOPPED 则门控 core clock（`rtl/lcvex_core_wrap.sv:125-165`、
`359-421`）。F1a 必须保持这一 reset fanout；若未来出现“只复位 core、不复位下游”的
入口，则必须启用外部 reset generation/response ID，不能继续依赖本地 flag。

## 3. F1a 冻结契约

### 3.1 身份、epoch 和在途限制

F1a 的身份是非架构的本地 `fetch_token`，建议字段如下；它不进入 commit packet：

| 字段 | 宽度/来源 | 约束 |
|---|---:|---|
| `epoch` | 8 bit | 当前 fetch generation；正常流不变，flush 事件加一，reset 置 0 |
| `seq` | 16 bit | 每个取指翻译/内存请求递增，便于断言与失败诊断；不参与架构状态 |
| `slot` | 1 bit | 2-entry FIFO 的 tail slot；仅用于本地 bookkeeping |
| `pc_va` | 64 bit | 请求的虚拟 PC；FIFO/故障/FAR 一律绑定此值，不能用 PA 替代 |
| `pa` | 64 bit | MMU 成功结果，仅存在于 fetch context，供 I-L1 请求 |
| `cacheable` | 1 bit | MMU 属性快照；Device 取指沿用 bypass |
| `fsc/fault` | 6 bit/1 bit | 翻译或下游 fault 元数据；fault token 不能进入 ID/EX |

F1a 在当前不带身份的公共内存协议上冻结以下硬约束：

1. core 到 MMU 的取指翻译最多一个在途；core 到 I-L1 的取指读最多一个在途；二者不可
   各自开启第二个同类事务。
2. 一个非 stale 的已接受请求必须恰好对应一个响应；响应可能任意延迟并背压，但不可
   乱序、重复或无响应。若适配器不满足该句，先做 sideband 协议任务。
3. `fetch_token` 在翻译等待、物理读等待和响应待入 FIFO 期间保持不变。MMU/I-L1
   的响应没有 token 时，只能由“恰好一个当前 context + quarantine”确定归属。
4. flush/reset/TLBI/IC invalidate 后，旧 context 的任何 data/fault 都是 stale，只能被
   `imem_rsp_ready`/MMU 完成通道消费后丢弃，不能 push FIFO、不能产生 IABT、不能更新
   `if_pc` 或 metadata。
5. stale response 尚未被消费时，不得接受新的 I-L1 request；否则旧响应会与新请求混淆。
   有显式 token 的未来接口可以放宽此限制，但不属于 F1a。

### 3.2 FIFO entry 和 IF/ID 绑定

2-entry FIFO 每项至少包含：

```text
valid, epoch, seq, pc_va, insn[31:0], fault, fault_fsc[5:0]
```

实现可保留 `pa/cacheable` 作为 debug context，但不得以 PA 作为 IF/ID 的 PC。`pc_va`
是架构提交/异常诊断的唯一 PC；`insn` 仅在 `fault=0` 时有效；fault entry 不能被译码
成 UDEF，也不能进入 ID/EX。

FIFO 头送入现有 IF/ID。ID/EX 仍由现有 `ifid_valid` 和 `stall_id` 控制，因此 FIFO 只是
供给层，不改变单发射和提交顺序。FIFO 充满时停止发新取指；IF/ID stall 时允许最多填
满 2 项，不能覆盖头项。没有分支预测，tail PC 只按 `+4` 生成，重定向后 tail 改成
目标 PC。

### 3.3 push/pop/flush 优先级

按一个时钟沿冻结如下优先级，便于 RTL 和 SVA 对齐：

1. **reset/restore**：清 FIFO、IF/ID、所有 fetch context；epoch reset 为 0（restore
   还必须清除旧请求或进入 quarantine）。
2. **flush/kill**：TLBI、IC invalidate、同步异常、系统提交重定向、IRQ、WFI wake、
   分支 redirect 任一成立时，清 FIFO/IFID 并抑制本拍 push/pop；epoch 只加一次。
3. **stale response consume**：若本拍有旧响应，保持 ready=1 消费并丢弃，不论 FIFO 是否
   满；清除 stale context，之后才允许新请求。
4. **正常 response push**：仅当响应 context 仍为当前 epoch 且 FIFO 有空间（或同拍 pop）
   时接受；FIFO 满且无 pop 时拉低 `imem_rsp_ready`，让 I-L1 保持 `S_RSP`。
5. **normal pop/IFID replenish**：ID 接收当前 IF/ID 且没有系统/flush 时弹出 FIFO 头；
   可在同拍用下一项替换 IF/ID。
6. **issue**：只在没有 stale quarantine、没有 fault head、没有维护/系统排空和 FIFO 未
   满时发下一个 tail 请求。

正常情况下 `push && pop` 允许同拍发生，occupancy 不变；flush 优先时二者都不计入。推荐
   `occupancy` 使用 2 bit（0..2），read/write pointer 1 bit，并保留 `peak` 计数供测试。

### 3.4 flush/epoch 事件表

| 事件 | epoch 动作 | FIFO/请求动作 | 架构动作/备注 |
|---|---|---|---|
| 外部 reset 或 C1 per-core reset | 置 0，reset 后第一代为 0 | 全清；若下游未同时 reset，先 quarantine | 不产生提交；保持 core/arb/cache reset fanout |
| 分支 `flush_id` | `+1` | 清年轻 FIFO/IFID；旧 MMU/IMEM response 进入 drop | 分支本身仍按原顺序进入 ID/EX/WB |
| 同步 UDEF/SVC/IABT/DABT 或 fetch fault merge | `+1` | 清年轻项；fault token 只能绑定匹配 older/system commit | 不把 stale fault 重分类成新异常 |
| `SYS_MSR` 改 MMU/TCR/TTBR/MAIR、ERET、其它系统重定向 | 识别重定向时 `+1` | 清年轻项；target fetch 只能是 held-for-system context | 系统提交仍等更老流水线和 `commit_ready` |
| `IC IVAU/IALLU` | 维护开始时 `+1` | 先清/排 stale，再发 I-L1 maintenance；维护完成前不暴露年轻数据 | IC 请求仍由 I-L1 的 `S_IDLE` 接受 |
| `TLBI` | TLBI 脉冲时 `+1` | 清 fetch context；忽略被 MMU 中止/晚到结果 | 与 `tlb_invalidate` 同拍；重新翻译 next PC |
| 普通 WB IRQ (`irq_taken`) | `+1` | 丢年轻 FIFO/IFID/取指在途，向 IRQ vector 重启 | 当前较老指令提交包保留原写回/内存副作用 |
| ID 系统 IRQ (`sys_irq_taken`) | `+1` | 同上，系统提交包 next_pc=IRQ vector | `ELR=d.next_pc`，SPSR 保存写后 DAIF |
| WFI/WFE/WFIT/WFET 进入 idle | 提交时 `+1` | 清年轻项和请求；idle 期间禁止 issue | 等待指令自身只提交一次 |
| WFI IRQ wake/计时器 wake | IRQ 入口 `+1`；纯 timeout 恢复也新开代 | 清旧项；从 `wfi_pc+4` 或 vector 重启 | IRQ wake 为异步异常提交，timeout/事件恢复不合成提交 |
| checkpoint restore | restore 边界开始新代（推荐 `+1` 后置 0 仅在 reset） | 所有 fetch/commit 清空，从 restored PC 开始 | 不能用 QEMU state 逐条回灌 |

**一次事件只加一次**：例如 TLBI 同拍触发 core flush 时由统一 `frontend_kill` 产生一次
epoch bump；不要让 `tlb_invalidate`、`sys_commit` 和 `flush_id` 各自重复加三次。

### 3.5 fault、系统排空和 commit packet

* 翻译 fault 或 I-L1/memory fault 进入 FIFO fault head 时，停止后续 issue；entry 保存
  `pc_va/fsc`，不产生 `ifid_valid`。
* 保持现有精确合并规则：fault PC 必须等于 older `next_pc`，在 older WB commit 上置
  `exc_valid=1`、IABT code/ESR/FAR；older GPR/SP/NZCV 和本条可能的内存副作用仍保留。
  若 fault 是系统指令 next-PC，合并到该 ID system commit。任何 stale fault 都被丢弃。
* 当前协议对“复位后第一条取指就 fault、且没有 predecessor commit”的 standalone IABT
  没有独立路径；F1a 不应悄悄发一个伪造 packet。该情形要么由上层保证 RESET_PC 可取，
  要么另立异常协议任务并增加 QEMU/RTL 对照测试，列为 F1a blocker。
* 系统/维护/ERET/WFI 提交条件必须包括：更老 `idex/exmem/memwb` 均空、数据翻译和
  dmem 无在途、FIFO/IFID 年轻项已清、stale response 已消费；若要提前取 system target，
  target response 只能存入 held context，不能进入 ID/EX，且必须等系统提交/维护 ack 后
  才可释放。
* `commit_ready=0` 时，任何 FIFO pop、system commit 或架构状态更新都不能发生。FIFO
  可以填到 2 项但不能造成 commit packet 变化；沿用现有 backpressure 语义。

### 3.6 跨页、跨 line 和属性边界

| 场景 | F1a 必须行为 |
|---|---|
| PC=`...0xFFC` 到下一 4 KiB 页 | 两个独立 `pc_va` entry；每个地址独立翻译/权限检查；前页旧 entry 可正常提交，下一页 fault 绑定 `pc_va+4` |
| 64B line 边界（例如 offset `0x3C` 后 `0x40`） | I-L1 仍以完整 line 响应；两个请求不能共用未完成 line 的未公开 metadata；PC 永远按 4B 增加 |
| MMU off→on 或 on→off | 修改 SCTLR/TCR/TTBR/MAIR 的 MSR 先排空并 kill 年轻项；next PC 使用提交后的有效翻译状态，不跨状态消费旧 entry |
| TLB hit/miss、TLBI | hit/miss 只影响等待时间；TLBI 后旧 translation response 必须 drop，next PC 重新翻译 |
| Device/Non-cacheable | 保持 `cacheable=0/bypass=1`；不可把 Device response 当成普通 I-L1 hit |
| IABT/error response | 保存故障 VA/FSC；不把邻近预取的 fault 改绑到另一条指令 |
| 自修改代码 + DMB/IC IVAU/ISB | 维护开始清 FIFO/epoch，等待 IC ack 后再取；旧 cache/FIFO data 不得越过维护边界 |

## 4. 建议的 F1a 实现状态和接口

实现可以合并现有 flags，但建议在 core 内部显式形成以下状态/事件线：

| 建议状态 | 进入 | 退出 |
|---|---|---|
| `FQ_EMPTY/READY` | reset/flush 后，无在途 | issue translation/request 或 pop 后仍有 head |
| `FQ_TRANSLATE_WAIT` | fetch translation accepted | current epoch `mmu_done`；stale 则进入 drop |
| `FQ_IMEM_WAIT` | I-L1 request accepted | current response push，或 stale response drop |
| `FQ_FULL` | occupancy=2 | pop、flush 或 reset |
| `FQ_FAULT_HEAD` | current epoch fault push | matching older/system merge；merge 后 flush |
| `FQ_STALE_DRAIN` | flush/reset 时存在旧 MMU/IMEM context | 消费旧 done/response；才回 READY |
| `FQ_HOLD_SYS_TARGET` | system/maintenance/ERET target 提前取回 | system commit/maintenance ack 后释放或 fault merge |

F1a 不要求改公共请求类型；core 本地建议新增 `fetch_ctx_r` 和 FIFO debug 信号：

```text
fetch_ctx_valid, fetch_ctx_epoch, fetch_ctx_seq, fetch_ctx_pc_va,
fetch_ctx_pa, fetch_ctx_stale, fetch_stale_drain,
fetch_fifo_valid[1:0], fetch_fifo_pc[1:0], fetch_fifo_fault[1:0],
fetch_fifo_occupancy, fetch_fifo_push/pop/flush, fetch_epoch
```

这些信号仅在 `FETCH_DEBUG_ENABLE=1` 下暴露或供层级 SVA 观察；默认不能进入提交包和
架构状态。`imem_rsp_ready` 的推荐定义是：current response 可 push，或 stale drain
需要消费；不要继续无条件拉高并在 FIFO 满时覆盖数据。

## 5. 维护/异常/等待的精确事件序列

下面是 F1a 任务必须按时序实现和验证的共同契约：

| 序列 | 事件 | 允许的 frontend 动作 | 禁止动作 |
|---|---|---|---|
| 1 | 普通顺序执行 | FIFO 预取最多填 2 项；头项进入 IF/ID 后按序提交 | 不跳过头项，不预测分支 |
| 2 | 分支在 ID 得出重定向 | 本拍 branch 进入 ID/EX；清 IF/ID/FIFO，epoch+1；旧响应 drop | 把旧路径 entry 留给新目标 |
| 3 | MMU fetch walk | 保持 current context/epoch；允许 arb PTW 优先完成 | 新开第二个 fetch walk；使用未锁存 VA |
| 4 | IC IVAU/IALLU/TLBI | 先 kill 年轻项并排 stale；维护请求/`tlb_invalidate` 完成后才 commit/重启 | 旧 I-L1 响应填新 FIFO；在 maintenance ack 前译码 |
| 5 | WFI/WFE commit | 清年轻项和请求，进入 idle；wake 后从指定 PC 开新代 | idle 中继续请求；wake 时消费旧 response |
| 6 | IRQ 边界 | 当前 older commit 保留；清年轻项，保存 ELR/SPSR，vector 新代 | 年轻 FIFO 指令先提交或影响 SPSR |
| 7 | ERET commit | 清年轻项，按恢复后的 EL/SP 权限翻译 ELR；fault 只合并 ERET | 按旧 EL 检查目标权限；释放旧路径 entry |
| 8 | `commit_ready=0` | 保持 IF/ID、FIFO head、system state 和 commit packet | pop、epoch bump、MSR/ERET/WFI 架构更新 |

## 6. F1a/F1b/F1c DAG、写集和串行关系

```text
F0 基线（已交付，需同 SHA 复测）
              │
              ├──────────────┐
              ▼              ▼
       F1a 契约/RTL+TB   F1c 测量框架准备（不改 RTL）
              │              │
       F1a base/cache/d2     │
       L0-L2 全部稳定         │
              ▼              │
       F1b safety gate ───────┘
              │
              ▼
       F1b（条件性）RTL+TB
              │
              ▼
       F1c 分离复测：F0 / F1a / F1a+F1b
```

| 切片 | 目标 | 建议精确写集 | 关系 |
|---|---|---|---|
| F1a-impl | 2-entry FIFO、epoch、quarantine、debug/SVA | `rtl/lcvex_core.sv`；`tb/sv/lcvex_soc_tb.sv`（参数/只读观测）；新建 `tb/sv/lcvex_fetch_fifo_tb.sv`；新建 `sim/cocotb/test_fetch_fifo.py`；新建 `sim/cocotb/Makefile.fetch_fifo`；`Makefile`（两个入口）；`sim/difftest/test_program.py`（新增 epoch/边界镜像）；新建 `sim/difftest/run_f1a.sh`；对应 handoff/evidence | F0 后；与 F3 core 写集串行 |
| F1a-proto（仅阻断时） | 给请求/响应加真实 token/epoch | `rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、`rtl/lcvex_l1_i.sv`、`rtl/lcvex_mmu.sv`、`rtl/lcvex_mem_arb.sv`、`rtl/lcvex_mem_delay.sv`、`rtl/lcvex_mem_ram.sv`、相关 TB/协议 | 不得混进 F1a-impl；先评审再实现 |
| F1b | critical-word-first、held early response、line completion/fault | `rtl/lcvex_l1_i.sv`、`rtl/lcvex_core.sv`；若采用 sideband 则加 `rtl/lcvex_pkg.sv`、`rtl/lcvex_mem_arb.sv`；`tb/sv/lcvex_l1_i_early_restart_tb.sv`、`tb/sv/lcvex_soc_tb.sv`、新建 `sim/cocotb/test_l1_i_early_restart.py`、新建 `sim/cocotb/Makefile.f1b`、`sim/difftest/test_program.py`、新建 `sim/difftest/run_f1b.sh`、`Makefile`、对应 handoff/evidence | 只能在 F1a L0-L2 和 §7 gate 后；与 F3/F4 core/cache 写集串行 |
| F1c | F0/F1a/F1b 同口径数据报告 | 新建 `docs/PERFORMANCE_F1_RESULTS.md`、对应 handoff/evidence；若现有 F0 runner 不足，另登记 metrics-infra 任务，不直接扩大 F1c | 可与 F1a 设计并行；复测必须按实现 SHA 串行 |

F1a 明确不写 `rtl/lcvex_l1_i.sv`、`rtl/lcvex_mmu.sv`、`rtl/lcvex_mem_arb.sv` 和
`rtl/lcvex_pkg.sv`；这是保持“小改动、单在途、旧公共协议”的关键。若新测试证明
quarantine 不足，应停在 F1a-proto，而不是隐式扩大写集。

## 7. F1b 风险门：critical-word-first 是否能保持精确语义

### 7.1 当前协议下的反例

当前 I-L1 在 line miss 时连续发 8 个 8B 请求，任一 `d_rsp.fault` 都把整次 refill
变为 `u_rsp.fault`，且 `mem_rsp_t` 没有 beat 地址/事务 ID。假设 line 起始于靠近
`SRAM_TOP` 的可访问 beat：

1. target beat 成功，early-restart 把 instruction word 发给 core，FIFO/IF/ID 可能消费，
   甚至提交该指令；
2. 后续 beat 越过窗口或外部返回 fault；
3. 当前协议无法区分“target 指令有效、后台 line 失败”和“当前指令 fetch fault”。

以下三个处理都不能在现契约下直接接受：

| 处理 | 问题 |
|---|---|
| 继续把 later fault 上抛为 IABT | 将未访问的相邻 beat fault 错绑到已消费/已退休 instruction |
| 直接吞 later fault 并保留 line | 暴露不完整 line，下一次读取可能读到未填数据；也改变旧路径 fault 语义 |
| fault 时回滚 early instruction | 提交包/架构状态无法回滚，违反精确异常 |

### 7.2 F1b 解锁条件

F1b 只有满足以下之一才能登记实现任务：

* **全行预检方案**：在发布 critical word 前证明 line 内所有 8 个 beat 的 PA/权限/窗口
  都合法，且下游保证后续不会发生外部 fault；这是对 `mem_rsp.fault` 的新明确保证，
  不能只依赖静态地址猜测。
* **后台 fault 分类方案**：增加明确的 `critical_word`、`fill_done`、`fill_fault` 和
  line/epoch 身份。critical word 已成功且被消费后，later background fault 只作废
  fill line、不得发架构 IABT；若 critical word 自身 fault，才生成 fault entry。
* **延迟发布方案**：critical word 可先在 I-L1 内部保存，但直到整行成功才对 core
  响应。这保持正确性但不再是 early-restart，应该另称 refill 优化而不是宣称 F1b 收益。

无论方案为何，`tag/valid` 必须保持“最后一个 beat 成功且无 fill fault 后才发布”。
early word 被消费后，若 line 最终失败，必须保证：该 line 不命中、不会把旧/半新数据
当作完整 line 返回、不会生成额外架构提交，也不会改变已退休指令的异常状态。

### 7.3 F1b 必测场景和停止条件

* 目标 beat 为 line offset 0、非 0、offset 56/60；后续 beat fault 和 target beat fault
  分别注入。
* fault 在 target 已进入 FIFO、已进入 IF/ID、已进入 ID/EX、已提交之后到达的四个时点。
* flush/branch、TLBI、IC IVAU/IALLU、reset 在 early response 和 later beat 之间发生。
* MMU off/on、跨 4 KiB 页、跨 64B line、Device/bypass 与权限 fault。

任一情况下出现 commit mismatch、半行 hit、stale response 入 FIFO、重复/缺失响应、
later fault 误生 IABT 或无法证明 fault 分类，`FETCH_EARLY_RESTART_ENABLE` 必须保持 0，
F1b 任务退回设计评审；F1a 不受影响。

## 8. SVA 和观测契约

建议 F1a 在 core 内增加以下 property（名称可调整，但语义不得省略）。仅增加断言，
不得删除当前 `lcvex_core.sv:3654-3725` 和 `lcvex_l1_i.sv:210-227` 的已有断言。

| Property | 断言语义 |
|---|---|
| `p_fetch_epoch_bump_on_kill` | 每个非 reset frontend kill 事件恰好使 epoch 加一；同拍多个原因仍只加一次 |
| `p_no_issue_during_stale_drain` | `fetch_stale_drain` 为 1 时不能接受新的 MMU/IMEM request |
| `p_stale_rsp_never_push` | stale MMU/IMEM response 可以被消费，但绝不能 `fifo_push`/`ifid_valid`/fault merge |
| `p_single_fetch_translation` | 未完成的 fetch translation context 存在时不能接受第二个 fetch translation |
| `p_single_fetch_imem` | 一个 current IMEM request 未完成时不能接受第二个 IMEM request |
| `p_fifo_bounds` | 每个非 flush 沿 occupancy 在 0..2；不得 overflow/underflow |
| `p_fifo_accounting` | 非 flush：`occ_next=occ+push-pop`；flush：`occ_next=0` 且 push/pop 被抑制 |
| `p_fifo_entry_current_epoch` | 进入 FIFO 的 entry epoch 等于当前 epoch；head 过期不得进入 IF/ID |
| `p_pc_binding` | IF/ID PC、fault FAR 和提交诊断 PC 等于对应 entry `pc_va`，不使用 `pa` |
| `p_fault_merge_binding` | IABT merge 仅在 fault PC 等于 older `next_pc` 或 held system target 时发生 |
| `p_fault_stops_issue` | fault head 未 merge 前不能有年轻 fetch request/entry |
| `p_flush_priority` | kill 同拍 response 不 push；branch/system 的目标代次不能消费旧响应 |
| `p_sys_drain` | system/maintenance/ERET/WFI commit 前，older pipeline/data 和 frontend drain 条件成立 |
| `p_commit_ready_atomic` | `commit_ready=0` 时不产生 system/normal commit、不更新架构状态、不 pop FIFO |
| `p_reset_no_commit` | reset 期间和 release 前不产生 commit；release 后只能提交新代请求 |
| `p_mmu_context_snapshot` | `mmu_done` 只更新与 current fetch context 同代的 PA/cache/fault |

F1b 额外需要 `p_il1_meta_after_last_beat`（valid/tag 仅在最后 beat 成功后更新）、
`p_early_fault_classification`（target fault 与 background fault 不混淆）和
`p_no_partial_line_hit`（fill 未完成时不能命中）。

建议只读计数器/trace 字段：`fetch_req_accept`、`fetch_rsp_accept`、
`fetch_stale_rsp_drop`、`fetch_translation_req/done/stale`、`fetch_fifo_push/pop/flush`、
`fetch_fifo_peak`、`fetch_epoch_bump`（按 branch/system/TLBI/IC/IRQ/WFI/reset 分类）、
`fetch_fault_head`。它们不是 ARM PMU 事件，必须在报告中标为仿真观测代理。

## 9. L0-L2 验证矩阵

本任务没有运行任何测试。下表是未来 F1a/F1b 任务的精确验证套餐；新增入口在对应
任务登记后才存在，当前命令不能据此声称通过。

### 9.1 L0：快速 RTL/模块和边界

| 用例 | 命令/内容 | 必查 |
|---|---|---|
| 静态写集 | `git diff --check`；确认只改登记写集 | 无 whitespace 错误、无越权文件 |
| F1a FIFO BFM | `make sim-sv-fetch-fifo`（F1a 新增） | depth=0/1/2、满/空、push+pop、flush 优先、PC/inst/fault 绑定 |
| F1a Cocotb | `make sim-cocotb-fetch-fifo`（F1a 新增） | delayed stale response、branch redirect、commit backpressure |
| 现有 I-L1 | `make sim-sv-l1i` | 读 hit/miss、冲突、fault、bypass、IC IVAU/IALLU；F1a 不改变整行响应 |
| 现有 MMU | `make sim-sv-mmu` | TLB miss/hit、permission、TLBI、MMIO 属性；F1a 不改变翻译结果 |
| 现有核心/背压 | `make sim-sv`、`make sim-sv-backpressure`、`make sim-cocotb-core`、`make sim-cocotb-backpressure` | default-off 和 F1a-on 的提交顺序、ready 原子性 |
| fault/reset BFM | 新增 `lcvex_fetch_epoch_tb.sv` 测试固定延迟响应在 branch/TLBI/IC/reset 后只 drop | 不允许旧 response 进入 FIFO 或 commit |

### 9.2 L1：SVA、随机延迟和系统边界

建议由 F1a task 在 `tb/sv/lcvex_fetch_fifo_tb.sv` 里加入可控 BFM，而不是用不确定的
随机延迟替代定向 stale 场景。套餐至少包括：

* `FETCH_FIFO_ENABLE=0/1`、`I_L1_ENABLE=0/1`、`MEM_DELAY_MODE=0/1/2`；其中 mode 2
  是现有可复现 0..4 周期 LFSR，不是任意固定延迟。
* FIFO 满时 response backpressure；flush 与 response 同拍；flush 后旧 response 晚到；
  MMU walk `done` 晚到；TLBI 中止 walk。
* PC `...0xFFC -> ...0x1000`、64B line offset `0x3C -> 0x40`、IABT/外部 fault、
  MMU off/on、Device bypass、IC IVAU/IALLU、WFI/IRQ/ERET 和 `commit_ready=0`。
* SVA 全部无失败；FIFO occupancy、push/pop/epoch/drop 计数与 BFM 事件一一对应。

F1b 的 L1 还必须包含 target/later beat fault 矩阵和 metadata visibility 断言；在这些
   用例没有精确结论前不得进入 L2。

### 9.3 L2：QEMU 单步锁步

优先复用现有脚本和镜像，避免把“测试生成器”误写成已经执行：

| 目的 | 命令 | 现有覆盖 |
|---|---|---|
| MMU/取指 fault | `bash sim/difftest/run_p5a.sh` | `p5a_mmu`、`p5a_mmu_el0`、`p5a2_fetch`；含分支 IABT、页末顺序 fault |
| 系统/异常/ERET | `bash sim/difftest/run_gate_c.sh` | EL1/EL0 SVC、UDEF、DABT、IABT、ERET 往返 |
| IC/TLBI/self-modify | `bash sim/difftest/run_m2_4b.sh --only hard_selfmod,hard_tlbi,hard_sys_fetch_fault,hard_msr_mmu_on` | IC IVAU/ISB、TLBI、空流水线 fault merge、MMU on MSR，不改 I-L1 语义 |
| WFI/IRQ/ERET | `bash sim/difftest/run_p6_wfi.sh` | WFI/WFE/WFIT/WFET、timer IRQ wake、ERET |
| random delay/cache | `bash sim/difftest/run_gate_d.sh --only delay2-cache-hard_selfmod,delay2-cache-hard_tlbi,delay2-cache-hard_sys_fetch_fault,delay2-cache-hard_irq` | 全缓存+0..4 周期延迟；由集成者排队运行 |
| 新增 stale/reset | F1a task 新建 `sim/difftest/run_f1a.sh`，至少包含 `hard_fetch_epoch`、`hard_fetch_4k`、`hard_fetch_line`、`hard_fetch_reset`，base/cache/delay2 各跑一次 | 明确旧响应 drop、跨页/line、reset in-flight |

每个 L2 运行必须使用同一个 QEMU release/patch、镜像/source SHA 和 coordinator；逐条
`PRE/COMMIT`、RTL commit packet 和 QEMU `seq` 一一对应。失败时保存指令编码/反汇编、
执行前状态、RTL/QEMU 状态和最近提交，不得通过关闭断言或跳过差分项“修绿”。

## 10. F1c 性能矩阵和定量 acceptance

F0 文档中的历史基线来自另一个代码 SHA（`b47175ea...`），不能直接与本任务 base 的
绝对 cycle 相减。F1c 必须先在冻结 F0 source SHA 上重跑公共基线，再比较：

| 配置 | `FETCH_FIFO_ENABLE` | `FETCH_EARLY_RESTART_ENABLE` | 用途 |
|---|---:|---:|---|
| `f0` | 0 | 0 | 当前路径锚点 |
| `f1a` | 1 | 0 | 隔离 FIFO/epoch 的影响 |
| `f1ab` | 1 | 1 | 仅 F1b gate 通过后，隔离 early-restart |

每个 workload/config 记录 `cycles`、`retired_insn`、`ipc`、`stall_if`、`fetch_wait`、
`branch_flush`、`ptw_stall`、I-L1 upstream/hit/miss/refill/downstream、arb/RAM requests
和 §8 fetch debug counters。统一使用 F0 的 14 项：
`alu_latency`、`alu_ilp`、`ctrl_branch`、`muldiv`、`mem_seq`、`mem_random`、`mem_ldst`、
`fp_scalar`、`fp_fp16`、`neon_vect`、`kernel_crc`、`kernel_hash`、`kernel_matmul`、
`kernel_sort`。

建议 F1a acceptance（是待实现任务的门槛，不是当前结果）：

* 14 项在 `f1a` 与 `f0` 的提交序列、架构状态和内存副作用逐条一致；不新增 timeout。
* 每项 `retired_insn` 完全一致；`cycles_f1a <= cycles_f0*1.02 + 64` 作为无优化路径
  的回归护栏。超过护栏先关闭 F1a 定位，不把偶然 cycle 变化解释成收益。
* `fetch_fifo_peak<=2`、无 overflow/underflow；正常请求满足
  `accepted_req = nonstale_response + stale_drop + reset_cancel`，其中 `reset_cancel`
  只能在复位协议明确允许下出现。
* `nocache_d0/l1i_d0` 不要求必须加速；F1a 的直接验收重点是延迟/背压/flush 正确性。
  `mem_delay=1/2` 重点看不新增死锁、错配和超时。

建议 F1b acceptance：

* 无 fault 的 miss 中，`critical_word_available` 严格早于整行 response，实际 delta
  由 trace 给出；不得静态宣称固定周期收益。
* 最后 beat 成功前 `tag/valid=0`；任何 early-consumed word 后的 background fault 均不
  产生伪 IABT、不污染 line、不改变已提交架构状态。
* base/cache/delay2、MMU off/on、跨页/line、维护、IRQ、ERET 的 L2 完全通过；否则
  保持 F1b off，仅交付 F1a。

性能数据必须标注“Verilator 仿真代理，不是 A10/Fmax/架构签核”。

## 11. 回退、停止和默认关闭

以下任一条件都触发立即回退到 `FETCH_FIFO_ENABLE=0` 并保存失败现场：

* stale instruction/response/fault 进入 FIFO、IF/ID、commit 或 IABT merge；
* PC 跳过、重复、乱序，或 commit packet/QEMU `seq` 不一一对应；
* FIFO overflow/underflow、请求无响应、重复响应、MMU/I-L1 事务死锁；
* TLBI/IC invalidate/self-modify 后读到陈旧指令，或 MMU off/on、Device 属性错误；
* WFI/IRQ/ERET/系统排空期间年轻项提交、SP/NZCV/SPSR/ELR 错配；
* 任一现有 SVA 失败、现有 default-off 回归失败，或 14 项新增 timeout/性能护栏超标；
* F1b later beat fault 被误报为架构异常，或 line metadata 在最后 beat 前可见。

回退不是跳过测试：先复现并记录 fault image/trace，再以参数关闭 F1a/F1b 重跑同一
套餐，确认旧路径仍绿。默认关闭时必须满足：

1. `FETCH_FIFO_ENABLE=0` 继续使用现有单 context 逻辑，公共 request/response/commit
   layout、I-L1 full-line refill 和所有旧端口保持不变；
2. `FETCH_EARLY_RESTART_ENABLE=0`，即使误设置 FIFO 参数也不得提前发布 I-L1 数据；
3. debug 输出固定为 0 或不例化，不能改变架构周期/内存副作用；
4. F1a/F1b 不通过修改参考结果、关闭断言、跳过 QEMU 比较来回退。

## 12. 现有测试读证据与未来补口

本预研已只读核对以下与取指/维护/等待/异常相关的测试和入口：

| 文件 | 已有覆盖和引用 |
|---|---|
| `tb/sv/lcvex_l1_i_tb.sv:126-203` | I-L1 hit/miss、冲突、越界 fault、bypass、IC IVAU/IALLU |
| `tb/sv/lcvex_mmu_tb.sv:185-282` | TLB miss/hit、权限 fault、TLBI、MMIO 属性和 39-bit walk |
| `tb/sv/lcvex_core_tb.sv:217-330` | core commit/next-PC 以及系统 MSR/FP state smoke |
| `tb/sv/lcvex_commit_backpressure_tb.sv:257-367` | WB 和 ID system commit 的 ready 背压原子性 |
| `sim/cocotb/test_lcvex_core.py:162-224` | P2 trace → commit packet 逐条 PC/next-PC/寄存器/内存比较 |
| `sim/cocotb/test_commit_backpressure.py:60-200` | normal/system commit 在 ready=0 时保持、不丢不重 |
| `tb/sv/lcvex_cluster_tb.sv:260-377` | per-core reset/start、WFI/WFE/event/IRQ、重启 |
| `tb/sv/lcvex_c2_reset_fault_tb.sv:256-276` | 一核 reset 时另一核继续运行且无 fault/deadlock |
| `tb/sv/lcvex_c3_timer_tb.sv:116-179` | timer compare/IRQ 观测和 core fault 检查 |
| `sim/difftest/run_p5a.sh` | `p5a2_fetch` 分支 IABT、页末顺序 IABT |
| `sim/difftest/run_m2_4b.sh:36-44,107-154` | selfmod/TLBI/空流水线 fetch fault/MSR MMU-on，base+cache |
| `sim/difftest/run_p6_wfi.sh:22-42` | WFI/WFE/WFIT/WFET/timer IRQ，base+cache |

现有测试没有覆盖“取指 FIFO 满时 response backpressure”“flush 后人为延迟 stale response”
“reset/TLBI 同拍 response”或“critical word 后 later beat fault”。F1a/F1b 任务必须分别
新增这些定向测试，不能把现有通过数当成新契约已验证。

## 13. 可派发的下一步

集成者验收本文件后，可登记 F1a 实现任务：先按 §6 的 F1a-impl 写集落地，使用
`FETCH_FIFO_ENABLE=0` 做旧路径锚点，再逐步打开 depth=2；完成 §8 SVA、§9 L0-L2 和
§10 F1a acceptance 后，才允许登记 F1b safety gate。F1b 若无法满足 §7 的精确 fault
语义，应永久留在后续风险门，不影响 F1a 合入。
