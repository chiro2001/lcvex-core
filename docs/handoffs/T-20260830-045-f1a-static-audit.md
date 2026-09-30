# T-20260830-045 PE-F1A-STATIC handoff

```text
task=T-20260830-045 state=review
base=ab6e44f6de301a50dd8930b7e457ee6e4ba3d424 head=3d953e4a2dba1b255876ca520973d5c5b68d0198 content_sha=3d953e4a2dba1b255876ca520973d5c5b68d0198
branch=verify/T-20260830-045-f1a-static-audit worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-045
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-08-30T22:13:05+08:00 received_at=2026-08-30T22:33:14+08:00 reported_at=2026-08-30T22:47:26+08:00
files=docs/handoffs/T-20260830-045-f1a-static-audit.md; docs/tasks/evidence/T-20260830-045.json
reads=AGENTS.md; docs/MULTI_AGENT_WORKFLOW.md; T-045 JSON; F1 PREWORK/RESULTS; T-041/T-043 handoff/evidence/artifact; core/soc/fetch FIFO RTL-TB-Cocotb/run_f1a
tests=docs-only/static jq/text checks + git diff --check; no build/sim/QEMU/generator
hypotheses=H-01 likely kill/response ID; H-02 likely pop/IFID/data stall; H-03 confirmed fault-head consumer gap; H-04 confirmed commit-ready hold gap; H-05 possible maintenance double-kill
risks=无动态 first-trace 无法确认 H-01/H-02/H-05；公共 mem_rsp_t 无 ID；T-043 timeout 受 5M cycle 上限影响
evidence=docs/tasks/evidence/T-20260830-045.json
blockers=T-043 strict FIFO-on equivalence failed: 42/98 retired mismatches, 6 memory effect/count mismatches, 1 status mismatch; no unique root without T-044 first-trace
next=T-044 compare alu_latency negative control then fp_scalar/mem_seq first mismatch; register minimal RTL fix task only after trace confirmation
```

## 结论

本任务只做静态 RTL 因果审阅，没有修改 `rtl/`、`tb/`、`sim/`、workload、QEMU 或参考
结果，也没有运行生成器、构建、仿真或 QEMU。对 T-043 结果的严格口径是：

- measurement source=`b2b0a96894596ade51e8409fc7b9d4eb566cfe63`，7 个 base、14 个
  workload、196 rows，98 个 f0/f1a pairs；177 pass、19 timeout、0 fail；
- 严格字段为 `status + returncode + retired_insn + commit_digest + memory_digest`，
  只有 56/98 pairs 完全相同；retired mismatch=42，memory digest/effect-count
  mismatch=6，status mismatch=1，commit-only mismatch=0；
- 6 个 memory mismatch 精确为
  `fullcache_d1/neon_vect`、`fullcache_d2/neon_vect`、`l1i_d0/neon_vect`、
  `l1id_l2_d0/neon_vect`、`nocache_d1/mem_random`、`nocache_d1/mem_seq`；
  唯一 status mismatch 是 `nocache_d1/mem_random`（timeout/pass）；
- 负对照 `alu_latency`、`ctrl_branch`、`kernel_crc`、`kernel_hash`、
  `kernel_matmul` 在可完成的 pair 中保持 retired/commit/memory digest 等价；
  因而 FIFO 的一般 ring bounds 不是唯一可疑点，问题集中在 fetch 交付与数据/FP/
  vector/循环控制交界；
- T-043 的 perf runner 在收到 magic store 的 commit 时结束，而不是按固定退休数；
  因此 pass/pass 中的 retired 差不能用 5M cycle timeout 解释。memory digest 相同
  只说明提交的内存 effect 序列相同，不说明控制/无副作用指令序列相同。

所有以下 hypothesis 均是可证伪候选，不是动态根因确认。

## 1. enabled path 的源码因果图

```text
if_pc
  ├─ MMU-on: fetch_req_valid -> mmu_req_valid (data_req_valid 优先)
  │                         -> fetch_req_accept -> fetch_trans_busy/context
  │                         -> mmu_done -> fetch_translated/fetch_pa
  └─ MMU-off 或 translation complete:
       fetch_imem_req_valid -> imem_req_accept -> fetch_pending/context
                              -> imem_rsp_valid/ready
                                   ├─ current response -> FIFO push
                                   └─ stale/kill response -> consume/drop

FIFO count/head/tail
  └─ fetch_fifo_pop -> IF/ID load -> ID/EX/WB/COMMIT
       ├─ ordinary sequential: ifid advances, tail issue may continue
       ├─ branch/exception/system/IRQ/WFI/TLBI/IC/restore: frontend_kill
       │       -> FIFO clear + epoch bump + in-flight fetch quarantine
       └─ fetch fault head: pop blocked, but no architectural fault consumer
```

