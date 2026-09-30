# LCVEX 交接文档 082：临时产物默认使用 build/tmp

日期：2026-08-25（Asia/Shanghai）  
前置：`081-linux-lite-buildtmp-and-mmufault.md`  
当前分支：`feature/p6-system-reg-shim`

## 决策

主机 `/tmp` 可用空间明显小于根文件系统。新任务的临时文件、trace 反汇编
中间文件、QEMU patch replay 临时副本和探针 Unix socket 默认放在
`build/tmp`，统一可用 `LCVEX_TMP_DIR=/path/to/workdir` 覆盖。压缩 checkpoint
仍写入各自的 `build/difftest/<chain>` 目录，不把未压缩 RAM 放到 `/tmp`。

历史主线 Linux 输入 `/tmp/Image-t80000` 尚未迁移；它是现有 checkpoint manifest
绑定的只读兼容输入，不应被脚本覆盖。后续若重建主线镜像，应直接发布到
`build/tmp` 或 `build/difftest`，并在 manifest 记录绝对路径和 SHA256。

## 已修改工具

- `scripts/kernel_trace_gap.py`：新增 `--tmp-dir`，默认
  `LCVEX_TMP_DIR` 或 `build/tmp`。
- `scripts/ci-nightly.sh`：QEMU release patch replay 的 `mktemp` 改到
  `build/tmp`，退出时清理。
- `sim/difftest/q6_harness.py`、`sim/difftest/qemu_probe.py`：默认 socket
  改到 `build/tmp`，自动创建父目录。
- `docs/DIFFTEST.md`、`docs/PROJECT_STATUS.md`：记录目录策略和兼容边界。

## 验证

```sh
git diff --check
bash -n scripts/ci-nightly.sh
python3 -m py_compile scripts/kernel_trace_gap.py \
  sim/difftest/q6_harness.py sim/difftest/qemu_probe.py
```

## 后续

继续定位 Linux lite `seq=1573` 的 `SCTLR.M` 后取指 fault；修复后用
`build/tmp/linux-lite-6.6` 保存短跑日志和 checkpoint，再恢复主线长跑。
