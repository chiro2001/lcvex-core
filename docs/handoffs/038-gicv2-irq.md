# LCVEX 交接文档 038：GICv2 + 异步 IRQ 入口（P6 平台第三外设）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 037（Generic Timer）。

## 1. QEMU GICv2 探针实证

- virt 默认 GICv2（TCG 单核）；GICD=0x08000000（64 KiB）、
  GICC=0x08010000（64 KiB）；
- 复位值：GICD_CTLR=0、TYPER=0x8、IIDR=0x43b、ISENABLER0=0xffff
  （仅 SGIs 使能）、ITARGETSR=0（**单核 RAZ/WI**）、ICFGR0=0xaaaaaaaa
  （16 SGI 全 edge）、ICFGR1=0、IPRIORITYR=0、IGROUPR=0；
  GICC_CTLR/PMR/BPR=0、ABPR=1、IIDR=0x2043b、IAR/HPPIR=0x3ff、
  RPR=0xff（空闲）；
- 语义要点（QEMU arm_gic.c）：SGIs 的 ISENABLER 写强制 0xff、
  ICENABLER/ISPENDR/ICPENDR 写强制忽略；ICENABLER/ICPENDR 读返回
  enabled/pending；`gic_get_best_irq` 低优先级值优先、低编号破平；
  current_pending 需 best_prio < PMR；IRQ 线 = best_prio < PMR &&
  best_prio < running_priority && GICD/GICC 组使能；IAR 确认置
  active/清 pending，EOIR 清 active。

## 2. QEMU fork：step 模式异步异常

- `lcvex_difftest.c` vcpu_discon：kind==2（IRQ/FIQ）由“视为失败”改为
  转为 COMMIT，`pending_exc_code = 0x40`（协议专用码，非 ESR.EC，
  ESR/FAR=0），与 RTL `EXC_IRQ` 一致；
- 无需重建 QEMU（fork 已含 async note），仅重编译插件。

## 3. RTL 实现

- **`rtl/lcvex_gic.sv`**：GICD/GICC 寄存器 + CPU 接口选路（best_irq/
  group_prio/running_prio/current_pending/IRQ 线），单核无安全；
  `level_ppi[1:0]` 电平输入（PPI 26/27 <- timer IRQ）；
- **路由器**：新增 MMIO2 端口（GIC 窗口 0x08000000..0x08020000）；
- **核心 IRQ 入口**：`irq` 输入；`irq_taken = irq && !daif.I &&
  commit_fire && !memwb_exc && !fetch_merge_wb`；提交覆盖为异步异常
  （ELR=下一条、SPSR=当前 PSTATE、PSTATE->EL1h+DAIF、向量
  +0x280/0x80/0x480、exc_code=0x40），IF 重定向到 IRQ 向量；
- decode/core 增加第二 MMIO 窗口（GIC）放行 MMU 关闭访存并强制
  不可缓存。

## 4. 验证

- `hard_gic` 定向锁步 50 条：复位值、SGIR/IAR/HPPIR/EOIR/RPR、
  ISENABLER/ICENABLER（含 SGI 强制语义）、优先级、IGROUPR；
- `hard_irq` 定向锁步 30 条：GIC 使能 + SGIR + DAIF.I 清 ->
  VBAR+0x280 入口 -> handler 读 IAR/EOI -> ERET，与 QEMU（fork async
  COMMIT）完全一致；
- 既有 hard_timer/hard_uart/random_smoke 在 GIC 接入后全部 PASS；
- `make test` 全绿；
- **Gate D 全量 PASS**（`build/logs/gate_d_p6_gic_20260824_054041.log`）：
  111 个 OK(green) 步骤、0 失败——M2-4b 23 组（含 hard_gic/hard_irq）×
  base/cache、delay2 并行 24 项、P5a-Hardening、Gate C/P5a/P4b、
  随机 300,007 条、覆盖记账、baremetal-C。

## 5. 关键命令

```bash
make -C qemu/plugins
IMAGE=build/difftest/hard_gic.bin MAX_INSNS=50 \
  COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh
IMAGE=build/difftest/hard_irq.bin MAX_INSNS=30 \
  COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh
```

## 6. 已知限制与下一步

- IRQ 只在普通 WB 提交边界取走（MSR/ERET 等 sys 提交后不抢占，下一
  普通指令边界补取）；FIQ 未实现（GICC_CTLR.FIQ_EN=0）；
- GIC 未建模的边角：SPI 电平输入（外部设备线）、预emption 嵌套
  （running_priority 组合计算支持单层活动）、SGI 目标过滤器 0b01/0b10
  在多核语义；
- **P6 剩余**：Device Tree（GIC/定时器/PL011 节点）→ PSCI → Linux
  early boot（Gate E）。