关键组合条件和时序如下：

| 阶段 | 当前条件/状态 | 因果关注点 |
| --- | --- | --- |
| fetch translation issue | `fetch_req_valid`（`rtl/lcvex_core.sv:1274-1283`）要求无 fetch/data pending、`!mem_busy`、`!flush_id`、`!frontend_kill`、FIFO 有空间；`mmu_req_valid=data_req_valid||fetch_req_valid`，data 通过 `fetch_req_accept` 被排除（`1249-1304`）。 | 保持 MMU 单在途；data translation 与 fetch translation 的同拍选择决定 stall。 |
| IMEM issue | `fetch_imem_req_valid`（`1748-1758`）选择翻译后的 PA 或 `if_pc`，同样阻止 stale/kill/FIFO full；`imem_req_accept` 只代表普通 fetch，不含 maintenance（`1770-1781`）。 | FIFO on 仅在 request fire 时将 `if_pc += 4`（`2423-2439`）；FIFO off 仍在 capture 时推进。 |
| current response | `fetch_imem_rsp_current` 要求 `fetch_pending && fetch_ctx_epoch==fetch_epoch && !frontend_kill`（`826-834`）；`imem_rsp_ready` 在 kill/stale 时强制 1，否则仅 pending 且有 FIFO space（`1773-1778`）。 | 无公共 response ID，归属依赖单 context+epoch；同拍 kill/response 是关键边界。 |
| FIFO push | `fetch_fifo_push` 接 current IMEM response、MMU fault 或 held `fetch_fault_pending`（`835-884`）；push 保存 epoch/seq/VA PC/insn/fault/FSC。 | FIFO fault push 后必须有 fault head 的架构消费；当前没有。 |
| FIFO pop | `fetch_fifo_pop` 要求非 kill、非 stale、`commit_ready`、非 system/data wait/load-use/EX busy/WB/dmem pending、count 非零且非 fault head（`812-821`）。 | 它是独立展开的 `stall_if` 近似式，不直接绑定 `ifid_valid` 或 `stall_if`；边界不对称见 H-02/H-04。 |
| FIFO ring update | flush 清 valid/head/tail/count；否则先 pop，再 push，count 按 `{push,pop}` 更新；count=2 时 push+pop 覆盖被 pop 的 tail=head slot（`rtl/lcvex_core.sv:1997-2065`）。 | ring bounds SVA 只查 count≤2，未查 entry order、PC 连续性或 pop 与 IF/ID 的语义一致。 |
| IF/ID load | FIFO on 的 IF/ID 在事件清除、`stall_if` 保持、`fetch_fifo_pop` 时装 head，否则 `ifid_valid<=0`（`2564-2578`）。 | `pop=0 && stall_if=0` 会丢 IF/ID；fault head/commit backpressure 是已确认条件缺口。 |
| ID/EX/data | `stall_id` 包含 load-use、FP load-use、system/exclusive hold、data translation、fetch walk/stale 和 EX/MEM 不可前进（`1728-1735`）；ID/EX 只在 `trans_done_for_ifid` 时接收 MMU-on load/store（`2594-2606`）。 | data translation 修复只绑定 `trans_done_pc_r==ifid_pc`，不是 fetch epoch/seq；需看同拍 FIFO pop/translation。 |
| PC/epoch | FIFO on 的 `if_pc` 在 IMEM request fire 时加 4；redirect/commit/IRQ/WFI/flush 取优先级（`2423-2439`）。`frontend_kill` 聚合 branch/system/exception/IRQ/WFI/TLBI/restore/maintenance start（`795-801`）。 | 每个 kill 使 epoch 加一并清 FIFO；`seq` 只在 fetch request fire 分配（`2453-2482`）。 |
| stale drain | kill 时若 fetch translation/IMEM 仍在途，分别置 `fetch_stale_mmu/imem`；随后任何 `mmu_done`/IMEM response 清 stale，`fetch_stale_drain` 期间禁止新请求（`1956-1994`、`1274-1282`、`1748-1758`）。 | 没有公共 ID，任何路由/同拍边界误判都会把 response 归错；T-044 必须记录 stale/drop 事件。 |

### 1.1 同拍交互审计

