# T-20260831-002 FPGA-G6-PROV：A10 provenance 重锁 handoff

```text
task=T-20260831-002
label=FPGA-G6-PROV
state=review
base=4764d834c33055814846db46dc29c6fc74290358
head=a2c811c50af953a3aee7faf1f685f88d4d9d0d7e
content_sha=d929dd88ccc06fdc9edfc2824cbb89744edd2329fcee736b8f539f60f53cddc9
branch=infra/T-20260831-002-a10-provenance-relock
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-002
owner=luna-a10-provenance
model=gpt-5.6-luna
reasoning=max
dispatch_sent_at=2026-08-31T01:23:22+08:00
sent_at=2026-08-31T01:23:22+08:00
received_at=2026-08-31T02:02:03+08:00
reported_at=2026-08-31T02:14:10+08:00
files=fpga/catapult_a10/platform_manifest.json; fpga/catapult_a10/source.lock; fpga/catapult_a10/SHA256SUMS; fpga/catapult_a10/skeleton_manifest.json; fpga/catapult_a10/tools/check_platform.py; fpga/catapult_a10/README.md; docs/FPGA_A10_PROVENANCE_RELOCK.md; docs/handoffs/T-20260831-002-a10-provenance-relock.md; docs/tasks/evidence/T-20260831-002.json
tests=metadata/static-only + check_skeleton contract
non_actions=no top/reset/QPF/QSF/SDC/payload/remote/Quartus/Qsys changes; no implementation rerun
blockers=full synthesis resource gate, speed-grade inconsistency, remote candidate sync and JTAG identity remain blocked/waiting
next=integrator reruns metadata/static subset on correction tip, then separately schedules candidate sync and reduced/partition synthesis
correction_files=fpga/catapult_a10/skeleton_manifest.json; docs/FPGA_A10_PROVENANCE_RELOCK.md; docs/handoffs/T-20260831-002-a10-provenance-relock.md; docs/tasks/evidence/T-20260831-002.json
```

`head` 和 `content_sha` 的语义已固定：`head` 是首次交付 tip
`a2c811c50af953a3aee7faf1f685f88d4d9d0d7e`；`content_sha` 是主重锁正文
[`docs/FPGA_A10_PROVENANCE_RELOCK.md`](../FPGA_A10_PROVENANCE_RELOCK.md) 的实际
SHA-256，而不是本次 correction tip。承载本次 metadata correction 的最终 tip
无法在自身 handoff/evidence 中预写，以本次 FINAL 的 `head` 为准；evidence 自身
不写自引用 SHA。

## 实现摘要

- 以 `/home/chiro/projects/a10-linux-riscv@3db828e74651fda377a33d84f2a2ca0e69901d72`
  的 raw Git blob 重锁 `source.lock` 和 manifest 的 23 项漂移；50/50 source
  hash/bytes 与 clean、锁定 HEAD 一致。
- 重新计算当前 50 个 target payload 的 manifest/SHA256SUMS；QSF=`78032dc5…`
  (13647 B)，SDC=`caf84775…` (5656 B)，其余 payload 未改。
- 加固 `check_platform.py`：默认离线兼容；显式 `--strict-source --source-repo
  ... --source-commit ...` 校验 clean repo、HEAD/commit、50 个 raw blob、重复/缺失/
  path traversal，以及 manifest/source.lock/SHA256SUMS/target 闭包。
- README、重锁说明和 evidence 已补齐；没有修改 QPF/QSF/SDC/Qsys/SFL/JTAG-UART/RTL。

## 边界与结论

来源仓只读审计通过，payload 与三份 provenance 文件闭合。source bytes/hash 描述
参考仓 raw blob，target bytes/hash 描述本地导入文件，两者不同不表示 payload 被
替换。strict-source 不会隐式运行，默认模式不会访问参考仓。

前序 A10 执行预检的 full synthesis 资源阻断、speed-grade 不一致、远端 candidate
未同步和 JTAG device identity 风险均保持不变；本任务没有运行 Quartus/Qsys/仿真或
任何远端/板卡动作。

## 验证与 evidence

```text
python3 -m py_compile fpga/catapult_a10/tools/check_platform.py             PASS
python3 fpga/catapult_a10/tools/check_platform.py                           PASS (50)
python3 fpga/catapult_a10/tools/check_platform.py --strict-source \
  --source-repo /home/chiro/projects/a10-linux-riscv \
  --source-commit 3db828e74651fda377a33d84f2a2ca0e69901d72                  PASS (50/50)
(cd fpga/catapult_a10 && sha256sum -c SHA256SUMS)                           PASS (50/50)
jq -e . fpga/catapult_a10/skeleton_manifest.json                           PASS
python3 fpga/catapult_a10/tools/check_skeleton.py                         PASS (TOOLCHAIN_MISSING only)
jq -e . fpga/catapult_a10/platform_manifest.json                            PASS
git diff --check                                                             PASS
```

隔离 fixture 中篡改 source.lock hash、SHA256SUMS hash、重复 target 和 `../` path
均被拒绝并返回非零。精确命令、输出摘要、fixture 清理和 immutable-path hash
记录在 [`docs/tasks/evidence/T-20260831-002.json`](../tasks/evidence/T-20260831-002.json)。

本次 correction 原先只允许修改本 handoff 与 evidence 两个文件；集成者新增
`fpga/catapult_a10/skeleton_manifest.json` 及同步主重锁文档后，写集扩为该 manifest、
主重锁文档、本 handoff 与 evidence 四个文件。以 BASE..HEAD 做 immutable-path 检查，并以
`git diff --name-only BASE..HEAD` 审计首次交付的 8-file 写集及 correction 后的
9-file 总写集。默认 `check_skeleton.py` 会写出
`build/agents/T-20260827-062/skeleton-toolchain-report.json`，本次按集成者要求运行
并保留该未提交本地报告；此前实现阶段的 offline/strict-source 与 fixture 结果
保持为历史 evidence，本 follow-up 不把它们伪报成新的实现测试。

在 correction tip 上另以 `git diff --check a2c811c50af953a3aee7faf1f685f88d4d9d0d7e..HEAD`
检查 whitespace，并以 `git diff --name-only a2c811c50af953a3aee7faf1f685f88d4d9d0d7e..HEAD`
确认 correction 写集严格只有 skeleton manifest、本 handoff 与本 evidence 三个文件；结果和 clean
worktree 复核由 FINAL 报告给出。初始实现命令的 started/finished 事件不可从历史
恢复，evidence 明确标为 unknown，不以 commit 时间替代。

交付文件 SHA-256、correction 四文件写集、BASE..HEAD immutable diff、JSON/diff
检查和上述 `check_skeleton.py` 的 PASS/TOOLCHAIN_MISSING 结果均以结构化形式记录在 evidence；evidence
自身的 artifact hash 明确标为 self-reference，避免制造自引用哈希。

## 风险 / next

下一步需由集成者在合并 SHA 上复跑离线与 strict-source 子集，并另立远端 candidate
同步及资源受控 reduced/partition synthesis 任务。不得把本 handoff 当作 Quartus
full flow、STA、SOF、program 或 Flash 写入通过证明。
