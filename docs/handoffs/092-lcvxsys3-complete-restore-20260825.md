# LCVEX 交接文档 092：LCVXSYS3 完整系统状态恢复

日期：2026-08-25（Asia/Shanghai）
前置：handoff 090（恢复端口）、handoff 091（CRC32/CRC32C）
分支：`feature/p6-system-reg-shim`

## 动机

handoff 090 的恢复端口已将 `LCVXSYS2` 系统状态在时钟边界送入 Verilator，
但 QEMU sidecar 当时遗漏了三个已实现的可变状态：`PMUSERENR_EL0`、
`TCR2_EL1` 和 exclusive monitor。进一步核对 QEMU 11.1 的
`CPUARMState.cp15` 后发现 `PIRE0_EL1` 对应 `pir_el[0]`，旧保存代码错误地
固定写 0。这些都不能靠 reset 默认值替代。

## LCVXSYS3

QEMU fork patch `qemu/patches/0009-lcvex-sys-sidecar-v3.patch` 将 sys
sidecar 扩为 540 bytes、magic `LCVXSYS3`、version 3：

- `PMUSERENR_EL0 = cp15.c9_pmuserenr`；
- `TCR2_EL1 = cp15.tcr2_el[1]`；
- `PIRE0_EL1 = cp15.pir_el[0]`（修复旧常量 0）；
- exclusive monitor 的 `exclusive_addr/exclusive_val/exclusive_high`。

协调器、`checkpoint.py` 与 `difftest_restore_*` 端口同步扩展；core 在恢复
strobe 接收这些值。`exclusive_addr == ~0` 是无有效 monitor 的唯一编码。

旧 `LCVXSYS1/2` 仍可读取：新增 sysreg 为 reset 值，且协调器显式把
monitor 标为无效，绝不会将零填充误判为地址 0 的有效 exclusive。

## 定向联合恢复

新增 `hard_checkpoint_sys_v3` 与 `make checkpoint-sys-v3-smoke`：

1. 写 `PMUSERENR_EL0=0xf`、`TCR2_EL1=0x70012`、`PIRE0_EL1=0x5aa`；
2. 写 RAM `0x44001000=0x55` 后执行 `LDXR`，在该有效 monitor 的提交点保存；
3. 用 QEMU `-incoming` 和 Verilator 从同一 checkpoint 恢复；
4. 读取三项系统寄存器，执行 `STXR`（必须返回 0），再读取 RAM（必须为
   `0x66`）。

实际结果：sidecar 读回 `15 / 458770 / 1450 / 0x44001000 / 0x55 / 0`，
随后 5 条 QEMU/DUT 锁步全绿。

## 验证与状态

```sh
make compile
make checkpoint-sys-v3-smoke
make checkpoint-sys-smoke checkpoint-timer-smoke
```

QEMU 11.1.0 已以物理核 0–5、最多 6 并行 job 本地重建；顺序应用
`0001..0009` 到干净 v11.1.0 worktree 的 `git apply --check` 通过。

同时，CRC 提交后的 lite 长窗从 seq 4,999,999 连续通过 1,500,000 条，
在相对 seq 1,399,999 保存新 checkpoint，已越过原 `crc32x` UDEF。

## 后续

1. 本轮应只提交 sys-sidecar v3、端口、QEMU patch、定向 smoke 与文档；
2. 新产生的 v3 链可用于带 exclusive 的快速恢复；旧 v2 Linux 链仍可作为
   无 monitor 的恢复输入；
3. 继续从新的 lite checkpoint 定位下一条真实 ISA/MMIO 缺口；IRQ COMMIT
   fallback 保持独立验证与提交。
