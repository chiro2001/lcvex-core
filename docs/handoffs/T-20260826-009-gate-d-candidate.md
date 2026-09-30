# T-20260826-009：Gate D candidate 回归交接

日期：2026-08-26（Asia/Shanghai）  
candidate：`73f0d51ab40d1a42bce9e17f846d2de4726afb1e`  
证据：[T-20260826-009.json](../tasks/evidence/T-20260826-009.json)

## 结论

本次 Gate D candidate 回归在 L1 首步阻断，不能作为 Gate D 绿证据。L0
`scripts/toolcheck.sh` 通过；`VERILATOR_JOBS=6 taskset -c 0-5 make test`
在 `compile` 的 Verilator lint 阶段退出码 2。

首错为 `rtl/lcvex_alu.sv:243/244` 的四个 `UNUSEDSIGNAL` warning：
`addc32w[33]`、`subc32w[33]`、`addc64w[65]`、`subc64w[65]`。candidate 的
`-Wall` 将 warning 视为 error（`Exiting due to 4 warning(s)`）。未关闭断言、
未抑制 warning、未修改 RTL 或参考结果；完整首错日志保留在
`build/T-20260826-009/logs/make-test.log`。

## 运行边界

- 仅使用 detached candidate worktree，CPU 绑定 0–5，未启动 Linux 长跑或并行
  重型 QEMU。
- QEMU 固定 11.1.0，binary/plugin/filelist 的 SHA256 均写入 evidence；外部
  QEMU fork 和 plugin 只读使用。
- 遵循首个 L1 失败立即停止，因此 `make coverage`、L2 定向差分和
  `run_gate_d.sh` 未执行，不能据此宣称 Gate D 完成。修复 lint 或明确候选
  policy 后，应从同一 candidate 重新运行完整队列。