1. **push+pop**：count=1 时 head/tail 不同，旧 head 装入 IF/ID、新 response 写另一
   slot；count=2 时 head=tail，非阻塞写顺序为 pop 后 push，语义上应保持两项。但当前
   没有 assertion 证明新 slot 的 PC/epoch/seq 继承正确，也没有把 IF/ID 的接受条件
   与 pop 做成同一个 fire。T-044 应比较 `fifo_pop/push/count/head/tail` 与连续 PC。
2. **flush+IMEM response**：`frontend_kill` 优先于 `fetch_imem_rsp_current`，同时
   `imem_rsp_ready=1`；响应只能计为 stale drop，pending 在主时序块清零，epoch block
   记录 stale flag（`826-844,1773-1778,1971-1994,2442-2492`）。delay0 常表现为
   同拍 drop，delay1/2 常表现为后续 stale drain。公共 `mem_rsp_t` 无 ID，故只能依赖
   单在途假设；若 T-044 first mismatch 不在 kill/drop 窗口，应排除该候选。
3. **MMU/data/IMEM**：data request 在 MMU 输入上优先；fetch translation 只有在
   `!data_req_valid` 的 accept 才锁存。T-041 增加 `data_wait_for_translation` 和
   `trans_done_pc_r`（`1254-1271,2360-2405`）以避免 fetch `mmu_done` 同拍让 IF/ID
   data op 未翻译就进入 EX/MEM；仍需检查 FIFO pop 是否与 `trans_done_for_ifid`、
   `ifid_valid` 同拍改变。
4. **dmem/mem_busy/stall**：`fetch_req_valid` 明确检查 `!mem_busy`，而 pop 展开式
   只显式检查 `!dmem_pending`、`!stall_wb`、`!ex_busy` 等，不直接检查 `mem_busy` 或
   `stall_if`（`812-821` 对比 `1728-1735`）。已完成 dmem response 时 `mem_busy` 仍
   可由 EX/MEM valid 保持，但 EX/MEM 可前进；该差异需要 T-044 用当拍 EX/MEM/dmem
   state 排除，不能仅凭最终 memory digest 判断安全。
5. **stalls**：IF/ID 由 `stall_if` 保持，但 FIFO pop 由独立条件计算；两者在正常
   load-use/data translation/EX busy 条件大多等价，在 `commit_ready=0` 和 fault head
   明确不等价。FIFO on 的 prefetch 可以在 `commit_ready=0` 时填满队列，但不能改变
   IF/ID/commit 语义。

## 2. kill/redirect/错误路径矩阵

| 事件 | 当前 `frontend_kill`/epoch | FIFO/IFID 动作 | 静态结论 |
| --- | --- | --- | --- |
| taken branch (`flush_id`) | kill=1，epoch+1 | FIFO 清零，pending/translated context 清零；同拍 response 消费/drop；branch 本身仍由 ID/EX 接收。 | 正常条件下 wrong-path entry 不应 commit；需 T-044 检查 kill 同拍边界。 |
| UDEF/SVC/IABT/DABT/fetch merge | `sys_commit`/`fetch_merge_wb`/`wb_exc_commit` 进入 kill | older commit 先完成，IFID/FIFO 清除；fault merge 仍使用 scalar `fetch_faulted`。 | FIFO fault head 没有进入该 merge，见 H-03。 |
| system redirect/ERET/MSR/barrier | `sys_fetch_redirect` 或 `sys_commit` kill | held system target 不进入 FIFO 后再无条件 commit；commit 时重定向。 | `sys_fetch_redirect` 与 maintenance start/commit 可能连续 kill，见 H-05。 |
| IC IVAU/IALLU/TLBI | TLBI/maintenance start/commit kill | stale MMU/IMEM 由 local quarantine；TLBI 让 MMU 清 TLB/中止 walk。 | epoch 只在 core 内；公共 response 无 ID。 |
| ordinary IRQ / WFI wake | `irq_taken`/`wfi_irq_take`/`wfi_wake` kill | 清 FIFO/IFID，向量或 `wfi_pc+4` 重新取指；异步 IRQ packet 仍单提交。 | 需 trace 检查 IRQ 前年轻项是否已 pop。 |
| reset/restore | `difftest_restore_sys_valid` kill（restore strobe）或 async reset | core pending/FIFO/IFID 清；FIFO epoch 不在 restore 分支显式归零。 | restore epoch/共享 endpoint quarantine 仍是协议缺口。 |
| fetch fault | push fault entry；`fetch_fifo_head_fault` 阻止 pop/issue | 当前 `sys_at_id` 不读取 FIFO fault，IFID block 也不因 head fault stall。 | 这是静态确认的 timeout/deadlock 缺口。 |

