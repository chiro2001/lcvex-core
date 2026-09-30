# T-20260826-032：step 锁步 runner 参数化交接

日期：2026-08-26（Asia/Shanghai）  
基线：`91e99d5`  
提交：`abd5a1f`  
证据：[T-20260826-032.json](../tasks/evidence/T-20260826-032.json)

## 结果

- `sim/difftest/run_lockstep_step.sh` 不再硬编码 plugin 路径，支持
  `PLUGIN=/path/to/lcvex_difftest.so`。
- 增加 `COORD_PIN`、`QEMU_PIN`，并保留 `PIN` 兼容入口；未设置 pin 时行为
  保持原样。
- 协调器和 QEMU 通过同一 `run_pinned` 入口启动，避免长跑把两个单线程进程
  绑定到同一物理核。

## 验证

- `bash -n sim/difftest/run_lockstep_step.sh`：通过。
- `git diff --check`：通过。
- 使用外部 plugin、协调器/QEMU 分别绑定物理核 8/9，`MAX_INSNS=1` step
  smoke：通过，1 条提交与 QEMU 一致。

## 边界

本任务只改变 runner 参数化，不改变 difftest 协议、RTL 或 QEMU 语义；完整
Linux fresh-root 结果由 T-031 单独记录。
