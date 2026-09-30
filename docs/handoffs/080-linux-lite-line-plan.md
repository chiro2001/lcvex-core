# LCVEX 交接文档 080：Linux lite 异步验证线计划

日期：2026-08-25（Asia/Shanghai）
前置：`079-p6-smulh-linux-gap.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 当前主线状态

- 主线固定输入：`/tmp/Image-t80000`、QEMU 11.1.0 `84f0721`、当前 7 个
  QEMU patch；主线不被 lite 构建覆盖；
- 已通过三段各 1M 的 Linux checkpoint 长跑，保守进度约 **31M** 动态指令；
- OSDLR/OSLAR 已关闭，`hard_p6_isa` 104 条 base/cache 通过；
- Linux 在第四段局部 `seq=527841` 遇到 `SMULH x1,x3,x1`，SMULH RTL 和
  `hard_madd` 43 条 base/cache 已通过，但修复后的 Linux 续跑尚未执行；
- 失败现场：`build/difftest/resume-run.zytvoA`；下一主线入口仍为
  `build/difftest/linux-timer-irq-3-20260825/diff-999999`，不要从失败点
  直接伪造恢复。

## 2. 新增 Linux lite 线目标

lite 线使用同一 RTL/QEMU 协议和同一 ISA 实现，但独立构建、独立 Image、
独立 DTB/checkpoint 目录，用于秒到分钟级的“checkpoint → 单缺口修复 →
续跑”循环。它不是主线结果的替代品，主线仍用于真实 Linux 长段和最终 Gate E。

建议固定 artifact 命名：

```text
build/linux-lite-6.6/                 # 内核 O= 输出，不改 build/linux-6.6
build/tmp/linux-lite-6.6/Image        # lite 临时/发布 Image
build/tmp/linux-lite-6.6/initramfs    # 最小静态 /init initramfs
build/difftest/linux-lite/            # runner 使用的稳定副本/manifest
build/difftest/linux-lite/<chain>/    # 每次独立压缩 checkpoint 链
build/tmp/linux-lite-6.6/qemu-lite-fdt-raw.bin # lite 专属确定性 DTB
```

## 3. 最小配置边界

从 Linux 6.6 `allnoconfig` 生成，再应用仓库中的 lite fragment；只打开：

- AArch64、4 KiB 页、MMU、单核运行（Linux 6.6 arm64 强制 `SMP=y`，最终
  配置 `NR_CPUS=2`，DT 仅提供 CPU0）；
- Device Tree、GICv2、ARM Generic Timer；
- PL011/AMBA 串口和 console、`PRINTK`/`TTY`；
- `BLK_DEV_INITRD`、ELF、`DEVTMPFS`、`TMPFS`、`PROC_FS`/`SYSFS`；
- futex/posix timers/high-res timers、必要的 syscall 基础；
- LSE atomics；

显式关闭：网络、PCI、VirtIO、块设备、模块、EFI/ACPI、KVM、SVE/SME、
NEON/FP、MTE、Pointer Authentication、随机化基址和调试信息。若某项被
Kconfig 依赖自动打开，以最终 `build/linux-lite-6.6/.config` 为准并记录
差异，不手工覆盖 Kconfig 结果。特别是 `SMP=y`/`NR_CPUS=2` 是 Linux 6.6
arm64 的硬性约束，不将其误记为 CPU 微架构已支持多核。

## 4. 并行与资源规则

- 主线长跑绑定物理核 0；lite 短跑绑定另一个物理核（默认核 1）；
- QEMU/Verilator 各自单核，两个运行线合计不超过主机 50% CPU 和可用内存；
- 任一线启动前检查 `build/tmp` 所在根文件系统与 `/tmp`；新的 128 MiB RAM
  backend、DTB、initramfs 和压缩链写入 `build/tmp`/`build/difftest` 各自目录，
  禁止共享 `ram.bin`、socket、日志或 manifest；历史主线 `/tmp/Image-t80000`
  仅作为已绑定输入保留；
- 构建阶段最多 6 线程，主线长跑与内核构建不同时占满内存；资源不足时排队；
- 每 100,000 条保存一个 diff checkpoint，链大小超过项目上限立即停止发布。

这里的“50%”按物理核槽位解释，而不是把一个单核进程拆到多个核：本机
`lscpu` 报告 12 个物理核（每核 1 线程），所以本地最多同时占 6 个槽位；
单次 QEMU/Verilator 锁步仍固定在 1 个核，额外核只能用于独立测试实例或构建。
当前空闲探测约有 0.38 个核的系统负载，故规划器给出 5 个可立即使用的
slot；启动 main+lite 后应显式保留 2 个 slot，余下约 3 个 slot 给短测试。
可用内存约 19 GiB；`build/tmp` 位于根文件系统（约 81 GiB 可用），而 `/tmp`
只有约 6.5 GiB。checkpoint/RAM backend 的磁盘上限仍优先于内存上限。

当前实测（无 LCVEX 后台任务）`scripts/test_planner.sh` 输出：本地
`cpu_slots=6`、扣除 loadavg 后 `parallel=5`、绑定 `[0,1,2,3,4]`；CI
`parallel=8`、绑定 `[0..7]`。因此 lite 线启动后，主线和 lite 各占一个
slot，仍可保留约三个 slot 做独立定向/随机锁步；构建任务需排队，不能与
多个 Verilator 长跑同时占满 6 个构建线程。

## 5. 压缩后下一步执行顺序

1. 新增 `configs/linux-lite-6.6.fragment`、最小静态 `/init` 和
   `scripts/build-linux-lite.sh`；构建输出只写 `build/linux-lite-6.6`；
2. 让 kernel step/resume runner 接受可选 `INITRD`，为 lite 生成并绑定专属
   DTB、Image/initramfs SHA256；含 initramfs 时使用 QEMU 的
   `BOOT_DTB=0x44200000`、无 text offset Image 的 `BOOT_ENTRY=0x40200000`；
   主线默认参数保持不变；
3. 运行 lite 从 reset 的 10k～50k 条短锁步，启用每 10k/100k 的压缩
   checkpoint；失败时先在 lite 线补实现+定向测试，再从最近 checkpoint 续跑；
4. 同时从主线 `linux-timer-irq-3-20260825/diff-999999` 重新续跑，确认
   SMULH 后的 1M 窗口；两线日志、链和失败现场分开；
5. lite 达到 `/init` 后，再用它做 ISA/异常/MMU 回归；主线达到用户空间后
   才评估 Gate E，不把 lite 通过当作主线 Gate。

## 6. 交接时的首条命令

```bash
git status --short --branch
ps -eo pid,ppid,stat,etime,pcpu,pmem,args | rg -i 'qemu|verilat|lockstep' || true
df -h build/tmp /tmp .
```

然后阅读本文件、`079-p6-smulh-linux-gap.md`、`docs/ROADMAP.md` 和
`docs/PROJECT_STATUS.md`，先实现 lite 构建入口，再启动任一长跑。
