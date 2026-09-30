# T-20260920-047：T-041 后 exact golden-only recovery

```text
task=T-20260920-047
state=review
base=0cdfb2734eddc5e81715b665db06b3e375fe570b
head=<evidence commit reported after commit>
branch=verify/T-20260920-047-b25-ddr-golden-recovery
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-047
sent_at=2026-09-20T22:19:25+08:00
received_at=2026-09-20T22:19:25+08:00
reported_at=2026-09-20T22:22:32+08:00
```

T-047 使用 T-036 原封不动的 9 文件 sealed bundle；source manifest SHA-256 为
`2972d24292de061ed06e98aa68ce3f4443ca041caa3cba1bca632e223542dfcc`。
fresh root/bootstrap、PowerShell AST 6/6 和 seal 9/9 均通过。

唯一 golden programmer transaction 成功：PID 8044、exit 0，Quartus tool、
configuration、operation、checksum `0x31510BB6` 和 JTAG ID `0x02E060DD` 全部
PASS。SOF 为 36,844,906 bytes、SHA-256
`290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`。

成功后只执行一次标准 `jtagconfig -n`；exit 0，输出包含指定 cable、裸文本
`02E060DD`、golden design hash `193DE4BC8A30F3ED5F1F`、`JTAG UART #0` 和
`JTAG PHY #0`。因此 live exact golden 已由成功 transaction 与最终 chain 联合证明。

wrapper exit 1 是枚举 parser 期待 `0x02E060DD`、而工具打印 `02E060DD` 的本地格式
错误；不影响上述原始字段。没有因此重跑或再次访问 GamePC。candidate、terminal、
`m`、Flash/JIC/EPCQ、reset/power、标准/未知进程停止均为 0，仅停止 task-owned
server 一次。

完整结构化证据见
[`T-20260920-047.json`](../tasks/evidence/T-20260920-047.json)。后续无需硬件动作；
集成后继续 T-042 BRAM microbench/CoreMark 本地实现。
