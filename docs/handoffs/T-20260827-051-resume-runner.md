# T-20260827-051 P7-0 checkpoint resume runner handoff

task=T-20260827-051 state=review

base=5d460192dfb8a72173c76077cae5bd05251e9eb9
head=6c0c2f192b5c80c35da823d60a8f9c5e4ae86079
line=feature/p7-fp-neon

## 本次闭合

- `run_lockstep_step.sh` 在 P7 required 差分 checkpoint 的 root manifest 中写入
  `p7_state=LCVXFP01`、`p7_cpu_profile=a76-v1` 和 `p7_vector_bytes=16`。
- `run_lockstep_resume.sh` 读取 manifest 第 13 列，并通过 `checkpoint.read_fp_state`
  严格验证 finalized manifest、552B sidecar、路径和 `header.seq == TSV seq`，再把
  解压后的 raw state 传给 coordinator 的 `--restore-fp`。
- P7 checkpoint 使用显式 `cntfrq=1000000000` 的 Cortex-A76 profile；QEMU 11.1
  默认 A76 的 62.5MHz 计时器链被拒绝，避免与 RTL 固定的 1GHz `CNTFRQ_EL0` 产生
  隐蔽不一致。标准 A76 写法在 root runner 中自动规范化。

## 验证结论

- 有效 root 链在 seq=6 finalize，包含 8 个 artifact 和第 13 列 FP sidecar；从该
  点恢复后下一条提交通过 A76 required lockstep。
- 显式传入和省略 `QEMU_CPU` 的 resume runner 均通过；后者采用 1GHz A76 默认值。
- 62.5MHz A76 sidecar 的恢复被 coordinator 拒绝；该链保留为负向现场，不作为
  通过证据。
- 低资源 checkpoint/trace manifest、resume provenance、P7 13 列 fixture、shell
  syntax/diff check 和当前 RTL lint 均通过。

精确命令、source SHA、QEMU/plugin/coordinator 和 artifact 摘要见
[`docs/tasks/evidence/T-20260827-051-resume.json`](../tasks/evidence/T-20260827-051-resume.json)。

## 边界与后续

本 handoff 只闭合 P7-0 的状态/协议/checkpoint 恢复，不代表 FP32/FP64 算术、NEON
访存、Linux 长跑或 Gate F-ISA/F-MEM/F-BOARD 完成。下一项应登记 P7-1 标量 FP
垂直任务，并保留 Catapult 线的独立写集和重型资源队列。
