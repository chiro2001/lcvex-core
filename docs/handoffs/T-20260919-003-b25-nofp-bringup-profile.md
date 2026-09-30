# T-20260919-003：B25 no-FP 标量快速 bring-up profile 交接

```text
task=T-20260919-003 state=done partial=false
acceptance_status=scalar-profile-frozen-local-l0-l2-pass
base=b05521e6f0ee09a15898545bac429ee78e7014f7
profile=d00d566da86e034d6cf1651cdfb8ec50074ead13
profile_tree=d5baa6b05f5f8824236c816980ab6e6d48578594
branch=fpga/T-20260919-003-b25-nofp-bringup-profile
evidence=docs/tasks/evidence/T-20260919-003.json
```

## 结论

profile 相对 corrected full-FP integration baseline 的唯一非台账差异是：

```systemverilog
parameter logic A64_FP_SIMD = 1'b0;
```

参数已证明从 Catapult board top 传到 SoC/core 的真实 generate gate。no-FP core、SoC
和完整 board skeleton lint 均通过；elaboration 代理规模分别约 3.05/5.74/5.67 MB。
BRAM monitor 的 AArch64 反汇编不含 FP/NEON 指令，因此该配置不改变本轮
PC=0→polling JTAG-UART→DDR 诊断程序的执行需求。

带 `-GA64_FP_SIMD=0` 的完整 B25 SoC smoke 已在共享 `local` 锁内通过：CAL-OK、
CAL-WAIT、CAL-FAIL 三个场景全部到 READY，PING/PONG、字符回显及成功场景 DDR adapter
计数均满足。修复后的 vendor-faithful M20K timing test 同样通过。

## 边界

该 profile 移除了 FP/NEON 执行单元，软件不得执行这些指令；它没有补全并验证所有
FP/NEON→UDEF/trap 语义，也不替代最终 full-FP/P7 fresh signoff。它保持在独立 topic
SHA，未覆盖 full-FP 集成基线。

## 下一步

T-20260919-004 已在此精确 SHA 上提前完成 fresh synthesis（流水线允许 synthesis，
但此前门控 fitter）。本任务完成后可继续 fitter/STA；assembler 仍需同时等待
T-20260919-002 完整 Gate D。精确命令和日志 hash 见
[`T-20260919-003.json`](../tasks/evidence/T-20260919-003.json)。
