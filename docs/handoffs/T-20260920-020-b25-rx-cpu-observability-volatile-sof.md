# T-20260920-020：B25 RX CPU observability volatile SOF 交接

```text
task=T-20260920-020 state=done partial=false
base=b56e1bd50091a5aba360d90bfe703913acf2bbae
candidate=e91d20f15244e425fefaadeca8654fdfa1ebebc6
candidate_tree=0f4110efbb8fbbc4ea51c147f6ff89e6cb27e2c7
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-020-b25-rx-cpu-observability-volatile-sof
received_at=2026-09-20T12:55:24+08:00
reported_at=2026-09-20T13:10:00+08:00
```

## 结果

从 T-017 accepted post-STA root 建立全新的 T-020 task-owned clone，source 与 clone
baseline byte-identical；只执行一次精确 assembler：

```text
quartus_asm --read_settings_files=on --write_settings_files=off catapult_a10 -c catapult_a10
```

Assembler report/stdout 均为 Successful、0 errors、0 warnings。唯一 SOF：

```text
bytes       = 36842101
sha256      = d9bc9a964be9b0c0e98b16643a5d9ca44a4bce00b3694915c84714552a0ed2fd
checksum    = 0x3159F8A0
design_hash = 4DAED3C37174544441E6912B371092CA
usercode    = 0xFFFFFFFF
```

输出格式计数：

```text
SOF=1
POF=0 JIC=0 RBF=0 JBC=0 SVF=0 JAM=0
```

Source pre/post manifest 均为：

```text
1ce45a9e54266dfb09993b97a3e4132f15b05a4670f691e7a671eadb7dc45e19
```

Assembler 仅造成严格 allowlist 内的 3 个 added 和 3 个 changed QDB report/runlog
metadata；0 removed，physical `final/partitioned/synthesized` payload 变化为 0。

## 边界与异常处理

所有 GamePC 操作均持 `gamepc` 锁；preflight EDA=0、最终 EDA=0、GamePC FREE。没有
synthesis/fitter/STA、programmer/JTAG/terminal、Flash/JIC/EPCQ、reset/power 或未知
进程停止。

Assembler 结束后的第一版结果序列化脚本因 PowerShell `[Text.UTF8Encoding]` 类型限定符
遗漏而失败；此时 assembler 已成功且只执行过一次。随后只运行 task-owned finalize audit，
重新核对 source/clone/DB/SOF/report 并抓取 evidence，没有重新调用 assembler。

完整证据见 [`T-20260920-020.json`](../tasks/evidence/T-20260920-020.json)。SOF 只能被
后续明确授权的 volatile board/JTAG 任务消费；本任务不代表已配置 FPGA，也不授权 Flash
或 reset/power。
