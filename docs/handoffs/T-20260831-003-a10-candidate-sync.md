# T-20260831-003 FPGA-G6-SYNC：A10 current candidate handoff

```text
task=T-20260831-003
label=FPGA-G6-SYNC
state=review
base=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
head=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
candidate_commit=19d266a7dcffe43de7e0fdcc7057f8881be6a47f
content_sha=56c42f3e9df6a3d2f8be1cde4ff71a9ad1dfaa47bea6455beea7ae6b4cfe7ed4
branch=infra/T-20260831-003-a10-candidate-sync
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-003
owner=luna-a10-candidate-sync
model=gpt-5.6-luna
reasoning=max
dispatch_sent_at=2026-08-31T02:27:13+08:00
sent_at=2026-08-31T02:27:13+08:00
received_at=2026-08-31T02:29:13+08:00
reported_at=2026-08-31T02:59:27+08:00
files=docs/FPGA_A10_REMOTE_CANDIDATE_SYNC.md; docs/handoffs/T-20260831-003-a10-candidate-sync.md; docs/tasks/evidence/T-20260831-003.json; remote:D:\Projects\fpga-altra\lcvex\build\T-20260831-003\candidate\**
tests=metadata/static-only + local/remote hash closure + resource/process safety
non_actions=no Quartus/Qsys/sim/programming/license/process/system changes; no old-root writes
blockers=full synthesis resource gate and candidate-only/release distinction remain; toolchain not invoked
next=integrator reviews manifest and schedules <=35GB reduced/partition experiment; re-sync after any core/H-04/H-03 change
```

## 结论

候选 `19d266a7dcffe43de7e0fdcc7057f8881be6a47f` 已写入远端全新根
`D:\Projects\fpga-altra\lcvex\build\T-20260831-003\candidate`。本地与远端
machine-readable manifest 均绑定 `file_count=150`、`total_bytes=3476191`、
`manifest_file_sha256=f17df639c0b33eb55f46d76801f51215b88ba8a4f181066cb3035af27ec55e59`；
逐项 closure 为 150/150，bytes/hash mismatch=0，QSF references=49、missing=0。

150 个文件由 121 个 Git tracked closure 文件和 29 个逐字节相同的
`fpga/rtl` QSF-relative aliases 组成；根 `rtl/**` 与 `fpga/catapult_a10/**` 均完整
保留。aliases 是为了现有 QSF `../../rtl/*.sv` 的真实路径解析，不是 RTL 实现改动。

## 验证

- 本地 HEAD 精确为 candidate commit 且初始 worktree clean；platform offline、
  strict-source、50 项 SHA256SUMS 和 skeleton checker 均通过，skeleton 仅提示
  `TOOLCHAIN_MISSING`。
- 同步前远端 candidate 根不存在且为空条件成立；精确 EDA compile/sim/programming
  进程数为 0。唯一 Java 为 SlimeVR Server PID 18104，未停止或改变。
- 同步后远端逐项回读：`REMOTE_CLOSURE ... closure_files=150 ... set_match=True
  missing=0 hash_bytes_bad=0 ... sidecar_match=True`；QSF 回读为
  `REMOTE_QSF refs=49 missing=0`。
- 同步前物理 free/pagefile/D 盘为 38031.0/12800.0/100.29，之后为
  37548.9/12800.0/100.04 MB/GB；前后 EDA process count 均为 0。
- 只做 metadata/static-only、scp 和只读 hash/resource/process probe；未运行任何
  Quartus/Qsys/仿真/编程或生成器。

精确命令、local/remote manifest hash、QPF/QSF/SDC 与 platform/source/skeleton/
Qsys/SFL/RTL key hashes、前后资源快照和非动作见
[`docs/tasks/evidence/T-20260831-003.json`](../tasks/evidence/T-20260831-003.json)。

`head` 表示冻结的 candidate source commit；承载报告文档的最终 Git tip 不在自身
evidence 内预写，以最终 FINAL 的 head 为准。`content_sha` 是主同步文档实际
SHA-256；evidence 不写自身自引用 hash。

## 风险 / next

远端新根只供资源实验，不是最终 release。后续任何 core、F1a、H-04、H-03 或 QSF
路径变化都必须重新建立全新 candidate 根；不得覆盖本根或复用旧远端工程。full
synthesis 仍受前序约 35 GB reduced/partition 资源门与 Quartus 工具可用性约束。
