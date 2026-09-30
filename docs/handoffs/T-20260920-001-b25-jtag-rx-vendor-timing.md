# T-20260920-001：B25 JTAG-UART RX 厂商时序复现交接

## 结论

当前 production RTL 没有在厂商时序等价测试中复现板上 RX 故障，因此本任务没有、也
不允许猜测性修改 `lcvex_catapult_soc_jtag_uart`。

新增模型覆盖 Quartus 21.4 注册式 waitrequest、DATA/CONTROL selector、RVALID、
showahead-OFF RX FIFO q，以及厂商 TX 满时“接受并置 overflow”的行为。最终提交
`07e8148b` 上：

- focused Icarus/Verilator 均通过，Avalon reads/writes `8/8`、RX pops `3`、TX pushes `6`；
- full-SoC 的 CAL-OK/CAL-WAIT/CAL-FAIL 三种场景全部通过；
- CAL-WAIT 在注入前完成精确 `65,536` 次空 DATA 读取，期间 CPU 提交 `458,755` 次；
- 随后 `p/PONG`、`Z` 回显和 `?/CLOCK25 CAL-WAIT DDR-FAIL` 全部 exactly-once；
- 原行为模型 full-SoC 也保持全绿，test registry 86 项一致性检查通过。

第一次 full-SoC 只触发了一个 testbench 假失败：行为模型把 FIFO event 与 bridge TX
pulse 放在同一拍，厂商协议则先在 waitrequest 高相位执行 FIFO side effect，bridge 在
下一低相位报告接受。观测器现只对厂商 event 延迟一拍再逐字节比较，并保留最终计数
相等检查；这不是 production 修复。

## 故障范围

已通过的范围是 host 字节进入模型 RX FIFO 后的厂商 DATA 时序、Avalon side effect、
bridge capture、M1-B 响应、resident monitor 轮询和命令响应。仍未由仿真覆盖的是实际
JTAG Atlantic host→target 传输、长命标准 server 状态，以及综合后的 vendor CDC/FIFO
在 Avalon DATA 之前的物理行为。

T-20260920-003 新发现：terminal 退出后，标准 server 可能暂时不枚举 UART；保留 PID
5640 并做有间隔的只读 `jtagconfig -n` 重扫可以恢复 `JTAG UART #0`。所以下一步应先
用既有 corrected SOF 做一次“明确重扫后首 terminal”的非破坏性控制，而不是立刻改
RTL。若仍失败，再增加物理 DATA-read/RVALID/last-byte 可观测性，并重新走 Gate D、
fresh physical、assembler 和易失板测。

全部命令、source SHA 与日志 hash 见
[`T-20260920-001.json`](../tasks/evidence/T-20260920-001.json)。
