# LCVEX 交接文档 065：EXTR 64 位方向修复与约 20M 深段

日期：2026-08-25（Asia/Shanghai）  
前置：`064-p6-deep-tail-final.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 新分歧与根因

从 `tail-resume-ckpt10-20260825` 续跑约 20M 时，指令
`0x93cf80e7 = EXTR X7, X7, X15, #32` 首次分歧：

```text
QEMU: x7 = 0x00000001ee0504a0
DUT : x7 = 0xaac20d6400000000
```

RTL 原公式把 `{Xn,Xm}` 的高低方向反置为
`(Xn >> lsb) | (Xm << (64-lsb))`。AArch64 EXTR 是拼接后右移，正确公式为
`(Xn << (64-lsb)) | (Xm >> lsb)`；`lsb=0` 的结果是 `Xm`。W 形式同样
在 32 位拼接域内计算并零扩展。

## 2. 修复与验证

- `rtl/lcvex_alu.sv` 修正 32/64 位 EXTR 方向和 `lsb=0` 语义；
- `hard_p6_isa` 增加非对称 64 位 `#32` 定向用例，提交数由 100 增至 101；
- `make compile` 通过；
- 从 `tail-resume-ckpt10` 恢复的 100000 条通过；
- `make m2-4b` base/cache 全绿，`hard_p6_isa` 101 条、`hard_gic` 52 条均与
  QEMU 一致；
- 修复后的 Linux checkpoint 续跑再通过 1000000 条，生成
  `tail-resume-ckpt12-20260825`，累计约 20M 指令。

修复提交：`5974cdc isa: fix EXTR concatenation direction`。

## 3. 当前入口和限制

下一步从 `tail-resume-ckpt12-20260825` 的 `diff-999999` 恢复，使用新绝对
目录继续 1～2M 长段。当前仍未进入正式 Gate E 验收：Timer IRQ/WFI、稳定
early boot 后用户空间和更长连续负载待继续。

保留约束：PAuth 仅为 P6 difftest shim，不代表 P7/P9 完成；checkpoint sidecar
尚未保存完整 QEMU/DUT TLB/Cache 状态；QEMU fork dirty 修改必须由
`qemu/patches/` 重放并保持固定 11.1.0 基线。

