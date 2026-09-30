# Handoff T-20260826-014：backpressure SV testbench restore pins

## 元数据

- task: T-20260826-014
- owner: root-integrator
- date: 2026-08-26
- base_sha: `2a2a2b7`
- head_sha: `b2e53f0`
- branch: `fix/T-20260826-014-backpressure-pins`
- worktree: `/home/chiro/projects/mycpu/lcvex-wt-T-20260826-014`
- dependencies: 无；用于后续 Gate D candidate
- qemu_release: 不适用
- qemu_commit: 不适用
- qemu_patches_sha: 不适用
- rtl_filelist_sha: 以合并 SHA `a4906c0` 的 `rtl/filelist.f` 为准
- config/toolchain: conda 环境 `lcvex`，Verilator 5.050
- evidence: `docs/tasks/evidence/T-20260826-014.json`

## 目标与边界

消除 backpressure SV testbench 在 `lcvex_soc` 实例化时对三个新增
checkpoint restore 输入的 `PINMISSING`；不改变 RTL、提交背压语义或 QEMU。

## 实现摘要

- 改动文件：`tb/sv/lcvex_commit_backpressure_tb.sv`
- 三个输入 `difftest_restore_ssbs/uao/tco` 均固定连接为 `1'b0`。
- 未改动 RTL、QEMU、协议和参考结果；这些连接不引入架构状态。

## 验证证据

| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-l0-backpressure-001 | L0 | 独立 worktree smoke 通过 |
| integrator-l0-backpressure-002 | L0 | 合并 SHA 上绑定物理核 0 重跑通过 |

精确命令、source SHA、版本、退出码、资源和 artifact manifest 以 evidence JSON
为准。

## 失败现场/重现

无；此前 T-013 的 `PINMISSING` 失败由本任务修复。若复现，运行：

```sh
taskset -c 0 env VERILATOR_JOBS=1 make sim-sv-backpressure
```

## 已知限制与后续任务

- 仅证明 backpressure testbench 的 L0 smoke；不能宣称 Gate D 或 Gate E 通过。
- Gate D 必须在包含 `a4906c0` 的单一冻结 candidate SHA 上重新执行。

## 集成说明

已于合并提交 `a4906c0` 集成；旧 T-013 candidate 不再作为新绿色证据。
