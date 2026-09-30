# 099 QEMU 无 FP CPU 补丁与 RTL ID 参数化（2026-08-25）

前置：handoff 095（lite 标量线）、098（lite 启动三处 RTL 修复）
分支：`feature/p6-system-reg-shim`

## 背景

内核上下文切换无条件执行 `fpsimd_save/load_state`（STP/LDP Q0-Q31、
MRS FPSR/FPCR），即使无 FP 使用者。标量核未实现 FP（P7 路线图），
因此 lite 线改用无 FP 的 QEMU CPU：`system_supports_fpsimd()` 为假时
内核完全跳过 FP 代码（`fpsimd_thread_switch` 直接 return）。

## QEMU fork 补丁 0011：AArch64 暴露 vfp-d32 属性

`-cpu max,vfp=off,neon=off` 会报
`ARM CPUs must have both VFP-D32 and Neon or neither`：AArch64 只暴露
`vfp` 属性，`vfp-d32`（默认 true）不可关。补丁
`qemu/patches/0011-lcvex-aarch64-vfpd32-off.patch` 在 AArch64 TCG 分支
同时注册 `vfp-d32` 属性，使
`-cpu max,has_el3=false,has_el2=false,vfp=off,neon=off,vfp-d32=off`
可用。验证：内核打印 `Advanced SIMD is not implemented` 且
`Run /init as init process`（纯标量路径）。

## RTL：A64_FP_SIMD 参数化 ID 寄存器

无 FP 时 QEMU 的 ID 寄存器值变化（`target/arm/cpu.c` 按字段清零）：

QEMU 无 FP 的 ID 值**按 FEAT 依赖批量清零**（手算会漏，须以
`-cpu max,vfp=off,...` 实证抓取为准；本表为实证值）：

| 寄存器 | FP-on | FP-off（实证） |
| --- | --- | --- |
| ID_AA64PFR0_EL1 | 0x1301001120110022 | 0x1301001120ff0022 |
| ID_AA64ISAR0_EL1 | 0x1221111110312120 | 0x1220000010310000 |
| ID_AA64ISAR1_EL1 | 0x0111211110211502 | 0x0101011010200502 |
| ID_ISAR5_EL1 (A32) | 0x11011121 | 0x00010001 |
| ID_ISAR6_EL1 (A32) | 0x01111111 | 0x00011000 |
| MVFR0/1/2 (A32) | 0x10110222/0x13211111/0x43 | 全 0 |

其余 ID 寄存器（PFR1/2、DFR0/1、AFR0/1、ISAR0-4、MMFR0-5、ZFR0、
FPFR0）在 FP-off 下与 FP-on 相同（RTL 已按 QEMU max 对齐）。

实现：

- `lcvex_pkg.sv`：新增 `*_NOFP_VAL` 常量；
- `lcvex_decode.sv` / `lcvex_core.sv` / `tb/sv/lcvex_soc_tb.sv`：
  `A64_FP_SIMD` 参数（默认 1），MRS 返回按参数选择；
- `Makefile`：`lockstep-build-kernel-nofp`（`-GA64_FP_SIMD=0`）→
  `build/verilator_lockstep_kernel_nofp/lockstep_coordinator`；
- `run_lockstep_step.sh`：新增 `QEMU_CPU` 环境（导出 FDT 与主 QEMU
  共用），并提高协调器等待上限到 60 分钟（长首跑）。

实证工具：`build/tmp/id_dump*.bin`（QEMU 无 FP 下 MRS 全部 ID/MVFR
寄存器并转储），避免手算字段遗漏。

## 使用

```sh
make lockstep-build-kernel-nofp
KERNEL=1 QEMU_CPU='max,has_el3=false,has_el2=false,vfp=off,neon=off,vfp-d32=off' \
  COORD=build/verilator_lockstep_kernel_nofp/lockstep_coordinator \
  ... bash sim/difftest/run_lockstep_step.sh
```

## 约束与后续

- lite 线固定无 FP；主线保持 `-cpu max`（FP-on）与
  `verilator_lockstep_kernel`。
- P7 实现 FP/NEON 时：RTL 加 FP 寄存器堆与 FP 指令，difftest 协议
  比较 v0-v31，QEMU_CPU 恢复默认（或按线配置），ID 参数回到 FP-on。
- QEMU patch 0011 以 `qemu/patches/` 管理，可在干净 11.1.0 上重放。

## 压缩后的首条命令

```sh
git status --short --branch
head -40 qemu/patches/0011-lcvex-aarch64-vfpd32-off.patch
sed -n '1,200p' docs/handoffs/099-qemu-nofp-scalar-line-20260825.md
```
