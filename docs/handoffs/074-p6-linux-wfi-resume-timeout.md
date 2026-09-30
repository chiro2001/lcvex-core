# LCVEX 交接文档 074：Linux WFI 恢复后的等待超时

日期：2026-08-25（Asia/Shanghai）  
前置：`073-p6-wfi-timer-irq-verified.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. Linux 复验结果

使用已验证 CASP 链恢复点：

```bash
CHAIN=build/difftest/casp-debug-20260825 \
RESUME_SEQ=499999 MAX_INSNS=10000 PIN=0 \
bash sim/difftest/run_lockstep_resume.sh
```

结果：从该恢复点继续前 5192 条均无 PRE/COMMIT 差分错误；随后 QEMU 在同一
Linux 等待路径进入 WFI，120 秒内没有新的 PRE，协调器按设计报告 timeout。
没有观察到 DUT/QEMU 状态 mismatch。裸机 `hard_wfi_timer_irq` 已证明 Timer
PPI30 和 ASYNC 协议可唤醒，Linux 的等待点还需要确认其实际中断源/掩码和
checkpoint 恢复后的设备状态。

## 2. 当前结论

- WFI/WFE retirement、QEMU idle hook、ASYNC IRQ packet、DUT idle wake 已
  在 base/cache 裸机闭环；
- Linux 真实等待路径尚未达到 Gate E，不能把 timeout 记为通过；
- 下一步应通过 QEMU timer/GIC debug 或较早 checkpoint 观察 WFI 前的
  `CNT*`、GIC PPI enable/pending、DAIF.I 和 GICC PMR，确认是 Linux 有意等待
  外部事件、还是 checkpoint 恢复丢失了定时器/设备唤醒状态。

不要把这个 timeout 当作回退 WFI 为 NOP 的理由；保留 `casp-debug-20260825`
链供后续切片和诊断使用。