## 3. T-043 模式解读

T-043 结果和 artifact hash 见 `docs/PERFORMANCE_F1_RESULTS.md:49-81,83-101`、
`docs/tasks/evidence/T-20260830-043.json:213-258`、
`docs/evidence/artifacts/T-20260830-043/f1c_matrix.json`。f1a 全部 row 的 occupancy/
peak≤2、overflow=0，只证明环计数边界，不证明退休序列。

### 3.1 等价负对照

`alu_latency`、`ctrl_branch` 的主要循环是寄存器/控制流；`kernel_crc`、`kernel_hash`、
`kernel_matmul` 虽含访存，但在该矩阵中可完成 pair 的 retired、commit digest、memory
digest 仍相同。它们说明：

- 单纯“FIFO 能 push/pop”或所有 taken branch 都会出错的解释不成立；
- 只有在特定 response/数据 stall/FP-vector/循环控制交界触发的候选才有优先级；
- delay1/2 的等价结果可能是时间窗口被改变或 stale drain 遮蔽，不是对 delay0/cache
  的修复证明。

### 3.2 非等价类别

`mem_seq`、`mem_ldst`、`mem_random`、FP 标量/FP16、NEON、sort 在 delay0/cache 组合
中反复出现多退休；delay1 无 cache 多数恢复，但 `mem_seq/mem_random` 仍 timeout 或
非等价；fullcache delay1/2 仍有 data/FP/NEON/sort mismatch。该形状与以下源码边界
相符：

- `mem_seq`/`mem_ldst` 的 loop body 由 load-use、store、LDP/STP 和计数分支交错；
- `kernel_sort` 的 insertion-sort `while (j>0 && arr[j-1]>key)` 使额外 branch/compare
  可能不改变最终写入摘要，却会改变退休数；
- FP/NEON workload 含 CPACR system commit、FP/NEON 状态/向量 load/store 和大量
  loop branch；NEON 的 6 个 memory mismatch 进一步要求比较 memory effect 的第一处；
- microbench runner 在 magic store commit 结束；同 memory digest 但 retired 增加可
  是额外 branch/compare/no-op，不能先判定为重复 store；memory effect/count mismatch
  则优先怀疑错误路径上的实际 load/store 或 vector pair effect。

## 4. 排序后的 hypothesis（无动态根因确认）

### H-01：kill 同拍响应/无 ID 的错误归属（`likely`，与 T-043 高相关）

- **源码条件**：`frontend_kill` 把 `flush_id/sys_commit/...` 聚合为单拍 kill
  (`rtl/lcvex_core.sv:795-801`)；`fetch_imem_rsp_current` 在 kill 时强制为 0
  (`826-834`)，`imem_rsp_ready` 却强制为 1 (`1775-1778`)，epoch block 同时根据
  `imem_rsp_valid && ready` 决定 stale flag (`1971-1994`)，主时序清 pending/context
  (`2442-2492`)。公共 `mem_rsp_t` 没有 response ID/PC，只靠单 pending context。
- **预期 T-044 first-trace signature**：f0/f1a 在 `seq=k-1` 相同；f1a 的第一处分歧
  邻近 `fetch_fifo_flush=1`、`fetch_epoch` 加一和 `fetch_stale_rsp_drop=1`（delay0
  同拍）或 `fetch_stale_drain=1` 后 drop（delay1/2）。随后 f1a `PRE/COMMIT` 的
  `pc/insn/next_pc` 出现 skip、重复或 sequence shift；若 memory effects 仍相同而
  retired 增加，可能是额外 branch/compare。
- **排除条件**：第一处分歧前后没有 kill/flush/stale/drop，且 FIFO entry PC/epoch/seq
  连续；或在固定 response ID/源端点审计中确认 response 与唯一 pending 完全匹配。
- **最小修复写集**：若 local core 逻辑足够，仅 `rtl/lcvex_core.sv` + F1a directed
  SV/Cocotb；若 T-044 证明无 ID 归属不足，则登记独立协议任务写
  `rtl/lcvex_pkg.sv`、`rtl/lcvex_l1_i.sv`、`rtl/lcvex_mmu.sv`、`rtl/lcvex_mem_arb.sv`
  及 delay/RAM 端点，禁止在本任务修改。
