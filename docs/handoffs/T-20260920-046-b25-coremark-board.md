# T-20260920-046：B25 microbench/CoreMark 真板验收

```text
task=T-20260920-046 state=blocked
candidate=f6633e70dd4d6b2f9a6aa932daee7c7e8252ac8d
candidate_tree=49fab30e4d8d49a5af24a81a49d8cf95f2cded8c
SOF=36842099 bytes / c648f9fe1744d66f5e60f97a2aa706a36d295d1029e887d4f3155d292127df4f
contract_sha256=f0cb20c5668c5b26e27d34e3ac8638f6f0609d71387bb79907bf8290758ce96c
```

## 本轮结果

tracked runner contract、PowerShell AST/seal、preflight 与 candidate volatile
programming 均通过；candidate programmer invocation=1，SOF checksum `0x31585D80`，
JTAG ID `0x02E060DD`。

唯一 terminal session 启动到 `LCVEX25 BOOT / CAL-WAIT / DDR-FAIL / READY`。命令 `t`
返回准确的 `MBPASS 24 8679CF21`。随后 `v` 的固件输出以 `CMSELF PASS` 开始，但字节流
中 summary 在 `state=000` 处停止并被 RXCPU/RXPATH 周期诊断页插入；完整的 final CRC、
cycle count 与 `score=INVALID` 行未到达 parser，严格 parser 因此失败。根据实现，这个
marker 表示 CoreMark 算法 CRC 自检返回 PASS；不过完整传输证据缺失，本任务不把它计为
host parser PASS。`c` 没有发送，也没有任何 CoreMark 分数。

初步原因在 [T-049 实施](../handoffs/T-20260920-049-b25-coremark-uart-backpressure.md)：
`boot.S` 的 `uart_putc` 在 TX WSPACE 为 0 时仅轮询 64 个逻辑周期，然后丢弃字节；64-byte
JTAG-UART TX FIFO 装满后，约 130-byte 的 `v` summary 被截断，自动观测页随后继续出现。
现有 SoC testbench 每拍 pop TX 字符，没有模拟慢速 JTAG 主机，因此旧回归未发现此问题。

唯一 golden restore 尝试以 `Can't scan JTAG chain. Error code 86` 失败。之后
postflight 的标准 `jtagconfig -n` 显示 golden design hash/UART/PHY，但那来自保留的标准
server 缓存，不能证明 live FPGA 已恢复。T-048 后续尝试又观察到 GamePC 的 FTDI device
enumeration 为 0。当前 live FPGA identity 仍未证明为 exact golden。

## 一次性安全边界

candidate programmer=1、terminal session=1、golden programmer attempt=1；无第二次
尝试。Flash/EPCQ/JIC、reset、power、standard/unknown process stop 均为 0。唯一
task-owned JTAG server 已清理。完整 transcript、programmer results、postflight 与文件
hash inventory 位于 ignored 的 `build/agents/T-20260920-046/run/final/`；结构化证据见
[`T-20260920-046.json`](../tasks/evidence/T-20260920-046.json)。

后续先以 T-049 修复并验证 TX 背压，再重新执行 same-payload physical/assembler/一次新
板测；Golden-only recovery 必须等 GamePC 重新枚举 MPSSE Blaster 后另开隔离任务，T-046
没有重试预算。
