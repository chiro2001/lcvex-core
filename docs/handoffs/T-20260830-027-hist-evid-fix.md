# Handoff T-20260830-027: HIST-EVID-FIX 历史 evidence 批量定稿与 live 时间戳清理

## 元数据

- task: T-20260830-027
- label: HIST-EVID-FIX
- parent: T-20260830-025 (EXT-01-FIX)
- base_sha: `3ae420dbd292d7a679fe58b4b2a4c1b78184c4e5`
- 当前主线: `feature/p7-final @ 8ee1fe5`
- branch: `feature/p7-final`（实际执行工作区；任务登记 branch 为 `feature/T-20260830-027-hist-evid-fix`）
- evidence: `docs/tasks/evidence/T-20260830-027.json`
- 状态：**owner 静态交付完成；live 时间戳清零；未合并，未运行 RTL/QEMU/FPGA。**

## 结论

1. 对 live 范围内的历史 done 任务 evidence 做了批量定稿：
   - 覆盖 **66 个 done 任务**（50 个 active + 16 个有 evidence 的 proposed）。
   - 为其中 **63 个尚未定稿的 evidence** 补齐 `merge_sha`、`state=done`、
     `handoff_sha`、`integrator_review`（含 `merge_sha`/`result_sha`）和
     `correction_record`；T-099/T-104/T-105 原本已定稿，未重复改写。
   - 为 **63 个 active/proposed 任务** 回填了缺失的 `head_sha`（来自对应 evidence）。
   - 将 **8 个短 merge SHA** 扩展为完整 40 位 SHA（active/proposed 与 evidence 同步）。
   - 为 **62 个 git 内可复现 artifact** 计算并填入了 SHA256；另有 33 个远程/本地
     非仓库 artifact 无法在 Git 内计算，保留为已知限制。
   - **未改写任何历史 handoff**，只新增本 handoff 和 evidence 回填/校正记录。

2. 时间戳清理：
   - 批量修正 **253 个** 超出承载 Git 提交或未来的 event/ledger 时间字段
     （保留原值到各文件 `correction_record.timestamp_fixes`）。
   - 额外修正 **4 个** evidence/active 单调性不一致
     （T-20260829-088、T-20260829-090 的 evidence sent/received 对齐 dispatch）。
   - `scripts/check_task_timestamps.py --scope live` 结果：
     - **before: 204 error / 125 warning**
     - **after: 0 error / 0 warning**

3. 脚本增强：
   - `--scope live` 现在只检查 proposed/active 任务及其对应 evidence；
     归档任务 evidence 仅在 `--scope all` 中检查。
   - `--scope all` 仍保留 **12 error / 78 warning**，均为归档/历史记录，
     按“不改写历史归档”原则保留并记录，不属于 live 残留。

## 批量 evidence 定稿明细

- 每个 touched evidence 在 `correction_record.evidence_finalization` 记录：
  - 新增/回填 `merge_sha`
  - `state` 置为 `done`
  - 回填 `handoff_sha`
  - 复制 active/proposed `integrator_review`，并补 `merge_sha`
  - 补充 `integrator_review.result_sha = head_sha`
- 每个 active/proposed 在 `correction_record.evidence_fixes` 记录回填的 `head_sha`。
- 所有旧值均以 correction 形式保留，不删除原始历史数值。

## 时间戳修正规则

- 对 event/ledger 时间大于其 `git blame` 承载提交时间或大于当前时间者，
  统一修正为承载提交时间（无承载时使用当前时间），并在
  `correction_record.timestamp_fixes` 保存 old/new。
- 对 evidence `sent_at/received_at/reported_at` 早于任务 `dispatch.sent_at` 者，
  对齐到 dispatch 时间，并在 `correction_record.monotonic_fixes` 保存 old/new。
- 对 planned/future 且属于已归档不可改写记录，不移改，改由 `--scope live`
  过滤掉；`--scope all` 仍可见。

## 校验

| 检查 | 结果 |
| --- | --- |
| `python3 -m py_compile scripts/check_task_timestamps.py` | PASS |
| 所有改动 JSON `json.load` | PASS（139 个 JSON） |
| `python3 scripts/check_task_timestamps.py --scope live` | 0 error / 0 warning |
| `python3 scripts/check_task_timestamps.py --scope all` | 12 error / 78 warning（归档历史） |
| `git diff --check` | PASS |
| RTL/QEMU/FPGA/Makefile 未改 | 是 |
| 历史 handoff 未改写 | 是 |

## 剩余 / 限制

1. live 范围内已无时间戳 error/warning。
2. `--scope all` 仍有 12 error，全部是归档任务/归档 evidence 的历史记录：
   - T-20260826-013/014 的 `updated_at < created_at`。
   - T-20260827-051/052/057/062、T-20260828-069/070 的事件晚于承载提交。
   - T-20260828-063/066/068/070 的归档 evidence 事件晚于承载提交。
   这些按归档不可改写原则保留，未在本任务中移除或伪造。
3. 33 个 live evidence artifact 仍未填 SHA256，因为它们指向远端
   Windows/FPGA 工程路径、构建目录或 worktree-local 文件，不在 Git 对象中；
   已在对应 evidence 中保持原有 null/reproduce 信息，未伪报。
4. 本任务未运行重型 Verilator/Gate D/Quartus；只改 docs 与 scripts。

## 下一步

由集成者合并本分支，复核 live 时间戳 0/0 与 evidence 回填记录；
如需彻底清理 `--scope all` 归档残留，应另立只针对 archive 的显式任务。
