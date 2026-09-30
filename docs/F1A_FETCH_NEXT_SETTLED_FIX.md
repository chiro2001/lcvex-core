# F1a system next-fetch outcome 栅栏修正

任务：`T-20260831-006`（`PE-F1A-NEXTSETTLE`）

## 结论

F1a 曾把“下一取指请求已 pending”或“VA→PA 已翻译”当成
next-fetch outcome 已确定。`hard_sys_fetch_fault` 中，页尾
`MSR SCTLR_EL1` 因此在下一页的取指 fault 返回前普通提交；稍后
fault 才成为 FIFO head，已无 older QEMU `PRE/COMMIT` 可供合并，导致
fault-head 永久无消费。

修复后，FIFO-on 的 `fetch_next_settled` 只接受 current-epoch、目标 PC
匹配的 FIFO entry（正常或 fault），或明确匹配的 `fetch_faulted`
context。pending request 和 `fetch_translated` 不再单独解除 ID-level system
commit 栅栏；matching fault 继续通过既有 `sys_fetch_merge` 与该系统
指令的提交包合并。

## 上下文切换

`SCTLR_EL1`/`TCR_EL1`/`TTBR0_EL1`/`TTBR1_EL1`/`MAIR_EL1` 改变取指
翻译上下文。这些 MSR 在 FIFO-on 时使用 IFID token epoch 区分写前与写后
outcome：

- effective MMU 开启且 `fetch_epoch == ifid_token_epoch` 时，必须先经
  `sys_fetch_redirect` 完成一次 quarantine/epoch bump；
- 旧 pending、translated、normal FIFO 和 fault FIFO 都不能直接 settle；
- refresh 后的新 epoch outcome 才能让 MSR 提交；
- fresh fault 与 MSR 合并时，上述五个系统寄存器的写效果仍在该
  commit 边界生效，然后进入 IABT 异常。

`MSR SCTLR_EL1, M=0` 是特殊过渡：它不使用旧 MMU context 的
matching fault 生成 `sys_fetch_merge`，而是正常写入 M=0，由该
`sys_commit` 的 frontend kill 清除旧 fault，随后按 MMU-off 重新取指。

## 状态与提交契约

本修复未新增架构状态、公共 response ID 或 commit packet 字段。
`sys_fetch_context_change`/`sys_fetch_context_refresh_needed`/`sys_fetch_merge_allowed`
均是 core-local 组合元数据，不需要独立 reset 值或软件读写权限。

架构状态仍只在 `sys_commit`/`commit_fire` 边界更新。
`commit_ready=0` 时系统指令、fetch context 和 fault metadata 保持；
matching fault 只能合并提交一次，同拍清除 younger FIFO/IFID/在途
context，epoch 只增加一次。T-046 `memwb_committed_r` 和 T-004
ready-low FIFO/IFID 原子转移保持不变。

## 验证

- pre-fix first-trace 证明 `fetch_pending=1` 曾误令
  `fetch_next_settled=1/sys_commit=1`，匹配 fault 后到。
- 最终 SHA 在 FIFO-on d0/d2 重建 `--assert` SV binary，通过 MMU
  fault merge、H-04 ready hold、T-046 duplicate 和 SCTLR-disable old-fault 定向
  probe；FIFO-off 的 disable old-fault 与 system backpressure 也通过。
- old pending、old translated、old normal FIFO、old fault FIFO 及
  SCTLR.M=0 负对照均有定向证据。
- `hard_sys_fetch_fault` 25/25 与 `hard_neon_fetch_fault` 20/20 在
  base/cache/delay2 六个 strict-lockstep case 中全部与 QEMU 一致。

精确命令、unit、资源峰值和 artifact/log SHA256 见
[`docs/tasks/evidence/T-20260831-006.json`](tasks/evidence/T-20260831-006.json)。

## 边界

本任务不修改 QEMU/plugin/comparator、`mem_req_t/mem_rsp_t`、MMU/arbiter
公共 ABI，不实现通用 H-01 UID/age、F1b 或 standalone reset-PC fault packet。
完整 F1c、Gate D、Linux、Quartus 与上板在后续独立任务中执行。
