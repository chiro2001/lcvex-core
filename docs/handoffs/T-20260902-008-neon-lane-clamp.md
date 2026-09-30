# Handoff T-20260902-008：NEON Lane Clamp 正式合入

```text
task=T-20260902-008
state=review
base=20639c8defd66407af87292844fd902b6bf00f6a
head=39f7a4a1858cdf88e9bf273aa718f6b89af9f291
branch=fix/T-20260902-008-neon-lane-clamp
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-008
sent_at=2026-09-02T18:12:00+08:00
received_at=2026-09-02T18:12:30+08:00
reported_at=2026-09-02T18:24:53+08:00
```

## 摘要

将 T-20260902-007 已由远端 probe 验证的全 lane-width 合法 index 钳位正式合入仓库
`rtl/lcvex_neon_int.sv`，消除 Quartus Prime Pro 21.4 elaboration 对 32-bit
`set_lane` 的 `index 128 out of range` 报错，并同步保护 `lane_unsigned`。

## 修改

`rtl/lcvex_neon_int.sv`：

- `lane_unsigned` 的 8/16/32-bit 分支增加 index 上限保护：
  - 8-bit：`index < 16`
  - 16-bit：`index < 8`
  - 32-bit：`index < 4`
  - 64-bit：保留已有 `index < 2`
- `set_lane` 的 8/16/32-bit 分支增加同等的 index 上限保护；非法 index 不写入，
  保持函数返回原 `value` 不变。
- 合法 lane 功能语义不变。

## 验证

| Evidence run ID | 命令 | 结果 |
| --- | --- | --- |
| owner-l0-compile-001 | `make compile` | PASS，exit 0 |
| owner-l1-sv-neon-int-002 | `make VERILATOR_JOBS=1 sim-sv-p7-2-neon` | PASS，exit 0 |
| owner-l1-cocotb-neon-int-003 | `make VERILATOR_JOBS=1 sim-cocotb-p7-2-neon` | FAIL（已知无关），TESTS=10 PASS=9 FAIL=1，exit 2 |
| owner-l1-diff-check-004 | `git diff --check` | PASS |
| owner-l1-static-clamp-005 | 静态扫描 `index*N +: N` 切片 | PASS，8 处切片均受对应上限保护 |

Cocotb 唯一失败仍为 `test_p7_2_neon.test_p7_2_unsupported_udef` 的 SQADD 用例：
`0x4E220C20` 被现有 B2c DUP decode 分支捕获。该失败与 T-20260902-004 记录一致，
不是本任务修改 `rtl/lcvex_neon_int.sv` 引入的新失败。

## 边界

- 本任务不修改 decode；未调整合法 NEON 整数 lane 运算语义。
- 未运行远端 Quartus full-FP synthesis；本任务只完成 RTL 正式合入和本地
  Verilator/Cocotb 验证。后续合并 SHA 全流程确认由集成者/后续任务执行。
- 未运行 fit/STA/assembler/SOF/编程。

## 下一步

1. 集成者验收并合并本分支。
2. 在合并 SHA 上复跑远端真实 full-FP synthesis，确认正式 RTL 不再报
   `index 128 out of range`。
3. 若需 P7-2 Cocotb 全绿，另开 decode B2c DUP/SQADD 编码重叠修复任务。

## 证据

- `docs/tasks/evidence/T-20260902-008.json`
