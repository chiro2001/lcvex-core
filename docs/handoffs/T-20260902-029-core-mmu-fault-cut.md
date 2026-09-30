# Handoff T-20260902-029: core/MMU fault-status register cut

```text
task=T-20260902-029
state=review
base=896fc46fb4c18d85c0a91c3844c27cd7c0298cbd
head=4b593ba2045d47dabcccb1dfa028d11cac25b4ce
branch=fix/T-20260902-029-core-mmu-fault-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-029
sent_at=2026-09-03T19:20:30+08:00
received_at=2026-09-03T19:20:45+08:00
reported_at=2026-09-03T19:36:05+08:00
```

## 结论

- 对 `rtl/lcvex_mmu.sv` 做了定向寄存器切级：MMU 请求接收（`S_IDLE`）
  只锁存 `req_va_r/req_is_insn_r/req_is_write_r/req_el_r/req_pan_r`，
  新增 `S_EVAL` 状态在下一拍用锁存后的请求做 TLB/权限/直通/区域判定，
  并产生 `paddr_r/fault_r/fault_fsc_r` 等结果。
- 这样从 `idex_d.inv_b` 等 core 前递/地址组合路径到 `mmu|fault_fsc_r` D 端
  的同一拍组合链被一个寄存器边界打断：原路径现在是
  `idex_d -> (ALU/前递/译码地址) -> mmu req_va_r 寄存器` 和
  `mmu req_va_r -> (TLB/权限) -> fault_fsc_r 寄存器` 两段。
- 架构行为未改变：同步异常优先级、ESR/DFAR/IFAR/PC、MMU fault 类型、
  异常返回地址、缓存/内存/页表语义、TLBI 和复位行为都不动。
  唯一影响是 MMU 所有翻译（TLB hit/直通/页表遍历）增加 1 个结果周期，
  由 core 已有的翻译冻结/等待逻辑吸收。
- 本地验证通过：`make compile`、`make sim-sv`、`make sim-sv-mmu`，
  以及 QEMU trace + Cocotb core 差分 `sim-cocotb-core`
  （33 条指令与 QEMU 完全一致）。未跑 A10 full-FP synthesis/fitter/STA
  与锁步 `p6-maint-v82*`（重型 FPGA/锁步队列）。

## 修改文件

- `rtl/lcvex_mmu.sv`

## 切级理由

T-20260902-028 的 FP-P5 STA top-1 为
`soc|core|idex_d.inv_b~DUPLICATE` → `soc|core|mmu|fault_fsc_r[2]`，
61 逻辑级、data delay 34.564 ns。该路径根因是 ID/EX 的 ALU 结果通过
core 前递视图进入 IF/ID 译码地址，再直连 MMU 请求输入，并在 MMU 内部
同一拍完成 TLB/权限判定后打到 `fault_fsc_r` 的 D 端。

本提交把 MMU 的请求采样与结果判定拆成两拍：请求先进入 `req_va_r` 等
锁存器，下一拍才从这些锁存器计算 fault/paddr。这样 MMU 内部 TLB/权限/
FSC 组合逻辑的起点不再是 core 的来源寄存器 Q，而是 MMU 自己的已锁存
请求 Q，从而切断跨模块的长组合链。

## 语义保持

- `fault_fsc` 仍按原格式生成：翻译 0x04+level、AF 0x08+level、权限
  0x0C+level、地址大小/外部中止 0x00/0x10；只延后一个周期输出。
- `fault`/`paddr`/`cacheable`/`par_attr`/`par_sh` 均随 `done` 一起延后，
  core 在 `mmu_done` 周期采样，不需要新的握手或对齐改动。
- 页表遍历起始级别、TTBR0/TTBR1 区域选择、PAN 权限均改用已锁存的
  `req_va_r/req_el_r/req_pan_r`，与原先输入锁存语义一致。
- `tlb_invalidate` 仍优先中止在途遍历并清 busy，不受 `S_EVAL` 影响。
- 不引入猜测执行，不改异步复位。

## 验证记录

| 项目 | 结果 |
| --- | --- |
| `make compile` | PASS |
| `make sim-sv` | PASS |
| `make sim-sv-mmu` | PASS |
| `make difftest-rtl`（QEMU trace + `sim-cocotb-core`） | PASS：33 条指令与 QEMU 一致 |
| `git diff --check` | PASS |

未运行：
- A10 `real_a10_full_fp` full-FP synthesis/fitter/signoff STA（远端/专业 EDA 队列）。
- `p6-maint-v82` / `p6-maint-v82_mmu` 锁步子集（重型锁步队列）。

## 下一步

1. 集成者/FP-P5 复跑确认该切级后的 STA top 是否仍落在
   `idex_d -> mmu req_va_r` 或 `idex_d -> idex_d.mem_addr` 等地址生成段。
2. 若仍有红色，建议下一轮对 ID/EX ALU 结果到 IF/ID 前递做显式寄存器切级
   /依赖停顿（本任务未采用，避免破坏现有前递/控制流语义）。
3. 继续处理 EMIF async FIFO 灰码 setup/hold 的红项（T-028 下一步 2/3）。
