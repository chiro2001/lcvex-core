# LCVEX 交接文档 077：P6 Linux Timer IRQ 后 2M 锁步与压缩链

日期：2026-08-25（Asia/Shanghai）
前置：`076-p6-linux-timer-irq-spsr.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 当前进度

Timer/IRQ/SPSR 修复提交后，从既有链恢复点继续：

```text
CHAIN=build/difftest/casp-debug-20260825
RESUME_SEQ=499999 MAX_INSNS=1000000       PASS
```

随后建立压缩 checkpoint 链并从其末端继续：

```text
build/difftest/linux-timer-irq-20260825   diff-999999
build/difftest/linux-timer-irq-2-20260825 diff-999999
build/difftest/linux-timer-irq-3-20260825 diff-999999
```

三段各 1,000,000 条均逐提交无差分错误；第二段从第一段的
`diff-999999` 恢复，故 Timer PPI27、IRQ 向量、SPSR PAN/DIT 和后续 Linux
路径已累计跨过约 3M 条。当前从 Linux 启动起可保守报告约 **31M 条动态指令**
正确锁步，仍不能把局部 checkpoint seq 相加当作精确全局编号。

## 2. Checkpoint 资源

- 两条新链每条约 14 MiB（gzip RAM base + 脏页 diff + arch/sys/timer/GIC
  sidecar）；
- 每 100,000 条保存一次，manifest 使用绝对路径；
- 未生成全量 trace，`/tmp` 约 6.6 GiB 可用，根文件系统约 81 GiB 可用；
- 运行均绑定单个物理核，构建线程不超过 6。

## 3. 已验证命令

```text
make test       PASS
make m2-4b      PASS（base/cache）
make p6-lse     PASS（base/cache，100 条）
make p6-wfi     PASS（base/cache，含 WFxT 14 条和 Timer IRQ 45 条）
QEMU patch 0001..0007 干净重放       PASS（基线 84f0721）
```

## 4. 下一步

从 `linux-timer-irq-2-20260825/diff-999999` 继续保存第三条链，目标是到达
用户空间 `/init` 或定位下一条真实缺口。若出现新差异，保留运行目录中的
`fail.txt`、PRE/COMMIT 窗口和流水线现场；不要删除两条已验证链。
