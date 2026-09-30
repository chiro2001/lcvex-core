# 094 HVC#0 分歧根因：Lite 内核 panic → PSCI SYSTEM_RESET（2026-08-25）

## 结论

Lite 线在相对 seq=671978（累计约 7.07M 条）的 `HVC #0` 分歧**不是 RTL
指令错误，而是访客主动请求整机复位**：lite 内核在
`prepare_namespace → mount_root` 阶段因看不到 initramfs 而 panic，
`panic()`（`panic=-1`）触发 PSCI SYSTEM_RESET（x0=0x84000009）。
QEMU 对 SYSTEM_RESET 执行 `qemu_system_reset_request`，CPU 寄存器清零、
PC 回到 0x40000000 复位向量；RTL 的 PSCI 表不含 SYSTEM_RESET，按
NOT_SUPPORTED（-1）返回并继续 pc+4，因此产生 20 处 GPR 差异。

## 证据链

1. 失败现场 [fail.txt](../../build/tmp/r.Ztuz1g/fail.txt)：
   - PRE x0=0x84000009 → `QEMU_PSCI_0_2_FN_SYSTEM_RESET`；
   - PRE pc=0xffffffc08001c224、insn=0xd4000002（HVC #0）；
   - QEMU post：x0..x30、sp 全 0，next_pc=0x40000000（RAM 基址复位向量）；
   - DUT commit：gpr_we rd=x0 wdata=0xffffffffffffffff，next_pc=pc+4。
2. [qemu.log](../../build/tmp/r.Ztuz1g/qemu.log)：
   `Kernel panic - not syncing: VFS: Unable to mount root fs on
   unknown-block(0,0)`，`No filesystem could mount root, tried:`（空列表），
   `Warning: unable to open an initial console`。
3. QEMU 11.1.0 `target/arm/tcg/psci.c`：
   `case QEMU_PSCI_0_2_FN_SYSTEM_RESET: qemu_system_reset_request(...)`。
4. RTL [lcvex_decode.sv](../../rtl/lcvex_decode.sv) HVC 分支：
   与 QEMU PSCI 表对齐但只含 VERSION/FEATURES/MIGRATE_INFO_TYPE/
   AFFINITY_INFO/CPU_ON，未知函数（含 SYSTEM_RESET/SYSTEM_OFF）返回 -1。

## Lite 内核为什么 panic（rootfs 缺失）

- lite 内核配置含 `CONFIG_BLK_DEV_INITRD=y` 与
  `CONFIG_INITRAMFS_SOURCE`（`build/tmp/linux-lite-6.6/initramfs.list`，
  静态 `/init` 打印 `LCVEX linux-lite /init ready` 后循环 pause()）。
- 首跑（P1 trace）确实带 initramfs（`lite-trace-qemu.log` 显示
  `rdinit=/init`）。
- 恢复续跑时 QEMU 在 machine init 阶段会把 `-kernel/-dtb/-initrd` 重新
  写入共享 RAM 文件（覆盖 checkpoint RAM 中已被 QEMU 修补过的 DTB）；
  若续跑未传 `-initrd`，`chosen` 节点就没有 `linux,initrd-start/end`，
  内核跳过 initrd → rootfs 挂载失败 → panic。
- `run_lockstep_resume.sh` 的 `-initrd` 是可选参数（`[[ -n "$INITRD" ]]`），
  本次 post-crc32 续跑未传 INITRD，且 `KERNEL_APPEND` 用了默认
  `rdinit=/bin/sh`（与首跑 `rdinit=/init` 不一致）。

## 修复方案（待用户确认后实施）

### A. Lite 线续跑恢复 initramfs 可见性

```sh
CHAIN=build/tmp/linux-lite-6.6/crc32-after-20260825/chain \
RESUME_SEQ=1399999 \
INITRD=build/tmp/linux-lite-6.6/initramfs.cpio \
KERNEL_APPEND='console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/init nokaslr panic=-1' \
MAX_INSNS=<窗口大小> PIN=<核> bash sim/difftest/run_lockstep_resume.sh
```

- `INITRD` 传原始 cpio（`initramfs.cpio`），避免 gzip 探测的额外不确定性；
  内容与首跑一致，地址由 QEMU 按相同 kernel/dtb 布局决定，不引入差异。
- `rdinit=/init` 与首跑、build 脚本默认保持一致。
- 验收：console 出现 `LCVEX linux-lite /init ready`，期间逐指令锁步通过，
  随后 /init 循环 pause() 长稳。

### B. PSCI SYSTEM_RESET/SYSTEM_OFF 的差分协议策略

即使修好 rootfs，未来任何 panic（新 ISA/MMIO 缺口）或干净的
poweroff 都会再次触发该分歧，因此需要协议级语义：

1. QEMU plugin 在 HOSTCALL discon 回调中用 `last_pre_state.x0` 分类
   PSCI 函数：SYSTEM_RESET（0x84000009/0xC4000009）、SYSTEM_OFF
   （0x84000008/0xC4000008）视为“访客请求复位/关机”。
2. 协调器把该事件定义为窗口终止条件：本窗口已到里程碑则判 PASS，
   未到则记录原因停止，不再比较后续指令。
3. 严格差分原则不变：不得跳过 HVC、不得忽略寄存器差异；只是把
   “访客请求整机复位”作为合法的窗口结束点。RTL 对 SYSTEM_RESET 的
   NOT_SUPPORTED 返回不再参与比较。
4. 真实复位语义（两侧回复位向量继续差分）留到未来需要时再做，本阶段不做。

## 实施约束

- 改动使用 `apply_patch`；功能提交独立（QEMU plugin/协议、runner 文档、
  RTL 若有调整各成提交）。
- 不引入对 QEMU runtime MMIO 的依赖；不因本问题放宽 IRQ/异常严格比较。
- 新 checkpoint 保存到 `build/tmp`，不写 `/tmp` 大文件。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,200p' docs/handoffs/094-hvc-system-reset-lite-rootfs-20260825.md
cat build/tmp/r.Ztuz1g/qemu.log
sed -n '150,200p' rtl/lcvex_decode.sv
```
