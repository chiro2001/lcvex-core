# T-20260920-030：B25 logic-imm repair volatile SOF 交接

```text
task=T-20260920-030 state=review partial=false
base=2e7d237bb9d442ed3d174eb606140786e8428717
candidate=2a1cd5c59fc27f0a6d947c58f5b24b194d4dd13b
candidate_tree=e5e94ab175f6847d727901576a8f12958efc1100
remote_source=D:/Projects/fpga-altra/lcvex/build/T-20260920-027-b25-logic-imm-repair-fresh-physical
remote_target=D:/Projects/fpga-altra/lcvex/build/T-20260920-030-b25-logic-imm-repair-volatile-sof
received_at=2026-09-20T17:20:02+08:00
reported_at=2026-09-20T17:32:59+08:00
artifact_sealed_at=2026-09-20T17:27:00+08:00
```

## 结果

在 `gamepc` 独占锁内从已验收的 T-027 post-STA fitted root 建立全新、task-owned
byte-identical clone。源清单为 539 行，pre/post 和 clone baseline 均为：

```text
4bfb8f25201c467f01ac3a5b3725cc847908b869f78d1dbaea19e0e8f6fc1f06
```

验证了 QPF/QSF/normalized-QSF/SDC、`boot/build/boot.mif`、fit.rpt 和 sta.rpt 的
冻结身份。冻结的 T-027 `boot.bin` 输入也复核为 2011 bytes、
`96f1b8484b30c33adac0a1562b897647a1f937cd4ac64539bad687538d19ad79`；它不属于远端
fitted source 清单。

只执行了一次精确 assembler：

```text
quartus_asm --read_settings_files=on --write_settings_files=off catapult_a10 -c catapult_a10
```

stdout 和 `catapult_a10.asm.rpt` 均为 Successful、0 errors、0 warnings，且命令行
完全一致。`catapult_a10.sof` 唯一且内容身份为：

```text
bytes       = 36842105
sha256      = bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264
checksum    = 0x315AC2B3
design_hash = 0CC907F3DD48A9C78864E3C5BD66B9AF
usercode    = 0xFFFFFFFF
```

配置产物计数为 `SOF=1`，`POF/JIC/RBF/JBC/SVF/JAM=0`。QDB 从 225 到 228，仅发生
T-020 模板确认且本轮实际匹配的 assembler metadata 变化：added 3、changed 3、
removed 0；`final/partitioned/synthesized` payload 变化为 0。

## 安全边界与证据

preflight 确认目标根不存在、源存在、冲突 EDA/programmer/terminal 进程为 0；标准
`jtagserver.exe` 仅观察未停止。assembler 后 EDA=0，独立最终只读扫描通过，锁释放后
`gamepc FREE`。未执行 synthesis/fitter/STA、`quartus_pgm`、`jtagconfig`、
`nios2-terminal`、FPGA 配置、Flash/JIC/EPCQ、reset/power 或未知进程停止。

第一次远端 root-create 命令因远端 shell 的 pipe 解析失败，在创建 root 前退出；随后在
锁内只读确认 root 仍不存在、且没有运行 assembler，再使用 encoded prepare runner 建立
新 root。该设置修复没有产生 EDA 运行，也不影响 assembler invocation count=1。

PowerShell 的 `Start-Process` `ExitCode` 观察值为 blank/-1；这是 wrapper 采样限制，
不是 assembler report 失败。由于 report/stdout 成功标记完整，未重跑 assembler。

完整机器证据见 [`T-20260920-030.json`](../tasks/evidence/T-20260920-030.json)，本地
抓取产物位于 `build/agents/T-20260920-030/remote-evidence/`（ignored）。SOF 只能由
后续明确授权的 volatile board 任务消费；本任务不代表已配置 FPGA，也不授权 Flash 或
reset/power。
