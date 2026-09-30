# T-20260920-004：B25 标准 server 延迟重枚举正控交接

## 结论

标准 server 的 JTAG-UART 节点 stale 已被排除，但 corrected candidate 的 RX 仍失败。

精确 T-006 SOF（`04218557...0abb7`，checksum `0x31426358`）易失配置成功后，只停止
任务自建的 programming server，保留标准 `jtagserver.exe` PID 5640。随后执行两次
相隔 2 秒的只读 `jtagconfig -n`，两次都明确看到 FPGA `02E060DD`、design hash
`193DE4BC8A30F3ED5F1F` 和 `JTAG UART #0`。

没有 console 预探测。紧接着第一个且唯一的 terminal 用历史普通文件 stdin 输入
`? / p / Z`，连接成功并收到：

```text
LCVEX25 BOOT
CAL-WAIT
DDR-FAIL
READY
```

但仍无 status、`PONG` 或 `Z` 回显。stdout hash 与 T-002 完全相同
`6b3116e8...9e23`，说明显式重枚举没有改变失败边界。

失败后 golden 易失回滚通过，checksum `0x31510BB6`；最终只读枚举看到 golden 的完整
Virtual JTAG、SignalTap、JTAG-UART 和 JTAG PHY 节点。PID 5640 保留，无残留 terminal/
programmer，端口 1310 已释放，板上最终运行 golden。

## 证据封装说明

脚本在所有板级动作、golden 回滚与清理完成后写 `result.json` 时发生 StrictMode 对象
错误：函数内的 `Write-Output` 日志混入了返回对象，导致 `stdout_path` 属性查询失败。
这只影响自动 JSON 封装；programmer、两份 rescan、terminal、rollback 和最终 postflight
均有独立文件/hash。已从只读拉取的 runtime 生成恢复结果，未重跑板测。

下一步不得再重复 pipe、普通文件、首会话或重枚举控制。需要加入物理 DATA-read、
RVALID 与 last-byte 可观测性，随后重新走相应 L0–L2、Gate D、fresh physical、assembler
和一次易失板测。精确证据见
[`T-20260920-004.json`](../tasks/evidence/T-20260920-004.json)。
