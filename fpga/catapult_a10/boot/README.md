# Catapult A10 25 MHz BRAM 常驻监控程序（B25）

启动地址图（见 `rtl/lcvex_catapult_soc_pkg.sv`）：

| 窗口 | 地址 | 用途 |
| --- | --- | --- |
| BRAM | `[0x00000000,0x00010000)` | 64 KiB 复位向量、监控程序与栈 |
| BRAM stack | `[0x0000F000,0x00010000)` | 向下增长的 4 KiB 栈 |
| DDR4 | `[0x40000000,0x48000000)` | 128 MiB 诊断窗口 |
| JTAG-UART DATA | `0x09000000` | 轮询收发数据 |
| JTAG-UART CONTROL | `0x09000004` | TX WSPACE 状态 |
| PLAT_STATUS | `0x09003000` | bit0=cal_ready、bit1=cal_failed、bit2=ddr_en、bits15:8=version |
| JTAG RX read count | `0x09003008` | 已完成的 DATA 读取次数，32 位自然回绕 |
| JTAG RX event | `0x09003010` | bits31:16=RVALID 次数、bit8=seen sticky、bits7:0=last byte |
| JTAG bridge response | `0x09003018` | 最近一次匹配 RVALID=1 的 UART DATA 响应低 32 位；空轮询不覆盖 |
| JTAG PoC response | `0x09003020` | 最近一次匹配 RVALID=1 的 UART DATA 响应低 32 位；空轮询不覆盖 |
| JTAG core dmem response | `0x09003028` | 最近一次匹配 RVALID=1 的 UART DATA 响应低 32 位；空轮询不覆盖 |
| JTAG response path events | `0x09003030` | bits31:24=bridge、23:16=PoC、15:8=dmem；bit2=dmem fault、bit1=PoC fault、bit0=bridge fault |
| JTAG TX event | `0x09003038` | bits31:16=accepted DATA writes、bit8=seen、bits7:0=last byte |
| Logic cycle counter | `0x09003040` | 只读 64 位、reset=0、每个 25 MHz `logic_clk` 加 1，响应接受时原子采样 |

`boot.S` 全程驻留在 BRAM：从 PC=0 设置栈，有限等待 DDR 校准，只在
`CAL-OK` 时执行一次 uncached DDR magic 写读，然后无论成功或失败都进入可交互
监控循环。启动 transcript 为四行：

```text
LCVEX25 BOOT
CAL-OK | CAL-FAIL | CAL-WAIT
DDR-OK | DDR-FAIL
READY
RXDBG 00000000 00000000
```

`RXDBG` 不依赖 host 输入：`READY` 后只输出启动页一次，此后每 `0x40000` 次空 DATA
轮询输出一个诊断页。启动页固定为 `RXDBG`，且不推进页索引；第一次 autonomous 页仍为
`RXDBG`，之后按
`RXDBG -> RXPATH -> RXCPU -> RXDBG` 轮转，每次只发一页，且包含 CRLF 的整行短于
vendor TX FIFO 的 64 bytes：

```text
RXDBG  <read-count:8hex> <RX-event:8hex>\r\n
RXPATH <bridge-response:8hex> <PoC-response:8hex> <dmem-response:8hex> <path-events:8hex>\r\n
RXCPU  <getc-event:8hex> <dispatch-event:8hex> <putc-event:8hex> <TX-event:8hex>\r\n
```

`RXPATH` 的硬件字段来自只读的 `+0x18/+0x20/+0x28/+0x30`；`RXCPU` 的软件字段为：

- `getc-event`：bits31:16=有效 `uart_getc` 次数，bits15:0=最近一次有效 DATA 原始值低 16 位（包含 generated vendor word 的 RVALID/status bits；vendor word 为 `0xA400|byte`，例如 `d` 为 `0xA464`，四次有效读取后的 packed event 为 `0x0004A464`）；
- `dispatch-event`：bits31:16=dispatch 次数，bits15:8=类别，bits7:0=字节；类别
  `0=ignored`、`1=ping`、`2=status`、`3=memory`、`4=debug`、`5=printable echo`；
- `putc-event`：bits31:16=成功 DATA 写次数，bits15:0=有限等待丢弃次数；
- `TX-event`：硬件 `+0x38` 的 accepted DATA-write count/seen/last byte。

所有软件观测变量在 `_start` 显式清零；硬件状态由 `logic_rst_n` 清零。观测路径不驱动
ready/valid、请求、响应或架构状态。`d` 仍立即输出一条 `RXDBG`，不消耗 autonomous
页轮转槽位。这样可以分别判断字节是否到达 bridge、响应是否沿 PoC/dmem 到达 CPU、
`uart_getc` 是否认为有效、命令是否分派以及 `uart_putc` 是否实际写入或丢弃。

监控命令是单字符轮询协议：`p` 返回 `PONG`，`?` 返回时钟/校准/DDR状态，
`m` 在校准可用时重新执行DDR诊断，`d` 立即输出一次 `RXDBG`；`t` 运行 24 项
CPU correctness microbench 并输出 `MBPASS 24 8679CF21`；`v` 运行一次 CoreMark
官方 seed/CRC 短自检并明确输出 `score=INVALID`；`c` 自动标定并运行不少于
250,000,000 个 25 MHz cycle 的标准 CoreMark。其他可打印字符原样回显。每个有效
输入字节均进入 firmware dispatch 观测；类别 `6/7/8` 分别为 `t/v/c`，控制字节类别
为 `0` 且仍被忽略。
启动和命令输出都在
JTAG-UART TX 无空间时最多等待 `UART_TX_WAIT_LIMIT=0x00100000` 次 WSPACE 轮询，再丢弃
当前字符，避免未连接 host 时永久阻塞。每次轮询会执行 Avalon CONTROL 读取；该有限
窗口允许异步 JTAG/USB host 排空 64-byte TX FIFO。完整 CoreMark 报告在计时结束后输出，
其所有字节仍受同一背压处理；真板验收要求 parser 收到完整 raw 报告。
启动校准等待当前为256次PLAT_STATUS轮询（25 MHz下约10微秒量级）；真实EMIF若
稍后才完成校准，首次会报告`CAL-WAIT/DDR-FAIL/READY`，host可随后用`?`刷新状态并
用`m`重试DDR诊断。

构建需要 GNU AArch64 GCC/binutils 与 Python 3：

```sh
bash fpga/catapult_a10/boot/build.sh
```

同一个 ELF 生成 `boot.bin`、逐字节 little-endian `boot.hex` 和
`WIDTH=64, DEPTH=8192` 的 `boot.mif`；构建会回读 MIF 并逐字节核对。产物均位于
ignored 的 `boot/build/`，不提交 Git。`microbench-build-manifest.json` 记录编译器、
flags、固定上游 CoreMark、seed/计时合同以及 ELF/BIN/HEX/MIF/source hash。历史兼容
的 `ddr.bin/ddr.hex` 不参与B25启动、仿真或物理镜像。

系统级验证：

```sh
VERILATOR_JOBS=1 bash fpga/catapult_a10/tools/run_soc_smoke.sh
```

该测试用真实 B25 64 KiB/64-set/1-way参数从同源 HEX 的 PC=0 启动，覆盖
CAL-OK/WAIT/FAIL、真实 EMIF read/write、完整启动 transcript、PONG、状态、重测和
字符 exactly-once 回显，并在同一镜像上要求 `t` correctness 签名与 `v` CoreMark
官方 CRC 短自检通过。完整 `c` 的十秒测量只在真板执行，避免把 host 仿真耗时误当
作目标 cycle。
