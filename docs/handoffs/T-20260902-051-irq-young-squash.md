# Handoff T-20260902-051：ordinary IRQ 年轻级/事务排空

```text
task=T-20260902-051
state=review
base=80de28596a33c900ab0f73daa7a19ce3a4ef341b
head=da47a8032dc3cbba0f7fad3dfa2f296163821bc7
branch=fix/T-20260902-051-irq-young-squash
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-051
sent_at=2026-09-04T14:15:18+08:00
received_at=2026-09-04T14:15:20+08:00
reported_at=2026-09-04T17:06:30+08:00
files=rtl/lcvex_core.sv; rtl/lcvex_mmu.sv; tb/sv/lcvex_irq_young_squash_tb.sv; tb/sv/lcvex_mmu_tb.sv; docs/handoffs/T-20260902-051-irq-young-squash.md; docs/tasks/evidence/T-20260902-051.json
tests=compile; MMU unit; IRQ FIFO/delay matrix; core/backpressure/FIFO/NEON SV; FP/NEON Cocotb; rebuilt strict QEMU IRQ/WFI/LSE/FP/NEON lockstep
blockers=无；自然 QEMU CASP/STXR/DC ZVA overlap 与 Quartus/STA 仍为后续验证
next=集成者在合并 SHA 重跑任务 L0-L2 并补 merge_sha；另登记自然原子 IRQ overlap 回归
```

## 结论

已修复普通 `irq_taken` 在老 MEM/WB 提交边界遗漏年轻级/事务的问题，且没有把
已经接受的不可回滚写请求直接丢掉：

1. 新增组合保护 `irq_irrevocable_pending`。EX/MEM 中已接受的普通写、STXR/LSE
   条件写、STP/Q/CASP 分相写、维护/DC ZVA 写，以及已完成第一半但尚未完整提交
   的写事务都会让 IRQ 保持 pending，直到该事务到达 exactly-once 提交边界。无
   kill 端口的 mul/div 在 `done` 前也作为 fence；完成拍可被 IRQ 安全冲刷，不会
   丢失未提交结果。
2. 当 IRQ 边界确实可取走时，`irq_taken` 同拍抑制 FIFO-off/on 的取指、数据和
   maintenance request，清空 IF/ID、ID/EX、EX/MEM、MEM/WB valid/token，并清除
   dmem issued/done、pair/atomic phase、translation result/pending、maintenance
   状态和 FP owner；已在途的读响应仍由既有 ready 通道消费后丢弃。普通 IRQ 同拍
   使用 MMU 独立的 `abort` 输入，取消当前 walk 但不清理既有 TLB；FIFO-on 继续
   使用 frontend kill/epoch/stale quarantine，FIFO-off 清除 legacy fetch context。
3. MMU 在尚未接受 PTW 的请求态直接回空闲；已接受 PTW 的响应态进入
   `S_ABORT_WAIT`，保持 `ptw_rsp_ready` 消费迟到响应并丢弃，不产生 `done/fault`。
   这避免复用整表 TLBI 造成既有 TLB 丢失，也避免 mem_arb 被遗留 response 堵塞。
4. MEM/WB 在 younger `dmem_pending` 时的 `memwb_committed_r` 防重提交逻辑统一
   作用于 FIFO on/off，避免 IRQ 延后期间老条目重复提交。
5. FP access sample 在老 MEM/WB FP/NEON effect 与年轻 IF/ID FPEN trap 同拍时优先
   归属老提交；年轻 trap 留在 IF/ID，下一独立系统提交边界重新检查，不会抑制老
   V/FPSR effect。

未新增架构寄存器或持久状态。`irq_irrevocable_pending` 为组合判定，reset 值、
读写权限和提交时机均不适用；既有 pipeline/transaction flags 仍按原 reset 值，
仅在 ordinary IRQ kill 或对应正常完成/提交沿清除。IRQ 仍要求
`irq_pending_raw && commit_fire`，而 `commit_fire` 自带 `commit_ready`，所以
`commit_ready=0` 时不可能 `irq_taken`。WFI/WFE、`wfi_irq_take` 和 `sys_irq_taken`
保持原独立排空路径；未扩展 FIQ、nested IRQ、DAIF/ERET/WFI 语义。

