# T-20260905-021：R19 core FP response-control cut 交接

```text
task=T-20260905-021
state=review
base=50b046b69341c13c4b93fffd89e5dda7d81590ff
implementation_head=9eab7d1eab2d9558bf85ede487f15af32279715b
branch=timing/T-20260905-021-r19-core-fp-response-control
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-021
owner=codex-r19-core
reported_at=2026-09-05T23:15:27+08:00
```

## 结论

T-014/T-019 后，`memwb_fetch_wait → stall_wb → exmem_can_accept →
fp_rsp_ready/fp_consume → TX_DONE` 不能通过简单布尔重写安全删除：当
MEM/WB 有更老条目、EX/MEM 也被占用时，FP response 必须继续等待，直接消费会
清除 ID/EX 而让 EX/MEM 保持，导致 response 丢失。

本 lane 在 `rtl/lcvex_core.sv` 增加一个一项 wrapper→core response elastic
boundary，并保留原 core→EX/MEM 消费谓词：

- wrapper 的 `rsp_ready` 改接 `fp_exec_rsp_ready = A64_FP_SIMD &&
  !fp_rsp_hold_valid`，不再读取 `memwb_fetch_wait`、`stall_wb`、
  `exmem_can_accept` 或任何 core-side kill 控制；因此 TX_DONE D 的该残余控制
  锥在结构上被隔离。
- EX/MEM 可接收时 response 直通，保持原 response-to-EX/MEM 延迟。
- EX/MEM/WB、fetch-fault fence 或 data-MMU hold 阻塞时，wrapper response
  在原本 TX_DONE 持有的窗口内被一次性锁存到 `fp_rsp_hold`；core-facing
  `fp_rsp_valid/fp_rsp` 继续保持，直到原 `fp_rsp_ready/fp_consume` 成功。
- kill 在 wrapper 与 hold register 两处均优先于推进；kill 同拍即使 raw
  response handshake，也不会进入架构提交。`fp_tx_issued` 只在 core-side
  `fp_consume` 清除，避免 hold 期间重复发起同一请求。

没有修改 FP datapath、QEMU、QSF/SDC、延迟定义或参考结果；没有加入 false
path，也没有关闭断言。没有宣称 timing improvement，必须由 T-020/下一次 fresh
post-fit STA 重新确认 `TX_DONE` replacement cone 与全局 top-N。

## 验证

已通过以下 owner/focused 检查：

- `verilator --lint-only --timing --assert ... --top-module lcvex_core`；
- no-FP `-GA64_FP_SIMD=0` 同一 lint；
- `python3` AST parse：`sim/cocotb/test_core_syskill.py`；
- 静态结构检查确认 wrapper 只连接 `fp_exec_rsp_ready`，该 ready 区域不含
  `memwb_fetch_wait/stall_wb`，六类精确 kill 仍在；
- 单线程 focused SV 编译与 `+T016_SYSKILL`：held response、raw boundary、
  system-after-FP（MSR/ERET/UDEF/WFI）、FCVTZS/ZU RAW 分支全部 PASS；
- 独立 T016 Cocotb：`test_core_syskill.test_r18_core_syskill` PASS。

精确命令、source/artifact hash、工具版本与限制见
[`T-20260905-021.json`](../tasks/evidence/T-20260905-021.json)。重点日志均保留在
`build/agents/T-20260905-021/static/`，未纳入 Git。

## 集成边界与下一步

集成者应从 `9eab7d1e` cherry-pick 本实现提交和随后 docs-only 提交，在 batch
candidate 上重跑 T016 SV/Cocotb、T012 natural FP/data-MMU overlap、IRQ-young、
expected-fail、受影响 L0–L2，并检查 response hold/kill/reissue、fetch-fault
merge 与提交顺序。功能联合验证通过后，按 T-020 队列运行一次 synthesis →
fitter → signoff/custom STA，查询旧 `idex_valid→TX_DONE` 是否离开以及新的
global top-N。setup 未全绿前仍禁止 assembler、bitstream、JTAG、上电和板测。
