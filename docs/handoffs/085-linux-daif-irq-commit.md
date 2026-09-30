# LCVEX 交接文档 085：DAIF 解屏蔽后的 IRQ 提交边界

日期：2026-08-25（Asia/Shanghai）  
前置：`084-linux-dtb-checkpoint-and-debug-monitor.md`  
当前分支：`feature/p6-system-reg-shim`

## 问题

主线长窗口在本地 `seq=1214433` 分歧：

```text
PC   = 0xffff8000810ca0a4
insn = d51b4221  (msr daif, x1)
x1   = 0          (写后 DAIF.I=0)
```

GIC 已有 virtual timer IRQ pending。QEMU 正确地把该 `MSR DAIF` 作为
IRQ 前最后退休的指令，COMMIT 的 `next_pc` 直接是
`VBAR_EL1+0x280`，`exc_code=0x40`、NZCV 清零。RTL 原逻辑只在普通
WB `commit_fire` 时接受 IRQ；ID 级 `sys_commit` 没有等价路径，故错误
地正常推进到 `PC+4`。

## 修复

- `rtl/lcvex_core.sv` 新增 `sys_daif_after`，覆盖 MSR DAIF 与
  DAIFSet/DAIFClr immediate 的写后掩码；
- 对非 ERET 的 ID 级系统提交，当写后 `I=0` 且 IRQ pending 时以
  `sys_irq_taken` 合成同条异常 COMMIT；
- 该 COMMIT 的 ELR 为 `d.next_pc`，SPSR 保存写后 DAIF，PSTATE 进入
  EL1h/DAIF=1111/NZCV=0，并把取指直接重定向到 IRQ 向量；
- ERET 保持独立恢复路径，未扩大本次变更的异常边界。

## 定向测试

新增 `hard_irq_daif`：在复位 `DAIF.I=1` 时经 SGIR 挂起 SGI#1，再执行
`msr daif, x1`（x1=0）。QEMU 必须在该 MSR 后、下一条 `movz` 前进入
EL1h IRQ handler；handler 读 IAR、写 EOI、ERET 返回。

```text
bash sim/difftest/run_m2_4b.sh --only hard_irq,hard_irq_daif
  PASS：base + I/D L1 + L2
  hard_irq       30 条
  hard_irq_daif  40 条

主线从 linux-main-long/diff-1199999 恢复
  PASS：额外 500,000 条，跨过旧 seq=1214433
```

## Linux lite 状态

Linux lite 的两条连续 5M 窗口均通过；累计从 reset **12,500,000** 条
逐指令锁步通过，checkpoint 间隔仍为 100k。尚未以锁步日志证实静态
`/init` 的 UART 输出，Gate E 不能宣称完成。

## 后续

1. 主线从 `build/tmp/linux-main-irq-daif-20260825/chain/diff-499999`
   继续；
2. lite 从 `build/tmp/linux-lite-6.6/long-7p5m-20260825/chain/diff-4999999`
   继续，直到到达 `/init` 或出现新 ISA/平台缺口；
3. 若未来触发 ERET 返回后立即 IRQ，单列测试与恢复后 EL/SP 向量语义，
   不将本次 `sys_irq_taken` 的 ERET 排除视为已覆盖。
