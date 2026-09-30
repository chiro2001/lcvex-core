# LCVEX 交接文档 037：Generic Timer（P6 平台第二外设）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 036（PL011 UART）。

## 1. 关键方法：icount 确定性差分

- 实测 QEMU 11.1.0（TCG, thread=single）**无 icount** 时 `CNTPCT` 为宿主
  时间（相邻指令间抖动数万 ns），不可差分；
- `-icount shift=0,align=off,sleep=off` 下 `CNTPCT` **每指令 +1、完全
  确定**（探针：mrs#k 读到 k；2 个 NOP 后读值 +3）；
- 因此 QEMU 锁步/trace 统一加 `-icount shift=0,align=off,sleep=off`
  （run_lockstep_step.sh / run_qemu.py / run_q6.sh），RTL 计数器每提交
  +1 与之对齐（CNTPCT = 已执行指令数）。

## 2. 实现（rtl/lcvex_core.sv + decode）

- `cntpct_r` 每提交 +1（sys_commit 与 commit_fire 互斥，均计入）；
- MRS 定时器读值在 **EX 级**用 `cntpct_r + 1` 计算（本指令计入；
  `sys_reg` 新增携带进 ex_pipe_t）；ISTATUS 读时组合求值
  （`enable && count >= cval`，QEMU icount 定时器在指令边界精确触发）；
- `CNTP_TVAL` 读 = `(uint32_t)(cval - count)`；写 = `cval = count +
  sext32(value)`（QEMU do_tval_write）；`CNTP_CTL` 写 bits[1:0]；
  `CNTV_*` 同语义（CNTVOFF_EL2=0，CNTVCT=CNTPCT）；
- 中断输出 `timer_phys_irq/timer_virt_irq`（供 GIC，非差分提交状态）；
- 编码实证教训：`CNTP_CVAL_EL0`/`CNTV_CVAL_EL0` 的 opc2=**2**（初版
  写成 3 导致 MSR UDEF，QEMU helper.c 核对修正）；a64.py sysreg 表
  新增 8 个定时器寄存器。

## 3. 验证

- `hard_timer` 定向锁步 40 条（base/全缓存/随机延迟三档全绿）：计数器
  读、CNTFRQ、CTL enable + istatus 0->1 翻转、CVAL 原样、TVAL 截断、
  TVAL 写（sext32）、禁用清 istatus、CNTV 族、imask；
- 既有 hard_uart/hard_p6_isa/hard_big_mem/random_smoke 在 icount 下
  全部 PASS（icount 不影响 PL011 等设备语义）；
- `make test`/`make coverage` 全绿；
- **Gate D 全量 PASS**（`build/logs/gate_d_p6_timer_20260824_051840.log`）：
  105 个 OK(green) 步骤、0 失败——M2-4b 21 组（含 hard_timer）×
  base/cache、delay2 并行 22 项、P5a-Hardening、Gate C/P5a/P4b、
  随机 300,007 条（icount trace）、覆盖记账、baremetal-C。

## 4. 关键命令

```bash
IMAGE=build/difftest/hard_timer.bin MAX_INSNS=40 \
  COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh   # 已内置 -icount
python3 sim/difftest/qemu_probe.py --image build/difftest/timer_probe3.bin \
  --max-insns 24 --el1 --icount "shift=0,align=off,sleep=off"
```

## 5. 已知限制与下一步

- EL0 定时器访问的 CNTKCTL 门控（QEMU EC=0x18 trap；计数器 bit0/1、
  定时器 bit8/9）未实现，当前 EL0 统一 UDEF（与既有 EL0 sysreg 策略
  一致）；Linux 在 EL1 访问定时器，不受影响；
- **P6 剩余**：GICv2（中断控制器 + IRQ 取指路径）→ Device Tree →
  PSCI → Linux early boot（Gate E）。
