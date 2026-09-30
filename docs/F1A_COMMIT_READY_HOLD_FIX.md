# F1a `commit_ready`/IFID hold 修复

任务：`T-20260831-004`（PE-F1A-H04）

## 结论

FIFO-on 路径在 `commit_ready=0` 且 MEM/WB 为空时不应停止取指。原实现把
`commit_ready` 直接加入 `fetch_fifo_pop`，但 IF/ID 只由 `stall_if` 保持。于是
FIFO 有 head、IFID 有效而下游没有 stall 时，`pop=0` 与 `stall_if=0` 同时成立，
IF/ID 更新分支落入气泡路径，丢掉当前 token/PC。

修复从 `fetch_fifo_pop` 移除 `commit_ready` 条件。MEM/WB 已有条目且消费者未就绪时，
现有 `stall_wb` 仍然禁止上游推进；MEM/WB 为空时，FIFO 与 IF/ID 正常消费/替换，
不会产生额外组合环，也不改变 FIFO-off legacy 路径。

## 根因门证据

未修复 RTL 使用 `FETCH_FIFO_ENABLE=1`、乘法忙窗口（使 FIFO 填充）构造了精确条件：

| 时刻 | `commit_ready` | FIFO count | `fetch_fifo_pop` | IFID | IFID PC/seq | `memwb_valid` | `stall_if` |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| ready 拉低后的同拍 | 0 | 1 | 0 | 1 | `0x4400000c` / 3 | 0 | 0 |
| 下一拍 | 0 | 1 | 0 | 0 | — | 1 | 1 |

完整 pre-fix 日志保存在本地 evidence artifact `h04_prefix.log`。这证明丢失发生在
IF/ID receive/hold 边界，而不是 commit packet 或外部 checker。post-fix 同一窗口为
`pop=1`，下一拍 IFID=`0x44000010`/seq 4，原 seq 3 只进入 ID/EX 一次。

## RTL 与断言契约

- `commit_ready` 只门控 `commit_fire` 和系统提交；MEM/WB 有效且 ready 低时由
  `stall_wb` 冻结流水线，FIFO pop 必须为 0。
- FIFO-on 且 WB 为空、IFID/FIFO 可消费、无 kill/stall 时，新增 SVA 同时检查旧
  IFID 的 PC/epoch/seq 下一拍进入 ID/EX，以及旧 FIFO head 的 PC/epoch/seq 原子
  替换到新 IFID；fault head 不属于 H-04 的可消费前件，由后续 H-03 单独处理。
- T-046 的 `memwb_committed_r`/`dmem_pending` 条件、IFID→IDEX→EXMEM→MEMWB token
  和原有 ring/epoch SVA 未改动。
- `FETCH_FIFO_ENABLE=0` 不经过这条 FIFO-on 条件，默认值和公共 commit/memory ABI
  不变。

## 验证

- L0：pre-fix 精确 failing probe；post-fix probe、标准 `sim-sv-fetch-fifo`、
  Verilator `--assert` 与 core lint 通过。
- L1：Cocotb ready 随机调度覆盖 FIFO 0/1/2、IFID valid/empty、WB 空/满、分支
  flush、dmem hold；`MEM_DELAY_MODE=0` 另外覆盖同拍 push+pop；T-046 load/ALU/load
  token 回归通过。
- L2：`hard_fetch_ready_hold` 与既有五个镜像在 base/cache/delay2 共 18 个严格
  锁步 case 中均为 32/32 commit；ready-hold f0/f1a 完整 trace 均 14 commits，
  comparator=`equal`，commit/memory digest 相同。

精确命令、服务资源限制、unit/invocation、日志及 SHA256 见
`docs/tasks/evidence/T-20260831-004.json`。不处理 H-03 FIFO fault-head、F1b 或
完整 F1c/Gate D/Linux。
