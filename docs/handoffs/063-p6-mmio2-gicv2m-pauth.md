# LCVEX 交接文档 063：P6 GIC MMIO2、GICv2m 与 PAuth 兼容

日期：2026-08-25（Asia/Shanghai）  
前置：`062-p6-msr-daif-false-loss-fixed.md`  
分支：`feature/p6-system-reg-shim`

## 1. 本轮结果

Linux 深段续跑在约 15.59M 首次暴露了真实 MMU 平台缺口，随后又暴露
GICv2m 和 PAuth 探测缺口。均已加入 RTL/测试/参考模型兼容路径：

- MMU 的合法 PA 窗口加入 GIC MMIO2 `0x08000000..0x08021000`；此前只允许
  SRAM 和 PL011 `0x09000000`，导致 GICD/GICC 访问被误报外部中止。
- `lcvex_gic` 增加 GICv2m frame `0x08020000..0x08021000` 的
  `MSI_TYPER=0x00500040`、`MSI_IIDR=0x05100000` 和 RAZ identification
  读；`SETSPI_NS` 对当前 SPI 子集提供最小 pending 语义。
- 增加 `SCTLR2_EL1` RAZ/WI 和 APIA/APIB/APDA/APDB/APGA key low/high 的
  P6 RAZ/WI shim，覆盖 Linux PAuth 探测写入。
- P6 DUT 使用 64 项全相联 TLB；恢复路径仍不宣称保存全部 QEMU TLB，
  checkpoint 继续限制在已验证链和 sidecar 语义内。
- `run_lockstep_resume.sh` 将相对 `CKPT_DIR` 规范化为绝对路径，避免
  manifest 恢复时重复拼接路径；新发布链必须使用绝对 artifact 路径。
- QEMU fork 在 `LCVEX_DIFFTEST_STEP=1` 时屏蔽 SCTLR 的 EnIA/EnIB/EnDA/EnDB，
  让 PAuth HINT 与 DUT NOP shim 对齐；普通 QEMU 运行不受影响。对应改动
  已写入 `qemu/patches/0002-lcvex-checkpoint-hook.patch`。

## 2. 失败与修复证据

### GIC MMIO2

失败指令：`LDR W1,[X1]`，VA `0xffff800080010004`，QEMU 返回 `8`，DUT
报 DABT/FSC `0x10`。DUT TLB 已命中 PA `0x08000004`，这是 GICD `+4`；
MMU `pa_in_window()` 漏掉 MMIO2 是直接原因。

修复后从 global 约 15.5M checkpoint 续跑 100000 条通过，并继续 500000
条通过，`hard_gic` 增至 52 条（新增 GICv2m MSI_TYPER 读取）且 base/cache
均与 QEMU 一致。

### GICv2m

失败指令：`LDR W2,[X2]`，VA `0xffff800080005008`，QEMU 返回
`0x00500040`。这是 GICv2m `MSI_TYPER`（base SPI=48、num SPI=64），
原 router top=0x08020000 将其排除。扩展窗口和寄存器模型后，M2-4b
全套 base/cache 通过。

### PAuth/SCTLR2

Linux 先写 `APIAKEYLO/HI_EL1`，随后执行 `PACIASP`。DUT 原本把 key 写
误判 UDEF；加入 RAZ/WI 后，QEMU 的 PAuth 默认又修改了 `x30`，而 P6 DUT
按既定范围把 PAC HINT 当 NOP。QEMU difftest 活跃时清除 SCTLR PAuth enable
位后，`PACIASP` 与 DUT 对齐。

## 3. 深段验证

- 从 `tail-resume-ckpt6-20260825` local `1499999` 恢复，MMIO2 修复后
  500000 条全绿；生成 `tail-resume-ckpt7-20260825`。
- 从 `tail-resume-ckpt7-20260825` local `499999` 恢复 1000000 条全绿；
  生成 `tail-resume-ckpt8-20260825`。
- 使用 QEMU PAuth 屏蔽后，从 `tail-resume-ckpt9-20260825` local `499999`
  恢复 1000000 条全绿；生成 `tail-resume-ckpt10-20260825`。
- `make compile`、`make sim-sv-mmu`、`make m2-4b`（base/cache）通过；
  `hard_gic` 52 条全部逐指令差分通过。

这些结果仍是 P6 内核长段证据，不等同 Gate E 完成；Timer IRQ/WFI、稳定
early boot 后用户空间和更长连续负载仍待验收。

## 4. 继续工作入口

优先从 `tail-resume-ckpt10-20260825` 的最后 diff 恢复，继续向 20M 推进；
每次新链使用新的绝对目录名，检查 `/tmp` 与磁盘后再启用 `CKPT_EVERY`。
QEMU binary 已因 PAuth shim 重建，旧带 `manifest.json` 的链会按 SHA256
约束拒绝，不能混用旧 QEMU 产物。

