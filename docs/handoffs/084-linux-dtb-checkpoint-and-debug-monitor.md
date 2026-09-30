# LCVEX 交接文档 084：checkpoint FDT 一致性与 debug-monitor 清零

日期：2026-08-25（Asia/Shanghai）  
前置：`083-linux-lite-39bit-ptw.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 差分 checkpoint 的 FDT 一致性

Linux lite 在 39 位 PTW 修复后，曾在本地 `seq=130953` 的
`ldr w4,[x0,#0x24]` 分歧：

```text
VA=0xfffffffdfddfe024 -> PA=0x44200024
DUT = 0x3c1c0000
QEMU= 0x401c0000
```

页表遍历正确，差异来自输入：旧 runner 以普通 `virt` 导出 FDT 后，才用
`memory-backend=lcvexram` 启动差分 checkpoint QEMU。QEMU 因 machine
配置变化重建 FDT，DUT 仍加载旧 DTB。

`run_lockstep_step.sh` 现做以下保证：

- 启用 `DIFF_CKPT=1` 时，先创建显式 RAM backend；
- 使用与实际锁步 QEMU 完全相同的 `-machine`/`-object` 导出 FDT；
- DTB 写入本次 `CKPT_DIR/qemu-fdt-raw.bin`，不会覆盖普通运行输入；
- 失败时默认清理未压缩 RAM backend；需要保留时设置
  `DIFF_CKPT_KEEP_RAM=1`。

验证：新私有 DTB 链下 lite 从 reset 锁步 **200,000 条**通过，已跨过旧
130,953 分歧点；随后 500,000 条也通过。

## 2. Unix socket 路径与恢复临时文件

恢复 runner 的 `LCVEX_TMP_DIR` 迁到带日期的 `build/tmp` 深路径后，旧的
`difftest-resume.XXXXXX/step.sock` 超过 AF_UNIX `sun_path` 108 字节限制。
协调器会截断 socket 名而 shell 等待完整路径，表现为无 QEMU 连接。

`run_lockstep_resume.sh` 现使用短目录 `r.XXXXXX`，并在启动前拒绝仍然过长
的 socket 路径；运行期 RAM、device 和 timer 原始文件默认在 `build/tmp`
中展开并在退出时删除（`KEEP_RESTORE_WORK=1` 才保留）。

## 3. Linux debug-monitor 关闭序列

主线从 checkpoint 续跑时依次遇到：

```text
msr dbgbcr0_el1, x2   # x2=0
msr dbgbvr0_el1, x2   # x2=0
```

这是 Linux early boot 关闭硬件 breakpoint/watchpoint。P6 尚未实现 P9 的
外部调试与 debug exception，因此 RTL 对完整族
`DBGBVR[n]`/`DBGBCR[n]`/`DBGWVR[n]`/`DBGWCR[n]`（`S2_0_C0_Cn_4..7`）按
“写零关闭”用途作 RAZ/WI shim；重置值/读值均为 0，MSR 在 ID 提交，写入
无可观察副作用。非零配置并不属于 P6 已承诺的 debug 支持。

`hard_p6_isa` 新增四类寄存器和 n=5 的 MSR/MRS 定向用例；base 与全缓存
锁步均通过 114 条。主线随后从 `diff-299999` 恢复，额外 **500,000 条**
通过，覆盖原 debug-monitor 分歧位置。

## 4. 验证摘要

```text
bash sim/difftest/run_m2_4b.sh --only hard_p6_isa
  PASS：base + I/D L1 + L2，各 114 条

Linux lite（DIFF_CKPT=1，链私有 FDT）
  PASS：200,000 条；PASS：500,000 条

主线 restore
  PASS：从 linux-timer-irq-3/diff-999999 的 1,000,000 条窗口
  PASS：从 debug-monitor 前 diff-299999 的 500,000 条窗口
```

## 5. 后续

1. 从 `build/tmp/linux-main-dbgmon-20260825/chain/diff-499999` 继续主线；
2. 从 lite 500k 链继续至 1M，观察静态 `/init` 的 UART 输出；
3. P6/Gate E、用户空间与 P9 debug 机制仍未完成，不能将 RAZ/WI shim
   误描述为完整 breakpoint/watchpoint 支持。
