# LCVEX 交接文档 066：P6 系统探测、YIELD 与 SCTLR 掩码收敛

日期：2026-08-25（Asia/Shanghai）  
前置：`065-p6-extr-deep-tail.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮关闭的 Linux 缺口

- `EXTR` 64 位拼接方向修复后，Linux 深段继续通过；
- `TPIDR2_EL0`（SME 探测）RAZ/WI；
- PSTATE immediate 的 DIT、PAN、UAO、SBSS、TCO 无副作用 shim；
- `ISR_EL1`/`DISR_EL1` RAZ/WI RAS shim；
- `SMCR_EL1` 保留 QEMU SME2 `FA64` bit31 与 LEN[3:0]；
- SCTLR 写入/读回统一只保留低 32 位，清除 QEMU P6 目标未启用的高位
  可选扩展（CMOW/MSCEN/EnFPM/BTI 等）；
- `YIELD` HINT 按顺序无副作用 NOP 接受，WFE/WFI/SEV/SEVL 仍保留事件语义
  缺口，待下一阶段专门实现。

## 2. 证据

连续恢复窗口：

- `tail-resume-ckpt12-20260825` local `999999` 后的 200000 条，跨过
  TPIDR2、DIT、PAN、SCTLR 探测；
- 同一 checkpoint 继续 1000000 条，生成绝对路径链
  `tail-resume-ckpt15-20260825`；
- 最新 1000000 条没有 PRE/COMMIT 或系统寄存器差分错误；
- `make compile`、此前 `make test`/`make checkpoint-sys-smoke`、M2-4b
  base/cache 全绿；`hard_p6_isa` 101 条覆盖 EXTR #32。

## 3. 修复提交

`0e47542 isa: close P6 SVE system probe gaps`（包含 SMCR FA64、PSTATE/RAS/
TPIDR2 shim、SCTLR 低 32 位掩码和恢复侧 SMCR 掩码）。

## 4. 下一步

从 `tail-resume-ckpt15-20260825` 最后 diff 继续长段，重点捕获第一个真正的
WFE/WFI、Generic Timer 中断或 early boot→用户空间转换。WFE/WFI 不应简单当
NOP：需要与 QEMU step 模式的等待/唤醒、IRQ 边界和 `CNT*` 状态共同验证。

