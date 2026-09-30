# T-20260905-012：FP response 与 data-MMU hold 定向回归交接

```text
task=T-20260905-012 state=review base=80b7664 head=d6e6d032f6d6ab62c0b0db5a6e2801f907a4a4ee branch=fix/T-20260905-012-dynamic-pc-token-sva worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-012
```

## 结论

在 6ef67db 的 `fp_rsp_accept_blocked` 修复上补充了真实 MMU 页表 walk 的
定向回归。测试通过完整 P5a 镜像装载 L0/L1/L2/L3 页表，恢复
`TTBR0_EL1=0x44010000`、`TCR_EL1=0x100010`、`MAIR_EL1=0xff`、
`SCTLR_EL1=0xc50839` 和已知 V0/V1，然后执行：

```text
MOVZ X0,#0x4000,LSL#16
MOVZ X4,#1
MUL  X5,X4,X4
FADD S2,S0,S1
LDR  X3,[X0]
B    .
```

旧 MUL 让 FP 与 LDR 同时进入流水线；LDR 的 VA `0x40000000` 经现有四级
P5a 页表翻译到 PA `0x44080000`。在 data translation 期间，FP response
payload 和 ID/EX token 连续保持，`fp_rsp_ready`/`fp_consume` 均为 0；翻译
结束后 response 只消费一次并正常进入提交路径。

专用测试的旧 FP 指令采用 scalar FADD，是为了在当前 1-cycle SRAM 配置下
让 response 与 data walk 形成可重复的并发窗口；它验证的是 core 共享
`fp_exec` response handshake，不宣称额外的 NEON-specific latency 语义。
既有 P7-3 NEON 测试仍在同一入口完整执行。

## 验证结果

定向回归实际观测：`blocked_cycles=5`、`data_issues=1`、`consume=1`、
`exmem_captures=1`、FP commit=1、LDR commit=1。完整 P7-3 Cocotb 入口为
`5/5 PASS`（含新增用例）；独立 P7-3 NEON raw SV 为 PASS。

精确命令、source SHA、资源限制和运行时间见
[`docs/tasks/evidence/T-20260905-012.json`](../tasks/evidence/T-20260905-012.json)。

## 修改文件

- `sim/cocotb/test_p7_3_neon_fp.py`：完整 P5a image loader、MMU/FP restore、
  response payload/token hold、ready/consume 唯一性、EX/MEM/提交结果断言。
- `docs/handoffs/T-20260905-012-dynamic-pc-token-sva.md`
- `docs/tasks/evidence/T-20260905-012.json`

RTL 实现沿用已提交的 `6ef67db`，本 handoff 未修改 FP datapath、MMU 控制、
QEMU、QSF/SDC 或板级流程。

## 边界与下一步

- owner 侧静态检查、P7-3 Cocotb 5/5 和 NEON SV raw 已通过；`merge_sha` 仍待
  集成者在 T-009 candidate 上补写并复跑。
- T-009 全量 L0-L2、完整 Gate D、Quartus、assembler/SOF、JTAG 和上板测试
  不属于本次回归，未运行。
- 不关闭任何断言、不修改参考结果；无 false-path 或 QEMU 变更。
