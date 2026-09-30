# 095 Lite 线 rdinit 根因与标量化（2026-08-25）

前置：handoff 094（HVC#0 SYSTEM_RESET 根因）、096（PSCI 复位协议）、
097（PSTATE.DIT）
分支：`feature/p6-system-reg-shim`

## rdinit 冻结根因（为什么旧 lite 链到不了 /init）

旧 lite 链的首跑 manifest 记录 `kernel_append=...rdinit=/bin/sh`，而
initramfs 只有 `/init`（无 `/bin/sh`）。`rdinit` 属 `__setup` 参数，只在
开机时从 DTB `chosen/bootargs` 解析一次、固化在内核内存
（`boot_command_line`）；**checkpoint 恢复时改 `-append` 不生效**。
因此旧链从源头就注定：`init_eaccess("/bin/sh")` 失败 →
`prepare_namespace → mount_root` → panic → PSCI SYSTEM_RESET。

续跑默认 `rdinit=/bin/sh` 与首跑一致（`run_lockstep_resume.sh` 默认
`rdinit=/bin/sh`），曾误以为“续跑传 INITRD 即可修复”，实际无效——
rootfs 内容在 checkpoint RAM 中完好，问题只在解析过的 rdinit。

## 修复 A：initramfs 加 /dev/console 节点

`scripts/build-linux-lite.sh` 的 initramfs.list 增加
`nod /dev/console 0600 0 0 c 5 1`。否则 `console_on_rootfs()` 打不开
`/dev/console`（`rdinit=/init` 跳过 `prepare_namespace`，devtmpfs 不挂载），
`/init` 的 write(1) 无法输出标记。

## 修复 B：无 FP 标量线（见 handoff 099）

内核上下文切换**无条件**执行 `fpsimd_save/load_state`（STP/LDP Q0-Q31、
MRS FPSR/FPCR）。标量核未实现 FP（P7 路线图），故 lite 线改用
QEMU 无 FP CPU（`-cpu max,vfp=off,neon=off,vfp-d32=off`）：
`system_supports_fpsimd()` 为假 → 内核跳过全部 FP 代码，走纯标量路径。

## 验证链

```text
lite-init-rdinit-20260825     全新首跑 8M（rdinit=/init）通过
lite-rdinit-post8m-20260825   续跑至相对 9.28M（DIT 失败，见 097）
lite-dit-cross-20260825       DIT 修复后 3M 通过
lite-to-init-20260825         2M 通过（引导后期）
lite-init-final2/final3       各 2M/3M（SP 写回、varshift、LDTR/STTR 修复）
lite-scalar2-20260825         无 FP 标量首跑（进行中，目标 /init）
```

## 约束

- 恢复续跑不能改变已固化的 `rdinit` 等 `__setup` 参数；参数变更必须
  全新首跑。
- lite 线目标是纯标量：QEMU_CPU 固定无 FP；RTL 用
  `verilator_lockstep_kernel_nofp`（A64_FP_SIMD=0）匹配 ID 寄存器。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,200p' docs/handoffs/095-lite-rdinit-scalar-line-20260825.md
tail -20 build/tmp/linux-lite-6.6/lite-scalar2-20260825/coord.log
```
