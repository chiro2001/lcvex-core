# T-20260826-047：SCTLR PAuth 脏 sidecar 联合恢复回归

日期：2026-08-26（Asia/Shanghai）
实现提交：`2f938af694bcc0f9038795419ea232368a8d79a0`
证据：[T-20260826-047.json](../tasks/evidence/T-20260826-047.json)

## 结论

新增永久 `checkpoint-sctlr-mask-smoke`。它在 `hard_sctlr_pauth` 的
`MSR SCTLR_EL1`（seq=2，`pc=0x44000008`，`0xd5181000`）后捕获 checkpoint，
断言下一条地址为 `0x4400000c` 且镜像编码为 `MRS x1, SCTLR_EL1`
（`0xd5381001`）。原始 QEMU sys sidecar 的 SCTLR 为 `0x00c50838`。

测试仅复制给 DUT 恢复使用的 sys sidecar，按实际 `LCVXSYS1/2/3` struct
解包、重包，并仅 OR `0xc8002000`，得到脏值 `0xc8c52838`。QEMU `-incoming`
仍从原始 device vmstate 和 RAM 恢复。DUT 不传 arch sidecar，而从脏 sys
副本恢复；恢复后 MRS 与随后的 MOVZ 两条提交均与 QEMU 严格锁步。

## 实现边界

- 改动：[Makefile](../../Makefile) 和
  [checkpoint_sctlr_mask_smoke.sh](../../sim/difftest/checkpoint_sctlr_mask_smoke.sh)。
- 未修改 RTL、QEMU fork、`checkpoint.py` 的格式/代码、manifest 内容或参考结果。
- capture 链、原始/展开 RAM、device vmstate、socket、日志和脏 sys 副本都在
  `build/tmp/t047.XXXXXX`；退出 trap 回收实际 QEMU/coordinator PID 并清理该目录。
- 脏化前记录 finalized `manifest.json` 与 `manifest.tsv` 的 SHA256；恢复后断言
  两者字节不变，且没有 dirty sidecar 路径。该副本从不成为可发布 artifact。

## 验证

| Evidence run ID | 层级 | 结论 |
| --- | --- | --- |
| owner-l0-static-wiring-002 | L0 | `bash -n` 和 Make target dry-run 通过。 |
| owner-l2-sctlr-dirty-003 | L2 | 原值/脏值、MSR/MRS 边界、原 QEMU 状态和 manifest 不变、两条恢复后锁步均通过。 |
| owner-l2-sys-v2-v3-004 | L2 | 既有 checkpoint sys v2/v3 联合恢复 smoke 通过。 |

首次 fresh-worktree 调用发现既有 `lockstep-build` 不创建 `build/` 父目录，
Verilator 因而无法写入 Mdir。新 target 先创建 `build/difftest` 与 `build/tmp`；
这不是磁盘、权限、生成器、RTL 或 QEMU 的瞬态失败。完整命令、日志 hash、资源和
工具版本见 evidence。

Sol 只读评审确认恢复边界没有核心阻断；其补充的 arch/MSR/MRS 与 finalized
manifest 完整性闭环均已加入并由最终主 smoke 覆盖。

## 已知限制与集成说明

- 不实现 ARMv8.3 PAuth；只覆盖当前标量目标 restore 写掩码对四个 enable 位的清除。
- 未运行 Gate D/Linux 长跑或 QEMU patch 重放；集成者应在合并 SHA 复跑本任务 L0-L2。
- `merge_sha` 由集成者在合入、复跑后补齐；不要改写本 handoff/evidence 的 owner 记录。
