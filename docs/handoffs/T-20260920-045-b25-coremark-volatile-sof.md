# T-20260920-045：B25 microbench/CoreMark volatile SOF 交接

```text
task=T-20260920-045 state=done
base=880517209700c76ca0d602ae8dbfd16dd930b373
candidate=f6633e70dd4d6b2f9a6aa932daee7c7e8252ac8d
candidate_tree=49fab30e4d8d49a5af24a81a49d8cf95f2cded8c
source_remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-044-b25-coremark-fresh-physical
target_remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-045-b25-coremark-volatile-sof
started_at=2026-09-21T00:51:44+08:00
finished_at=2026-09-21T00:52:34+08:00
```

## 结果

在一个 `gamepc` resource-lock 窗口内，从已验收的 T-044 post-STA root 建立全新
task-owned byte-identical clone，并且只执行一次：

```text
quartus_asm --read_settings_files=on --write_settings_files=off catapult_a10 -c catapult_a10
```

不可覆盖的 `assembler.once` marker、runner result 与本地调用路径都记录 invocation
count=1。stdout 和 `catapult_a10.asm.rpt` 均为 Successful、0 errors、0 warnings；唯一
volatile SOF 为：

```text
bytes       = 36842099
sha256      = c648f9fe1744d66f5e60f97a2aa706a36d295d1029e887d4f3155d292127df4f
checksum    = 0x31585D80
design_hash = BE249DE82456FE40F022D019CD23D8C9
usercode    = 0xFFFFFFFF
```

源与 clone baseline manifest 均为
`533cb35732b27220a06e47f4fc5383f402cbbb4d9526f9cb2490110e15ea1f40`；assembler 后源
manifest 保持相同。clone QDB 从 225 到 228，只出现与历史成功流程相同的 assembler
metadata added 3 / changed 3 / removed 0，`final/partitioned/synthesized` 数据库变化为 0。
MIF 仍为
`d56386b0714c65bab955cb91112d510b31f4290f80281f86c7feabdd6988d7d0`，对应完整 64 KiB
image SHA-256
`1e691cc06094746464633929b2dea25be43c96305873bedfca82d3978c87ddb9`。

## 安全边界

配置产物计数为 `SOF=1`，`POF/JIC/RBF/JBC/SVF/JAM=0`；pre/post EDA process=0，保留
标准 `jtagserver.exe` PID 5640，未停止任何标准或未知进程。本任务没有调用
`quartus_pgm`、`jtagconfig`、`nios2-terminal`，没有配置 FPGA，没有 Flash/EPCQ、
reset 或 power 操作；live FPGA 仍为此前证明的 exact golden。

PowerShell `Start-Process.ExitCode` 再次观察为 `-1`，没有因此重跑。权威成功依据是原始
stdout/report 的精确命令和 Successful/0/0 标记、唯一 invocation marker、零残留 EDA、
QDB allowlist 和最终只读扫描。

完整证据见
[`docs/tasks/evidence/T-20260920-045.json`](../tasks/evidence/T-20260920-045.json)，SOF 与
raw reports 保存在 ignored 的 `build/agents/T-20260920-045/remote-evidence/`。该 SOF
只能由 T-046 的一次 sealed volatile board transaction 消费。
