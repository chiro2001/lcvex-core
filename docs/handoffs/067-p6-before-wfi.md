# LCVEX 交接文档 067：P6 系统探测收敛与 WFE/WFI 前入口

日期：2026-08-25（Asia/Shanghai）  
前置：`066-p6-sysprobe-yield-tail.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮状态

继续从 `tail-resume-ckpt12-20260825` 深段恢复，关闭并验证了：

- YIELD HINT 顺序 NOP；
- DIT、PAN、UAO、SBSS、TCO immediate PSTATE shim；
- ISR_EL1/DISR_EL1 RAZ/WI；
- TPIDR2_EL0 RAZ/WI；
- SMCR_EL1 FA64 bit31 保留；
- SCTLR 读写统一保留低 32 位，清除 P6 未实现的高位可选扩展。

从 ckpt12 继续的 200k、500k、1M 窗口均通过，生成了
`tail-resume-ckpt15/16/17-20260825` 绝对路径链；累计约 26M 指令未出现
新的 PRE/COMMIT 或系统寄存器差分。最终 `make m2-4b` base/cache 全绿，
`hard_p6_isa` 101 条、`hard_gic` 52 条通过。

## 2. 已知下一缺口

Linux feature probe 已报告 WFx with timeout，但当前仍未实现真正事件等待：

- WFE/WFI/SEV/SEVL 仍被 decoder 保留为未实现事件语义；
- QEMU step 模式对 WFI/WFE 的暂停、IRQ/事件唤醒和 `CNT*` 计时边界需要
  与 DUT 协议共同定义；
- 下一次真实遇到 `WFI`/`WFE` 时，不能简单照 YIELD 当 NOP，应加入可复现的
  idle 状态、Timer/GIC 唤醒测试，并保持每条 QEMU PRE 与 DUT commit 对齐。

## 3. 下一步入口

从 `tail-resume-ckpt17-20260825` 的 `diff-999999` 恢复，使用新的绝对输出
目录继续；优先抓取第一个 WFI/WFE 及前后 Generic Timer IRQ。当前仍未宣称
Gate E 完成，PAuth 也仍只是 P6 difftest shim。

