# Linux 支持计划

> 2026-09-27：B25 真板 CoreMark 后的执行规划见
> [Linux 板级启动计划](LINUX_BOARD_BOOT_PLAN.md)，覆盖当前 SoC 缺口、板级仿真、
> DDR 加载、Flash/JIC 制作与冷启动交互。以下保留 P6 历史架构和仿真背景，
> 其中 QEMU 的 PL011、1 GHz 计时和加载地址不直接适用于当前板级设计。

## 目标

最终支持 AArch64 Linux。Linux 不是早期标量核心的入口条件，而是 MMU、异常、Cache、计时器和中断系统稳定后的集成目标。

## 必需架构功能

- AArch64 EL1/EL0
- 同步异常和 `ERET`
- 4 KiB 页表和 MMU
- I/D Cache 与统一 L2
- 原子指令或等价独占访问
- `DMB/DSB/ISB`
- Generic Timer
- IRQ 和中断返回
- `WFI`
- 必要的 EL1 系统寄存器

## 内存模型（P6 已完成）

- RTL RAM 从 1 MiB SRAM（0x44000000..0x44100000）扩展为 128 MiB
  （0x40000000..0x48000000），与 QEMU `virt` 默认 RAM 完全对齐；
- 差分测试程序基址**保持 0x44000000**（数据区 0x44080000）：QEMU 11.1.0
  的 virt 机器在 `machine_done` 无条件把 DTB 写入 0x40000000（实测
  0x40000000..0x40100000），程序基址必须避开；
- 后续 Linux 内核镜像加载地址为 0x40080000（QEMU `-kernel` 约定：
  DTB 限界在镜像低地址之前，不重叠），见 handoff 035。

## PL011 UART（P6 已完成）

- MMIO 路由 + `lcvex_pl011`（QEMU 11.1.0 语义复刻）已实现并差分验证
  （handoff 036）：`UARTDR/FR/CR/LCR_H/IBRD/FBRD/RIS/MIS/ICR/IMSC/
  DMACR/RSR/ID`，TX 中断、LBE 回环 RX FIFO、FEN 深度；
- Linux earlycon（`earlycon=pl011,0x09000000`）所需的 FR 轮询 + UARTDR
  写入路径已可用；下一步接 Generic Timer 与 GICv2。

## Generic Timer（P6 已完成）

- `CNTPCT/CNTVCT/CNTP_*/CNTV_*` 已实现并差分验证（handoff 037）；
  QEMU 锁步统一加 `-icount shift=0` 保证计数器确定性；
- Linux `arch_timer` 驱动所需：CNTFRQ 读（1GHz）、CNTPCT 校准、
  CNTP_TVAL/CTL 触发与 mask 已可用；中断线已引出（接 GICv2 后生效）。

## GICv2（P6 已完成）

- `lcvex_gic`（GICD/GICC 寄存器 + SGIR/IAR/EOI + 优先级选路）已实现并
  差分验证（handoff 038）；核心异步 IRQ 入口（+0x280/0x80/0x480）与
  QEMU fork 的 step 模式 async COMMIT 已打通；
- Linux irq-gic.c 初始化所需（CTLR/ISENABLER/IPRIORITYR/ITARGETSR(单核
  RAZ)/ICFGR/IGROUPR + GICC_CTLR/PMR/BPR）与 timer PPI 27 触发路径
  已可用；下一步 Device Tree（GIC/定时器/串口节点）与 PSCI。

## C++ MMIO fabric / PL031（P6 已完成首个模型）

- 原生 RTL 保留 GIC、Generic Timer、PL011 与 PL061；PL031、fw_cfg、virtio
  等 QEMU virt 外设通过 `lcvex_mmio_fabric` 接入 Verilator 链接的 C++ model，
  不能让同一锁步 QEMU 反向充当 DUT 的同步 MMIO 从端；
- PL031 `0x09010000` 已支持 ID、计数/装载/匹配/中断寄存器，定向锁步在无
  Cache 与 I/D L1+L2 均通过。runner 固定
  `-rtc base=2000-01-01T00:00:00,clock=vm`，以虚拟时间保障可重复；
- C++ fabric 状态作为差分 checkpoint 的 `.dev.mmio.gz` sidecar 保存和恢复。
  旧链没有该文件时仍可作历史定位，但不可以作为 PL031/future C device 的
  联合恢复证据；
- Lite 从 `long-ldpsw-v2-20260825` 的 `seq=3199999` 恢复后已经额外锁步
  100,000 条，跨过 PL031 PID0 的原始阻塞访问。下一实际平台缺口由新的
  长窗口继续定位，优先按 C++ fabric 扩展，不新增 PL031 SystemVerilog。

## Device Tree（P6 当前阶段）

确定性 DTB 由 `scripts/validate_virt_dtb.py` 生成和校验：固定
`virt,gic-version=2,dtb-randomness=off`，去除 QEMU 的 1 MiB 填充，检查
128 MiB RAM、PL011、GICD/GICC、Generic Timer、PSCI HVC 和单核 CPU 节点，
并输出 compact DTB 的 SHA256。入口：

```bash
make dtb-smoke
```

KERNEL 锁步模式仍导出 QEMU `-kernel/-append` 实际使用的 FDT（因为 bootargs
会被 QEMU 写入），但导出命令和临时文件已固定在 `build/difftest/`，不再把
1 MiB 原始 DTB 长期放在 `/tmp`。协调器双镜像布局保持：bootloader
`0x40000000`、Image `0x40080000`、DTB `0x44000000`。

## 内核启动 trace（P6 实证循环，见 handoff 039）

- QEMU 侧内核已启动到 "alternatives: applying system-wide alternatives"
  （800k 指令），说明外设（UART/timer/GIC）与系统寄存器已覆盖内核早期
  初始化；新实证缺口 LDUR/STUR 族与 CSET 别名已关闭；
- 启动基建：`dumpdtb` 提取 DTB 并 `dtc` 重编译去填充、Image 头部
  text_offset 补丁为 0x80000（内核加载 0x40080000、DTB 0x40000000）；
- 下一步：协调器双镜像加载（内核+DTB）+ RESET_PC=0x40080000 变体 ->
  内核锁步差分（Gate E 核心步骤）。

## 推荐平台接口

优先提供接近 QEMU `virt` 的平台：

- PL011 兼容 UART
- ARM Generic Timer
- GICv2 兼容接口，后续再评估 GICv3
- Device Tree
- 简化 PSCI

## Bring-up 顺序

```text
裸机汇编
  → 裸机 C 和 UART
  → RTOS
  → Linux head.S
  → early console
  → MMU/页表初始化
  → timer/IRQ
  → init
```

每一步都需要保留最小可复现镜像和 QEMU/RTL 日志。

## 早期限制

- 不在无 MMU、无异常、无中断阶段尝试启动 Linux。
- 先完成架构状态和内存系统，再接入操作系统。
- 第一个 Linux 版本只要求单核和串口控制台，不要求完整设备树和高性能 I/O。
