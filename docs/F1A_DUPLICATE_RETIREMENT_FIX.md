# F1a duplicate retirement 修复

任务：`T-20260830-046`（PE-F1A-FIX）

## 结论

F1a 的重复退休根因是 MEM/WB 的 `memwb_committed_r` 在 younger 数据访存仍处于
`dmem_pending` 时没有被置位。此时 older MEM/WB 条目已经产生一次 commit，但由于
数据事务冻结，MEM/WB 仍保持有效；下一拍 `commit_fire` 再次看到同一条目，造成连续
重复退休。问题不在 FIFO push、IFID 接收或 EX/MEM token 转移。

修复只在 `FETCH_FIFO_ENABLE=1` 时把 `dmem_pending` 纳入已提交标记条件；FIFO 关闭的
legacy 路径和公共 commit packet 不变。修复提交为
`c86329e46da5d2adec261ec4c235a214866b1075`。

## 根因复现

同一 `mem_seq` 镜像、1000-cycle 独立 runner 诊断得到：

| 配置 | retired | trace SHA256 |
| --- | ---: | --- |
| f0 (`FETCH_FIFO_ENABLE=0`) | 261 | `e3b4aba26e838291ad5a87776a65c95fc2044631b869d2fd371329f5c4122901` |
| f1a (`FETCH_FIFO_ENABLE=1`) | 319 | `2715fd538a9e44a12b32935ef8ab5fb184ccdfedf0466c938e07de50be9f1c82` |

pre-fix probe 的关键窗口为：

- cycle 43：FIFO head `(epoch=3, seq=18, PC=0x44000108)` 只发生一次 pop；
- token `(3,17, PC=0x44000104)` 在 IFID、IDEX、EXMEM、MEMWB 各只转移一次；
- cycle 47、48：MEM/WB token `(3,17)` 连续两次 commit；两拍间没有新的
  EXMEM→MEMWB transfer，`dmem_pending=1`，`memwb_committed_r=0`；
- 因而最早坏点是 MEM/WB commit hold，而不是 FIFO entry 重复产生。

独立最小镜像为 `ldr; ALU; ldr` 窗口：前一条 load 后的 ALU 进入 MEM/WB，后一条
load 在 EX/MEM 等待数据响应。pre-fix 产生同一 ALU token 连续三拍 commit；post-fix
只产生一次，且 commit 后 `memwb_committed_r=1`。

## 实现与状态契约

RTL 在 `rtl/lcvex_core.sv` 增加了仅用于 F1a 诊断的 `(epoch, seq)` token，并随
IFID→IDEX→EXMEM→MEMWB→commit 传播。token 不进入架构状态或 commit packet。

| 状态 | reset 值 | flush/restore | 更新时机 |
| --- | --- | --- | --- |
| IFID/IDEX/EXMEM/MEMWB valid | `0` | 清 `0` | 正常 transfer 或 bubble |
| 各级 token epoch/seq | `0/0` | 清 `0/0` | 对应级捕获新 token |
| `memwb_committed_r` | `0` | 清 `0` | 新 MEM/WB 条目进入时清零；F1a 中 commit 与 `dmem_pending` 同时有效时置 `1` |
| commit token/debug fire | `0/0`、`0` | 清零 | 仅实际 commit fire 产生一拍脉冲 |

F1a SVA 检查：

1. `commit_fire && dmem_pending` 后一拍必须保持 `memwb_committed_r`，且不得再次
   `commit_fire`；
2. 相邻有效流水级不能持有相同 token；
3. 连续 commit fire 的 token 必须变化；
4. 原有 FIFO occupancy/epoch/flush 断言继续有效。

## 验证入口

- `tb/sv/lcvex_fetch_fifo_tb.sv`：可选 `PROBE_HEX/PROBE_WORDS` 逐拍输出 FIFO、
  token、流水级、commit 和 dmem hold；默认 taken-branch smoke 保持不变。
- `sim/cocotb/test_fetch_fifo.py`：检查 occupancy 属于 `0/1/2`、相邻 token 唯一、
  transfer 不重复、dmem hold 时 EX/MEM 与 MEM/WB 保持、commit token 不重复，并在
  reset 后确认 FIFO/IFID 清空。
- `sim/difftest/test_program.py`：`build_hard_fetch_duplicate_program()` 生成 10
  条指令的 `ldr; ALU; ldr` 定向镜像。
- `sim/difftest/run_f1a.sh`：将 `hard_fetch_duplicate.bin` 纳入 base/cache/delay2
  三配置矩阵。

已完成的本地验证包括：带 `--assert` 的 Verilator F1a SV smoke 与 1000-cycle
post-fix probe、F1a Cocotb、以及 feature-off commit backpressure SV 回归。精确命令、
source SHA、artifact hash 和后续锁步结果以
[`docs/tasks/evidence/T-20260830-046.json`](tasks/evidence/T-20260830-046.json) 为准。

## 边界

本修复不修改 `lcvex_pkg.sv`、内存 ABI、runner comparator、I-L1/MMU/arbiter、QEMU
或参考结果；不处理 FIFO fault-head（H-03）、独立 commit-ready gap（H-04）或 F1b
early-restart。FP/vector 访存只作为后续锁步覆盖边界，不扩大本次最小 RTL 修复。
