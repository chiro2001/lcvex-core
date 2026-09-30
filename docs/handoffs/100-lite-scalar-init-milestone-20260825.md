# 100 Lite 标量线到达 Linux /init（P6 里程碑）（2026-08-25）

前置：handoff 095-099（lite 标量线、PSTATE.DIT、RTL 修复、无 FP 配置）
分支：`feature/p6-system-reg-shim`

## 里程碑

纯标量 ARMv8.2 核（无 FP/NEON，`A64_FP_SIMD=0`）在逐指令 QEMU 差分
锁步下成功启动 Linux 6.6 到用户态 `/init`，console 输出：

```text
Run /init as init process
LCVEX linux-lite /init ready
```

`/init`（无 libc 静态 ELF）进入 pause() 循环后持续锁步通过
（SVC 异常入口/返回路径反复执行，全部与 QEMU 一致）。

## 本阶段 RTL 修复（commit 7ff6d55）

### 1. ERET 目标取指异常语义（lite /init 入口三连 bug）

- `sys_merge_code`/异常向量：ERET 目标取指 fault 时按**目标 EL**
  （`spsr_el1[2]`）选 EC（0x20/0x21）与向量（+0x400/+0x200），此前用
  当前 EL（1）导致向量/EC 错误；
- 保存的 SPSR：ERET 完成后取指 fault 用**恢复后的 PSTATE**
  （spsr 字段），不是旧 PSTATE；
- `mmu_access_el`：ERET 目标取指（`if_pc==elr_el1`）按目标 EL 检查
  权限（否则返回用户页 PXN=1 被误判 EL1 取指 fault；向量取指仍按
  EL1）。

### 2. PSTATE SSBS/UAO/PAN/TCO 实现

旧 decode 把 MSR immediate 的 SSBS(op2=1)/DIT(2)/TCO(4)（op1=3）与
UAO(3)/PAN(4)（op1=0）全部 lump 进 SYS_DIT。内核为用户态设置
PSTATE.SSBS（`ssbs_thread_switch`），异常入口需随 SPSR 保存 bit12；
缺失导致 `MRS SPSR_EL1` 差 0x1000。实现：

- decode：每个 op2 独立 sys_op（SYS_SSBS/TCO/UAO/PAN/DIT）与 MRS 读；
- core：`pstate_ssbs/uao/tco` 寄存器，MSR 写、异常入口清零、ERET 恢复、
  SPSR 保存（make_spsr 加 bit12/23/25）、difftest 恢复（从 sys sidecar
  pstate 字段提取）；
- 位位置：SSBS=12、UAO=23、PAN=22、DIT=24、TCO=25。

### 3. ADC/ADCS/SBC/SBCS/NGC/NGCS

内核 syscall 返回路径用 `ngc x0,xzr` 计算 -1 错误码；旧 decode 缺失
导致 UDEF。编码：`sf op[1:0] 11010000 Rm 000000 Rn Rd`
（op=00/01/10/11 = ADC/ADCS/SBC/SBCS；NGC/NGCS=Rn 31）。ALU 新增
`cin`（C 标志）与 ALU_ADC/ALU_SBC（32/64 位带进位加法器），标志按
QEMU 语义；修复 cmp_flags 三态（add/sub/其他=逻辑清零 C/V）。

## 测试

- `hard_adc_sbc`（30 条）：C=0/1 两态、W/X、NGC/NGCS；
- 既有 `hard_dit/hard_varshift/hard_ldtr_sttr/hard_psci` 回归；
- base/cache 双配置 `run_m2_4b.sh --only ...` 全绿；
- Lite 标量链从 `lite-scalar12`（绝对 ~23M）续跑跨过全部失败点，
  `/init` 稳定运行（连续 200 万条通过）。

## 链布局（lite 标量线，绝对 seq）

```text
lite-scalar2（全新首跑 8M）→ scalar4/5/6/7/8（各 2-3M）
→ scalar9/10/11/12/13（各 2M，至绝对 ~31M，/init 前）
→ scalar15-21（RTL 修复后跨过 /init 全部门槛）
→ scalar21/22：/init pause 循环稳定
```

checkpoint 链：`build/tmp/linux-lite-6.6/lite-scalar2X-*`。

## 约束与后续

- lite 线固定 QEMU_CPU 无 FP（`vfp=off,neon=off,vfp-d32=off`）+ nofp
  协调器；主线标量线（`main-scalar*`）并行推进中。
- P7 实现 FP/NEON 后恢复 FP-on 参考，移除 nofp 参数化。
- 主线（全量内核）无 initramfs，将在 mount_root panic 处由
  PSCI 复位协议（096）优雅终止。

## 压缩后的首条命令

```sh
git status --short --branch && git log --oneline -8
sed -n '1,200p' docs/handoffs/100-lite-scalar-init-milestone-20260825.md
rg -n 'LCVEX linux-lite' build/tmp/r.HcJeC1/qemu.log
```
