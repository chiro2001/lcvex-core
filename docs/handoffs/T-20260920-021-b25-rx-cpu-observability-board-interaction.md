# T-20260920-021：B25 RX CPU observability 真板交接

```text
task=T-20260920-021
state=board-functional-fail-golden-rollback-pass
branch=verify/T-20260920-021-b25-rx-cpu-observability-board-interaction
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-021
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-021-b25-rx-cpu-observability-board-interaction
```

## 结果

T-020 的唯一候选 SOF 已按冻结身份完成易失配置：

```text
bytes=36842101
sha256=d9bc9a964be9b0c0e98b16643a5d9ca44a4bce00b3694915c84714552a0ed2fd
quartus_checksum=0x3159F8A0
design_hash=4DAED3C37174544441E6912B371092CA
jtag_id=0x02E060DD
```

Programmer exit 为 0，configuration、operation、checksum、JTAG ID 均通过；任务专属
15 MHz/channel-0 server 已停止，标准 Quartus `jtagserver.exe` PID 5640 保留。

同一最终配置锁流程随后打开用户指定的直接终端：

```text
D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe -c "JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]" -d 1 -i 0
```

终端确实连接到 JTAG UART，并输出：

```text
LCVEX25 BOOT
CAL-WAIT
DDR-FAIL
READY
RXDBG 00000000 00000000
```

TX 排空后只发送了一个原始 `?`。由于其响应没有出现预期的
`CLOCK25 CAL-(OK|WAIT|FAIL) DDR-(OK|FAIL)`，按 paced-input 规则没有发送 `p/d/Z`，
随后停止本任务终端。

## 关键定位证据

`RXPATH` 连续 207 行均为：

```text
RXPATH 0000A43F 0000A43F 0000A43F 01010100
```

因此 bridge、PoC、core dmem 三个观察点都看到了相同的 `0x0000A43F`，各自 valid-event
计数为 1，fault 为 0；但 firmware 页面连续显示：

```text
RXCPU 00010000 00010000 5ABE0000 5ABE010A
```

也就是说，CPU 侧 `uart_getc` 计数为 1，但最近 raw DATA 低 16 位仍为 `0x0000`，
dispatch 只有一次 class=0/byte=0，没有进入 status 分支。`putc/TX` 计数继续推进，
说明 CPU 仍在运行并输出自主诊断页。该结果把物理失败边界进一步收窄为：观测 tap 已
看到 DATA response，而 core load 写回/固件可见值仍丢失或错位；不是主机发送、JTAG
UART bridge、PoC response 或三层 response payload 不一致。

完整直接终端 transcript：

```text
path=build/agents/T-20260920-021/terminal/direct-terminal.typescript
bytes=23917
sha256=2ac376a0390252f514405e5c48fe99f23a381e80d48a0ef0a5891f8b0d956f4e
```

## Golden 收口

功能验收失败后，重新以精确 Golden SOF 完成易失回滚。Programmer exit 0，configuration、
operation、checksum、JTAG ID 全部通过；最终独立 postflight 验证：

```text
golden_sha256=290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92
golden_design_hash=193DE4BC8A30F3ED5F1F
jtag_id=0x02E060DD
JTAG UART #0=present
standard_server_pid=5640=preserved
busy Quartus/programmer/terminal=0
port1310=free
```

第一次回滚尝试只在配置前因标准 server 暂未给出候选 design-hash 行而停止，未发生
programmer 配置；修正后的 retry 在同样的 `gamepc` 锁协议下完成 Golden 配置并通过
final design-hash 检查。没有 JIC/EPCQ/Flash、power cycle、板级/SoC reset，也没有
停止未知或预存进程。

## 后续建议

不要再重复主机输入或发送时序实验。应把本证据交给 RTL/厂商时序等价线，重点检查
`lcvex_bram_boot` M20K 同步读的 response-data 到 core dmem load/writeback 的周期对齐；
修复后必须重新完成受影响 L0–L2、Gate D、fresh physical、assembler，再开新的、内容
寻址的 volatile board interaction 任务。

精确字段、命令、artifact hash 和安全边界见
[`T-20260920-021.json`](../tasks/evidence/T-20260920-021.json)。