- **新增测试**：可控 response 延迟在 branch flush 同拍、flush 前一拍、flush 后一拍
  返回；检查 `rsp_fire` 恰一次、stale 不 push、PC/epoch/seq 连续，覆盖 d0/d1/d2、
  I-L1/cache。

### H-02：FIFO pop 与 IF/ID/stall 的边界不原子（`likely`，与 memory/NEON 高相关）

- **源码条件**：pop 使用独立展开式 `rtl/lcvex_core.sv:812-821`，IFID 更新使用
  `stall_if` 再判断 pop (`2564-2578`)，而 `stall_if/stall_id` 的真实集合在
  `1728-1735`；pop 不直接检查 `ifid_valid`、`mem_busy` 或 `stall_if`。data wait、
  `trans_done_for_ifid` 与 ID/EX 接收在 `1260-1271,2594-2606` 交互。静态上，已完成
  dmem response、load-use 或翻译同拍是最值得 trace 化的边界；不能仅凭 `!dmem_pending`
  断言安全。
- **预期 T-044 first-trace signature**：第一处分歧邻近 `LDR/STR/LDP/STP` 或 NEON
  load/store，f1a 记录 `fetch_fifo_pop` 与 `dmem_pending/mem_busy/data_wait_for_translation/
  load_use` 交界；候选错误形状为 `pop=0 && stall_if=0` 时 IFID valid 掉落、PC 跳过，
  或 `pop=1` 与仍驻 EX/MEM 的 data op 同拍。6 个 memory mismatch 应在 memory effect
  首次出现地址/strb/count 差异时被该 signature 支持或排除。
- **排除条件**：first mismatch 是纯 ALU/branch，且 IFID valid/PC/insn 在该窗口保持；
  或 `stall_if` 与 pop 每拍完全同值、EX/MEM 可前进且 data effect 逐项一致。
- **最小修复写集**：`rtl/lcvex_core.sv`，配套 `tb/sv/lcvex_fetch_fifo_tb.sv`、
  `sim/cocotb/test_fetch_fifo.py` 或新 data/FIFO directed TB；不要扩大到公共 memory
  ABI，除非 trace 证明需要 transaction ID。
- **新增测试**：FIFO count=0/1/2 下 push+pop 与 IFID 消费；dmem response 当拍、
  load-use、FP load-use、LDP/STP/NEON pair、`commit_ready` backpressure；逐条比较 PC、
  retire count 和 memory effect。

### H-03：FIFO fault head 没有架构消费路径（`confirmed` 条件缺口，主要解释 timeout）

- **源码条件**：fault entry 可由 IMEM/MMU fault push (`rtl/lcvex_core.sv:835-884,2459-2469`)，
  `fetch_fifo_head_fault` 只在 `fetch_fifo_pop` 和 F1a SVA 使用
  (`803-806,812-819,4127-4129`)，而 `sys_at_id` 只看 IFID decode/dabt/system op
  (`1690-1717`)；FIFO IFID 装载在 fault head 时因 `pop=0` 且通常 `stall_if=0` 进入
  `ifid_valid<=0` (`2564-2578`)。没有代码把 fault head 转为 `fetch_faulted`、IABT
  merge 或 fault commit。
- **预期 T-044 first-trace signature**：f1a 先出现 `fetch_fifo_push_fault=1`（若该
  debug 字段未导出，则 `fetch_fifo_head_fault=1,count>0`）；随后 `fetch_fifo_pop=0`、
  `fetch_req/imem_req_accept=0`，IFID 无 fault entry，长期无下一 commit，runner 只
  能 timeout。该候选不应解释无 fault 的 pass/pass retired mismatch。
- **排除条件**：first timeout/trace 窗口没有 fetch fault entry，或 fault 在 FIFO 外由
  旧 `fetch_faulted/fetch_merge_wb` 路径正确提交。
- **最小修复写集**：`rtl/lcvex_core.sv`；需要将 fault head 明确映射到 fault merge/ID
  fault entry，并新增 `tb/sv/lcvex_fetch_fifo_tb.sv`、`sim/cocotb/test_fetch_fifo.py`
  的 MMU fault/IMEM fault/flush 后 fault 测试；不在本任务实现。

### H-04：`commit_ready=0` 时 pop 被禁但 IFID 未必保持（`confirmed` 条件缺口，独立于 T-043）