## 定向验证

`tb/sv/lcvex_irq_young_squash_tb.sv` 通过已有 SoC SRAM/延迟模型在 FIFO off/on ×
delay 0/2 四配置串行运行。每个配置覆盖：

- 真实 ID/EX ordinary ALU 与 NEON integer young stage；
- 未接受的 younger store（IRQ 同拍无 request/accept）；
- 先让真实 store write request 接受，再确认 `irq_irrevocable_pending` 阻止 IRQ；
- held scalar FP response/FP owner kill；
- mul/div mid-run fence 与 done 后 IRQ commit；
- 自然数据 MMU page-walk 在 PTW 已接受后注入 IRQ，检查 `mmu_abort`、TLBI 不误触发、
  response quarantine 排空及无伪造 `done/fault`；
- IRQ packet PC/next-PC/EXC_IRQ、ELR、EL1h/DAIF/NZCV/SP 边界，以及 stage valid、
  dmem accept/write、FP effect、旧 token 清除。

该 TB 在 FIFO-off 的自然弹性节奏没有老 WB 与每一种 younger 事务同时驻留的窗口；
为直接检查该边界，store/FP/NEON fixture 仅在当前没有老 WB 时对 `commit_fire` 和
老 WB metadata 做单拍 testbench 注入，RTL request/response、transaction 和 IRQ
优先级仍由真实流水驱动。不可逆 store 另有真实 request-accept guard；该 fixture
不改变参考结果，也不跳过断言。

## L2/回归结论

精确命令、版本、退出码和 source/artifact hash 见
[`docs/tasks/evidence/T-20260902-051.json`](../tasks/evidence/T-20260902-051.json)。
通过内容包括：

- core compile、core smoke、commit backpressure、FIFO/epoch、MMU SV unit；
- scalar FP Cocotb 5/5、NEON Cocotb 10/10、NEON FP SV raw unit；
- QEMU 11.1.0 strict step：`hard_irq`、`hard_irq_daif` base，`hard_irq` cache/
  delay2，WFI timer base/cache，LSE atomic base，scalar FP/NEON FP required lockstep。

所有 Verilator 构建/运行均使用
`systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0`，且
`VERILATOR_JOBS=1` 或 Verilator `-j 1`；未运行 Quartus、assembler、SOF 或修改
QEMU fork。QEMU binary/plugin 仅只读复用。

## 边界与后续风险

- `lcvex_mmu` 本任务新增独立 `abort` 输入，在 IRQ 同拍取消当前 walk；TLB 只由维护指令的 `tlb_invalidate`
   清空。已接受 PTW 仍是必须消费的读侧协议事件，由 `S_ABORT_WAIT` quarantine
   完成排空；`data_trans_active/trans_done_flag/dabt_pending` 及物理结果仍由
   core kill 清除，使迟到响应不会产生 `mmu_done` 或 IRQ 后 DABT。
- 原子和 maintenance 的完整自然 IRQ overlap 矩阵尚未由 QEMU 注入覆盖；现有 LSE、
  MMU、maintenance 和本次 core fixture 分别覆盖分相/故障/请求边界，合并后应在
  Gate D candidate 再做一次综合矩阵。
- 未运行 Quartus/STA；任何后续物理候选需在合并 SHA 复查时序。

下一步：集成者 cherry-pick `884578fd0d9a8d9dfe221cdd69f63ff05ed4e943`、
`879ef70e6e824ebc63d648d54bc402a681213221` 和
`da47a8032dc3cbba0f7fad3dfa2f296163821bc7` 及本 handoff/evidence；若要补齐
QEMU 自然原子 overlap，另登记 regression task。
