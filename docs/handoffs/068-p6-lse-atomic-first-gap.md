# LCVEX 交接文档 068：P6 深段首次 LSE 原子缺口

日期：2026-08-25（Asia/Shanghai）  
前置：`067-p6-before-wfi.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 新分歧

从 `tail-resume-ckpt17-20260825` 继续约 28M 时，首次遇到：

```text
0xffff8000801e7868: 0xb8f80001  ldaddal w24, w1, [x0]
```

QEMU 语义：原子读取内存旧值 `1` 写入 `W1`，并把
`0xffffffff + 1` 的结果 `0` 存回 `[x0]`；提交包含一个 32 位 Store。
DUT 当前将该 LSE 指令判为 UDEF，因而没有寄存器写回/内存副作用。

这不是差分基础设施问题，也不是 WFI；它是 ISA_SCOPE 中尚未实现的 LSE
原子族首次进入真实 Linux 路径。

## 2. 下一步实现边界

优先实现 `LDADD/LDADDA/LDADDL/LDADDAL` 的 W/X 形式：

- decode 识别 `a64.decode @atomic` 的 size、acquire/release、Rs/Rt/Rn；
- EX/MEM 采用单阻塞两阶段事务：读旧值 → 计算新值 → 写回，保证单核
  顺序模型下原子性；
- WB 返回旧值到 Rt，commit packet 上报一次内存写副作用；
- request/response、D-L1/I-L1/L2 和 MMU fault 均复用现有协议；
- 增加 baremetal/QEMU 定向测试，覆盖 W/X、0/最大值回绕和 acquire/release。

随后再按 Linux 实际轨迹补 `LDSET/LDCLR/LDEOR/LDUMAX/LDUMIN/SWP/CAS`，
不要把原子指令错误降级成普通 Load/Store 或跳过内存比较。

## 3. 当前验证与入口

- `make compile`、`make test`、`make checkpoint-sys-smoke`、M2-4b base/cache
  最近均已通过；`hard_p6_isa` 101 条、`hard_gic` 52 条通过；
- 最新可恢复链：`tail-resume-ckpt17-20260825`，最后 diff local `999999`；
- 约 26M 前的系统探测、YIELD、SCTLR/SMCR/RAS/TPIDR2 均已关闭；
- WFE/WFI/Timer IRQ 仍未进入正式验收，LSE 原子实现优先级更高，因为它已
  在当前 Linux 负载中实际阻塞继续执行。

