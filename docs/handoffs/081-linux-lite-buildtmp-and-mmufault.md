# LCVEX 交接文档 081：Linux lite 构建与 build/tmp 资源盘

日期：2026-08-25（Asia/Shanghai）
前置：`080-linux-lite-line-plan.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 资源与临时目录

- 主机实测 12 个物理核、约 30 GiB 可见内存（用户侧约 32 GiB）；本地测试
  上限 50%，规划器空闲时给出 6 个槽位，扣除约 0.38 loadavg 后通常为 5；
- 单次 QEMU/Verilator 锁步绑定 1 个物理核，增加核数不会加速单次运行；
  main+lite 各占 1 槽位，其他槽位用于定向/随机测试或构建；
- 根文件系统 `build/tmp` 所在盘约 81 GiB 可用，`/tmp` 仅约 6.5 GiB；新的
  Image/initramfs/DTB/checkpoint 临时产物使用 `build/tmp`，历史主线
  `/tmp/Image-t80000` 保持不动；
- `scripts/test_planner.sh` 新增 `--reserve-slots=N`，并行 runner 可在
  main/lite 刚启动时显式保留槽位，资源不足仍可 `--wait` 排队。

## 2. 已实现的 lite 构建入口

新增：

- `configs/linux-lite-6.6.fragment`；
- `baremetal/linux-lite/init.S`（无 libc 静态 PID 1，write 后 pause 循环）；
- `scripts/build-linux-lite.sh`（独立 O= 输出、initramfs、SHA256、发布副本）。

Linux 6.6 arm64 的 `SMP` 在 Kconfig 中是 `def_bool y`，不能设置为 n；最终
配置实证为 `SMP=y, NR_CPUS=2`（`NR_CPUS` 合法下限为 2），DT 仍只提供 CPU0，
因此这不表示 LCVEX 微架构进入多核。

构建命令与结果：

```text
WAIT_FOR_RESOURCES=0 JOBS=5 RESERVE_SLOTS=0 scripts/build-linux-lite.sh
PASS
build/tmp/linux-lite-6.6/Image             4.5 MiB
build/tmp/linux-lite-6.6/initramfs         585 B
build/linux-lite-6.6/.config               SMP=y, NR_CPUS=2
```

稳定副本位于 `build/difftest/linux-lite/`；构建脚本没有修改
`build/linux-6.6/.config`。

## 3. runner 改动与 lite 短锁步结果

`sim/difftest/run_lockstep_step.sh` 和 `run_lockstep_resume.sh` 已支持可选
`INITRD`，并将 `BOOT_DTB`、`BOOT_ENTRY` 参数化。加入 initramfs 后 QEMU 的
FDT 地址是 `0x44200000`；lite Image 的 header `text_offset=0`，QEMU 因
bootloader 保留区把入口放在 `0x40200000`。主线默认地址保持
`0x44000000/0x40080000`。

lite 10k 锁步命令（固定物理核 1）：

```bash
taskset -c 1 env KERNEL=1 \
  IMAGE=$PWD/build/difftest/linux-lite/Image \
  INITRD=$PWD/build/difftest/linux-lite/initramfs \
  BOOT_DTB=0x44200000 BOOT_ENTRY=0x40200000 \
  KERNEL_DTB=$PWD/build/tmp/linux-lite-6.6/qemu-lite-fdt-raw.bin \
  KERNEL_DTB_REGEN=1 MAX_INSNS=10000 \
  bash sim/difftest/run_lockstep_step.sh
```

结果：启动 bootloader、内核加载和前 1573 条提交一致；在
`seq=1573, PC=0x4051435c, MSR SCTLR_EL1,x0 (d5181000)` 分歧：

- QEMU 正常退休，`next_pc=0x40514360`；
- RTL 将下一条取指合并为同级 IABT，`next_pc=0x200`、`ESR=0x86000004`。

这是真实的 lite MMU/取指翻译缺口，不把该 1573 条计入通过数。现场保留在
`build/tmp/linux-lite-6.6/run-10k-v3/fail.txt`，用于“checkpoint → 定位 →
修复 → 续跑”。

## 4. 下一步

1. 对比 seq=1573 前后的 `SCTLR/TCR/TTBR/MAIR`、TLB/PTW 和
   `fetch_next_settled`，修复 lite 的 MMU enable 后取指路径；补最小定向测试；
2. 修复后从 lite reset 续跑 10k～50k，确认 `/init`；
3. 并行从主线 `build/difftest/linux-timer-irq-3-20260825/diff-999999`
   续跑 1M，确认 SMULH 后的主线窗口；main/lite 使用不同核、socket、日志和链；
4. 每 100k 保存压缩 checkpoint，优先使用 `build/tmp` 所在盘并检查大小上限。

交接首条命令：

```bash
git status --short --branch
ps -eo pid,psr,pcpu,pmem,rss,stat,args | rg -i 'qemu|verilat|lockstep' || true
df -h build/tmp /tmp .
```
