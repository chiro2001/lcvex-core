# LCVEX 交接文档 078：P6 OSDLR_EL1 Linux 缺口关闭

日期：2026-08-25（Asia/Shanghai）
前置：`077-p6-linux-2m-after-timer.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 新缺口

从 `build/difftest/linux-timer-irq-3-20260825/diff-999999` 恢复并运行
第四条链时，局部 `seq=20243` 首次分歧：

```text
PC    = 0xffff800080095260
insn  = 0xd510139f
disas = msr osdlr_el1, xzr
```

旧 RTL 将该系统寄存器编码判为 UDEF 并跳到异常向量；QEMU 11.1.0
`target/arm/debug_helper.c` 将 `OSDLR_EL1 (S2_0_C1_C3_4)` 建模为
RAZ/WI dummy，正常顺序执行到 `pc+4`。

## 2. 修复与测试

- `sys_reg_t` 新增 `SREG_OSDLR_EL1`；
- decoder 识别 `S2_0_C1_C3_4`，MRS 返回 0，MSR 写入忽略；
- `a64.py` 增加系统寄存器编码，`hard_p6_isa` 加入 MSR/MRS 两条定向指令；
- `run_m2_4b.sh` 期望提交数由 101 更新为 103。

验证：

```text
hard_p6_isa, base       103 条 PASS
hard_p6_isa, I+D+L2     103 条 PASS
```

第四条链在该修复前的失败运行目录为
`build/difftest/resume-run.8JbDeC`；不要把该目录之后的任何条数计为通过。

## 3. 当前进度与下一步

前三条链各通过 1,000,000 条，Linux 从启动起保守约 **31M** 条动态指令
正确锁步。第四条链在 OSDLR 缺口前尚未到首个 checkpoint；下一步从
`build/difftest/linux-timer-irq-3-20260825/diff-999999` 恢复，重新续跑并每
100,000 条保存新链，继续关闭系统寄存器
或其他 ISA 缺口，目标仍是稳定 early boot 后进入用户空间 `/init`。

资源与安全约束保持：单物理核、构建最多 6 线程、优先压缩 checkpoint，
不生成全量 trace；提交前保持 `../qemu` dirty fork 不被 reset/checkout。
