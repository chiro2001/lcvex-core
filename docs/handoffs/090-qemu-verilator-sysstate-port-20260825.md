# LCVEX 交接文档 090：QEMU→Verilator checkpoint 系统状态端口

日期：2026-08-25（Asia/Shanghai）
前置：handoff 089（WFxT 等待恢复时间同步）
分支：`feature/p6-system-reg-shim`

## 背景与结论

用户指出，QEMU checkpoint 中的系统状态不应由锁步协调器直接写入 Verilator
内部层级。这个判断正确：恢复必须经一个明确、时钟同步、可由 RTL 自身验证的
输入边界。

本轮新增 `lcvex_soc_tb` 与 `lcvex_core` 的验证专用恢复端口：

```text
difftest_restore_sys_valid
difftest_restore_pc / difftest_restore_*
```

协调器在 reset 保持期间装载 GPR/RAM；reset 释放后将 QEMU sidecar 的 PC、
PSTATE、EL1 系统寄存器和 Generic Timer 值置于端口上，并仅打一拍
`difftest_restore_sys_valid`。core 在该时钟沿接收值、冲掉同拍可能生成的取指
状态和提交包，下一拍从 sidecar `next_pc` 取指。

这和 WFx 的 `difftest_wait_*` 端口遵循同一原则：协调器不直接改写 core 的
PSTATE、MMU、Timer 或系统寄存器层级变量。

## 边界

这不是每条指令后的 QEMU 状态同步。普通锁步始终由 RTL 自己执行、生成
commit packet，并与 QEMU COMMIT 严格比较；若把状态逐条回灌，会掩盖真正的
RTL bug。端口只能用于以下两类确定性外部输入：

1. checkpoint 恢复的初始架构状态；
2. 已经定义的非架构等待恢复输入（`WAIT_RESUME` 的 CNTVCT）。

独立 SV/Cocotb、microbench 及未来 FPGA 顶层均把恢复端口固定为 0。

## 本轮覆盖与遗留

当前 `LCVXSYS2` 通过端口恢复：PC、SP bank、EL/SP/NZCV/DAIF/PAN/DIT、
ELR/SPSR/VBAR/SCTLR/TCR/TTBR/MAIR/ESR/FAR/PAR、CPACR/MDSCR/CNTKCTL、
TPIDR、PIR/PIRE0、ZCR/SMCR/CSSELR 和 Generic Timer CVAL/CTL/计数。

`PMUSERENR_EL0`、`TCR2_EL1` 和 exclusive monitor 仍不在 `LCVXSYS2`
sidecar 中；因而它们不是本次“完全 checkpoint 恢复”的已验收状态。下一版
`LCVXSYS3` 需并行修改 QEMU fork 的导出结构、`checkpoint.py`、协调器、RTL
端口和 checkpoint 联合 smoke，并保持 v1/v2 链只读兼容。

## 已验证

```sh
make compile
make checkpoint-sys-smoke
make checkpoint-timer-smoke checkpoint-dut-smoke
make sim-sv sim-sv-backpressure
make sim-cocotb-backpressure
```

结果均通过。其中 `checkpoint-sys-smoke` 是 QEMU `-incoming` 与 DUT 从同一
sidecar 恢复后继续 4 条严格锁步，覆盖 ZCR/SMCR/CSSELR；
`checkpoint-timer-smoke` 覆盖 QEMU 虚拟计数到 RTL 内部计数的 `-1` 转换。

## 当前工作区注意事项

- 该功能尚未单独提交；应仅 stage 本文档、`docs/DIFFTEST.md`、恢复端口、
  coordinator 与普通测试初始化文件，提交建议：
  `difftest: add checkpoint system-state restore port`。
- 同一工作区已有未提交 CRC32/CRC32C 指令组和 IRQ exception fallback，
  不得混入上述提交。
- `../qemu` 是预期 dirty 的 patch fork；本轮没有修改 QEMU 代码或 patch。

## 下一步

1. 将本轮端口改动按单一逻辑提交；
2. 为 `PMUSERENR_EL0`、`TCR2_EL1`、exclusive monitor 设计并实现
   `LCVXSYS3`，先完成小程序联合 checkpoint smoke；
3. 再从 lite/main Linux checkpoint 恢复推进，遇到新 ISA/MMIO 缺口时保持
   主线与 lite 线异步。
