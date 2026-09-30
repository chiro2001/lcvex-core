# LCVEX 交接文档 064：P6 深段收敛与下一阶段入口

日期：2026-08-25（Asia/Shanghai）  
前置：`063-p6-mmio2-gicv2m-pauth.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 已完成

本轮已关闭真实 Linux 深段暴露的三组缺口：

1. MMU 合法 PA 窗口加入 GIC MMIO2 `0x08000000..0x08021000`；
2. GICv2m frame `0x08020000..0x08021000` 的 MSI_TYPER/IIDR/RAZ 读取与
   最小 SETSPI_NS；`hard_gic` 由 50 条扩展为 52 条；
3. `SCTLR2_EL1`、APIA/APIB/APDA/APDB/APGA key low/high 的 RAZ/WI shim；
   QEMU difftest 活跃时屏蔽 PAuth enable 位，PAC HINT 与 DUT NOP 对齐。

顺序核 TLB 默认扩为 64 项全相联。续跑脚本把相对 `CKPT_DIR` 规范化为绝对
路径，避免新链恢复时 manifest 重复拼接目录。

## 2. 验证证据

- `make test`：toolcheck、lint、SV/Cocotb 双轨、缓存/MMU/PL011、编码器
  检查全部通过；
- `make sim-sv-mmu`：MMIO2 定向翻译通过；
- `make checkpoint-sys-smoke`：sys sidecar v2 联合恢复 4 条通过；
- `make m2-4b`：base/cache 全部 M2/R1 定向通过，`hard_gic` 52 条一致；
- QEMU patch 在固定 `84f0721` 临时 worktree 中按 0001→0002 正向重放通过；
- P6 Linux 深段：
  - `tail-resume-ckpt7-20260825`：修复 MMIO2 后连续 500000 条通过；
  - `tail-resume-ckpt8-20260825`：继续 1000000 条通过；
  - `tail-resume-ckpt10-20260825`：QEMU PAuth shim 生效后继续 1000000 条
    通过；
  - 运行窗口已推进到约 19M 指令，未再出现 062 的假性 MSR 丢失、GIC
    外部中止或 PAuth x30 分歧。

对应提交：

```text
ca5e22d isa: close P6 GICv2m and system probe gaps
0ffd476 verify: canonicalize resume checkpoint paths
77fe9be verify: remove obsolete Linux debug logging
b51c4db qemu: mask PAuth enables for P6 difftest
2deed40 docs: record P6 MMIO and PAuth closure
```

## 3. 当前限制

- PAuth 不是已实现的架构扩展；当前仅为 P6 Linux 兼容 shim，参考 QEMU 的
  difftest 活跃路径显式关闭 PAuth enable 位；P7/P9 范围不得据此宣称完成。
- checkpoint sidecar 尚未保存完整 QEMU/DUT TLB 与 Cache 状态；新链应从已
  验证的绝对路径恢复，旧带 `manifest.json` 的链在 QEMU binary 重建后会因
  SHA256 约束拒绝，不能混用。
- Gate E 仍未完成：Timer IRQ/WFI、稳定 early boot 后用户空间、更长连续
  负载和正式 Linux 交互验收尚待继续。

## 4. 下一步命令

优先从 `tail-resume-ckpt10-20260825` 的最后 diff 恢复，使用新的绝对输出
目录，先跑 1～2M 条确认继续稳定；资源检查通过后再扩大窗口。QEMU fork
dirty 改动必须保留，任何 QEMU 变更都要同步更新 `qemu/patches/` 并做干净
基线重放。