- **源码条件**：`fetch_fifo_pop` 明确含 `commit_ready` (`rtl/lcvex_core.sv:812-819`)，
  但 FIFO IFID 分支只在 `stall_if` 时保持，未直接含 `!commit_ready`
  (`2564-2578`)。当 `commit_ready=0`、`memwb_valid=0`（因而 `stall_wb=0`）、无其它
  stall、FIFO count>0 时，pop=0 且 stall_if=0，IFID valid 会被清零并可能跳过当前项。
- **预期 T-044 first-trace signature**：在 `commit_ready` 下降后的第一个窗口，
  `fifo_count>0,pop=0,stall_if=0,ifid_valid:1→0`；恢复 ready 后第一条 PRE/COMMIT
  缺少原 IFID PC 或出现 PC 跳跃。T-041 skeleton 只检查 branch/target 和“ready=0 不
  commit”，未检查完整 post-backpressure 序列。
- **排除条件**：`memwb_valid && !commit_ready` 持续使 `stall_wb/stall_if=1`，或 first
  window FIFO count=0/IFID 已无有效项；T-043 microbench `commit_ready` 恒 1，不能将
  H-04 作为其直接根因。
- **最小修复写集**：`rtl/lcvex_core.sv` + fetch FIFO SV/Cocotb；增加 ready 下降时
  IFID/FIFO/PC/commit packet 全保持的 assertion 和多项后续指令检查。

### H-05：maintenance/system redirect 产生重复 kill/epoch（`possible`，边界性）

- **源码条件**：`frontend_kill` 同时包含 maintenance start
  `(sys_maint_at_id && maint_state==MS_IDLE)` 和 `sys_commit/tlb_invalidate/sys_fetch_redirect`
  (`rtl/lcvex_core.sv:795-801,1438-1455`)；maintenance FSM 在 ID 期间从 MS_IDLE 转
  MS_DONE/REQ (`3935-4031`)，随后 system commit 又成立。单个 TLBI/IC maintenance
  可能看到 start kill 和 commit kill 两个周期，各自使 epoch+1、flush counter+1。
- **预期 T-044 first-trace signature**：system/IC/TLBI/ERET PC 附近两个相邻周期
  `fetch_fifo_flush=1` 且 `fetch_epoch` 连续加二，FIFO 清空两次；随后 target fetch
  request/PC 可能重发。无该类 system op 的 FP/memory first mismatch 应排除。
- **排除条件**：维护 FSM 状态和 trace 只出现一次统一 kill，或 workload 没有维护/系统
  redirect；当前 T-043 perf FP 只有 CPACR MSR，不等同于 MAINT。
- **最小修复写集**：`rtl/lcvex_core.sv` + maintenance/TLBI/IC directed SV/Cocotb
  与 lockstep；将一次架构 redirect 聚合为一次 kill，不能只修改 counter。

## 5. 修复和验证边界

本静态任务不修 RTL。T-044 首先应使用 `alu_latency` 做 trace instrumentation 负对照，
再短跑 `fp_scalar`（历史 +2 retired）和 `mem_seq`（历史 +10 retired），记录 first
mismatch 前后有限窗口：`seq,pc,insn,next_pc,gpr/sp/nzcv,mem effects,exception,
fetch_epoch,fetch_fifo push/pop/flush,stale_drop/stale_drain,occupancy`。若观测端口不足，
报告缺口而不扩写集。

根据 first signature 选择后续任务：

- H-01：先登记 response identity/quarantine 或 local kill fix；
- H-02：先登记 FIFO/IFID/data-stall 原子性 fix；
- H-03：单独登记 FIFO fault merge，避免用 timeout 误判性能；
- H-04：登记 commit-ready frontend hold 回归；
- H-05：登记 maintenance kill 聚合回归。

任何后续 fix 必须保持 `FETCH_FIFO_ENABLE=0` 默认旧路径、公共 commit ABI 和 QEMU
reference 不变；同一 source SHA 上重跑受影响 L0-L2，不能把 T-041 12/12 directed
lockstep 当成 T-043 14-workload 等价。

## 6. 最终判断

状态保持 `review`。静态审阅确认了至少两个条件级 correctness gap（H-03/H-04），并
给出了与 T-043 模式相符的 H-01/H-02 候选和边界性 H-05；在 T-044 first-trace 到达前，
不能声称唯一根因、不能开启 FIFO 性能签核、不能登记“已修复”。

`content_sha/head_sha=3d953e4a2dba1b255876ca520973d5c5b68d0198` 表示技术审计内容提交；
evidence 自引用不能预写其后 metadata commit 的最终 tip，owner FINAL 的 `head` 才是
最终 branch tip。
