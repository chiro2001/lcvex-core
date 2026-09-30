# LCVEX 交接文档 056：Linux MMU checkpoint 联合恢复

日期：2026-08-24（Asia/Shanghai）
前置：handoff 055（checkpoint 输入与链完整性 manifest）。

## 1. 结论

已用真实 `/tmp/Image-t80000` 完成 1,000,000 条 KERNEL step 锁步，并在
seq=999999 验证了 `SCTLR_EL1.M=1` 的 checkpoint：

- 1M 窗口按每 250,000 条保存，QEMU/RTL 全部通过；
- seq=999999 的 sidecar 含非零 `TCR_EL1/TTBR0_EL1/TTBR1_EL1`，且
  `SCTLR_EL1.M=1`；
- RAM、sys/timer/GIC sidecar 注入 DUT 后，QEMU `-incoming` 与 kernel DUT
  继续执行 5 条，联合锁步返回码 0；
- 生成的链使用修正后的 QEMU SHA256，旧 QEMU 输入链会被 manifest 正确拒绝。

## 2. 首次失败与修复

第一次用旧 QEMU 二进制生成的 seq=999999 链恢复时，初始化检查报：

~~~
pc 相同；DUT SP=0x42297000，而 sys sidecar 的 sp_el1=0；
nzcv=0x8
~~~

arch 提交摘要已经保存了正确的 `0x42297000`，因此不是 RTL 注入或 MMU
翻译分歧。根因是 QEMU AArch64 在显式 SPSel 切换之间把当前工作 SP 留在
`env->xregs[31]`，`env->sp_el[1]` 可能是旧 banked copy；sys sidecar
直接读取后者。

修复：

- `qemu/patches/0002-lcvex-checkpoint-hook.patch` 在保存 sys sidecar 前
  读取 `PSTATE.SP`；
- `PSTATE.SP=1` 时保存 live `env->xregs[31]` 到 `sp_el1`，否则保存
  到 `sp_el0`；
- QEMU fork 源码已增量重建，未覆盖其余 dirty 改动。

## 3. 受控验证与资源

使用 conda 环境 `lcvex`、物理核 0、QEMU `tb-size=64`：

~~~
make lockstep-build-kernel
taskset -c 0 env IMAGE=/tmp/Image-t80000 KERNEL=1 \
  COORD=$PWD/build/verilator_lockstep_kernel/lockstep_coordinator \
  MAX_INSNS=1000000 CKPT_EVERY=250000 DIFF_CKPT=1 \
  CKPT_DIR=build/difftest/linux-1m-fixed.cR2HQ0/chain \
  bash sim/difftest/run_lockstep_step.sh
~~~

实测：

- 1,000,000 条锁步通过；
- seq=999999：`SCTLR_EL1=0x0200000034f4d91d`、`TCR_EL1!=0`、
  `TTBR0/TTBR1!=0`；
- seq=999999 QEMU/DUT 联合恢复 5 条通过；
- coordinator 约 170–270 MiB RSS，QEMU 约 135 MiB RSS，总内存远低于
  主机 50% 预算；
- 128 MiB 原始 RAM 仅用于恢复实验并已删除，保留约 14 MiB 压缩链；
- QEMU 仍打印已知的 `Expected vmdescription section, but got 0`，不影响
  本次 `-incoming`/step 结果；没有残留 QEMU 或 Verilator 进程。

## 4. 当前状态与下一步

真实 `SCTLR.M=1` checkpoint 的基础恢复闭环已完成，但尚未证明更深处的
TLB 在途状态、Device memory 访问、Timer IRQ/WFI 和用户空间入口。下一步：

1. 以相同 manifest/资源策略向约 14.8M 受控推进，优先每 1M 保存；
2. 若出现新分歧，保留最近压缩链、sys/arch 摘要和 `step_fail.txt`，不生成
   无上限 trace；
3. 先按 handoff 057 批量闭合固定 QEMU 的只读 ID/CLIDR 清单，再处理
   memblock、GIC init、Timer IRQ、WFI/WFE、LSE/LDXP 等 Linux
   深启动缺口，进入稳定 init 后再评估 Gate E。
