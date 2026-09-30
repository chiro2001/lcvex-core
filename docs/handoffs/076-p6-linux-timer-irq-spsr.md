# LCVEX 交接文档 076：P6 Linux checkpoint Timer IRQ 与 SPSR 收敛

日期：2026-08-25（Asia/Shanghai）
前置：`075-p6-wfxt-verified.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮定位与修复

从 `build/difftest/casp-debug-20260825` 的 `RESUME_SEQ=499999` 复验时，
首先确认 Linux 恢复点后普通 `EOR` 不再停顿；原因为 QEMU incoming 后 raw
virtual clock 与 timer sidecar 可有小的有符号偏移。修复内容：

- QEMU patch 0006：timer deadline 使用模 2^64 的 offset 换算；保留
  `UINT64_MAX` 已触发远期哨兵，避免 timer callback 自旋；
- QEMU patch 0007：Generic Timer callback 后显式 kick step vCPU；
- RTL Timer IRQ 用 `cntpct_r+1`（本条提交后的可见计数），与 QEMU 在
  CVAL 到期指令边界生成 ASYNC IRQ 的时序一致；
- IRQ 提交时冲刷取指在途状态和 IF/ID，避免旧顺序取指阻塞 IRQ 向量；
- checkpoint 注入和异常保存/ERET 恢复 `PSTATE.PAN`（bit22）与 `DIT`
  （bit24），对齐 Linux handler 的 `MRS SPSR_EL1`。

## 2. 验证证据

```text
make p6-wfi                                  PASS（base/cache）
Linux RESUME_SEQ=499999 MAX_INSNS=6000       PASS
Linux RESUME_SEQ=499999 MAX_INSNS=100000     PASS
Linux RESUME_SEQ=499999 MAX_INSNS=1000000    PASS
```

6000 条窗口明确越过：

```text
Timer PPI27 到期 → ASYNC IRQ → VBAR+0x280 → IRQ handler → ERET
```

1,000,000 条窗口最后记录 `seq=999999 OK`，无 PRE/COMMIT 差分错误。相对于
此前约 28.5M 后的 WFI/Timer 边界，当前从该 checkpoint 续跑后的可验证
全局进度约为 **30M 条动态指令**；全局数仍以近似值对外报告，不能把
checkpoint 局部 seq 直接相加为精确编号。

## 3. 验证基础设施增强

`run_lockstep_resume.sh` 新增可选环境变量：

- `TIMEOUT_MS`：协调器 socket 等待超时；
- `MAX_CYCLES_PER_INSN`：DUT 单条指令周期上限；
- `QEMU_DEBUG`：QEMU `-d` 类别，日志存入本次运行目录；
- `SKIP_TIMER_RESTORE=1`：仅用于诊断，不得作为正式通过条件。

协调器在 EOF/超时/单条指令不提交时保存 PRE、DUT commit（若有）和
流水线/MMU/Timer/IRQ 现场，不调用 tick，避免诊断改变锁步结果。

## 4. 当前工作区与下一步

根仓库包含上述 RTL、协调器、脚本、文档和 QEMU patch 0006/0007 的未提交
改动；`../qemu` 固定为 11.1.0，dirty 内容为预期。临时 QEMU/plugin 调试
打印已删除。提交前须运行 `git diff --check`、`make test`、`make m2-4b`、
`make p6-lse` 和 `make p6-wfi`，并验证 0001..0007 在干净 QEMU 基线上的
顺序重放。

下一步从新的 100000 条通过边界继续 Linux 长段，目标是稳定 early boot、
用户空间 `/init`；随后处理真实轨迹中的 LSE128 其他操作族和剩余系统寄存器。
