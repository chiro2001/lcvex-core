# T-20260920-052：corrected UART payload volatile SOF

```text
task=T-20260920-052 state=done
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
source_remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-051-b25-coremark-uart-fresh-physical
target_remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-052-b25-coremark-uart-volatile-sof
started_at=2026-09-27T18:12:11+08:00
finished_at=2026-09-27T18:42:40+08:00
```

## 结果

从已验收的 T-051 fitted database 创建独立副本，精确绑定 source stage manifest
`432efd72...3722fc6`、corrected `boot.mif` SHA-256
`0743295f...bd610a2f`、完整 64 KiB image SHA-256
`aa43d0b7...92f944`、Gate-D 候选 SHA `5b33c451` 和 tree
`e026b2ce...fa557d5e`。QPF/QSF-normalized/SDC、MIF、fitter report 与 STA report 均在
assembler 前逐项核验。

唯一 Quartus 命令执行一次，耗时约 45.25 秒。Assembler stdout 与
`catapult_a10.asm.rpt` 均记录 exact command 及 `Successful. 0 errors, 0 warnings`。
`Start-Process.ExitCode` 观测为 `-1`，未据此重跑。唯一 volatile SOF：

```text
bytes       = 36,842,099
sha256      = 39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def
checksum    = 0x31585D80
design_hash = 48917DD6FD70C4420BD5765A206DACBB
usercode    = 0xFFFFFFFF
```

Source pre/post manifest 都是 `86ac31c6...608d865`，clone 与 source 差异为 0。
数据库从 225 项到 228 项，只新增/更新了历史 assembler metadata 白名单中的各 3 项；
`final/partitioned/synthesized` 物理 fitted payload 变化为 0。配置产物总计仅 SOF=1，
POF/JIC/RBF/JBC/SVF/JAM 均为 0。Postflight EDA=0，`gamepc` 锁已释放。

## 调度异常与安全边界

第一次 verifier 参数 transport 在 assembler 前失败；随后 v1 runner 因把 T-051 的输入
QSF manifest hash 当成 Quartus 生成工程的 raw QSF hash 而停在身份校验处，也没有创建
clone/runtime 或 assembler marker。输入 stage manifest 和 QSF normalized hash 正确；实际
T-051 工程 raw QSF SHA 是 `1deb0042...5bfa46`，normalized SHA 是 `3e0ef899...71c5fe`。
保留旧脚本和失败现场，新增独立 v2 脚本名并再次验证全部前置身份后，才运行唯一一次
assembler。远端最终扫描确认 invocation marker=1。

本任务没有执行 `quartus_pgm`、`jtagconfig`、`nios2-terminal`，没有访问 JTAG、配置板卡、
烧写 Flash、reset 或 power 操作。T-048 之后 live FPGA exact golden identity 仍未证明；
这项 SOF 生成不构成任何真板 CoreMark 结果。

精确命令、hash、资源锁与 artifact 记录见
[`docs/tasks/evidence/T-20260920-052.json`](../tasks/evidence/T-20260920-052.json)。忽略的大型
SOF、Quartus report 和 clone 清单保存在 `build/agents/T-20260920-052/remote-evidence/`。
