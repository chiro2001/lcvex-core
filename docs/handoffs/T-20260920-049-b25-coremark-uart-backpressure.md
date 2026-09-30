# T-20260920-049：B25 CoreMark UART TX 背压修复

```text
task=T-20260920-049 state=done-local-validation
base=30500395
branch=fix/T-20260920-049-b25-coremark-uart-backpressure
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-049
```

## 结果

T-046 真板 transcript 显示 `CMSELF PASS` 后的 summary 被截在 `state=000`，紧接着自动
RXCPU/RXPATH 页出现。检查发现 `uart_putc` 在 CONTROL.WSPACE 为 0 时只做 64 次轮询，
队列满后很快丢弃当前字节；此前 SoC 模型每个逻辑周期都 pop 一个 TX 字节，没有覆盖
JTAG/USB host 的异步 drain 节奏。

固件现在以 `UART_TX_WAIT_LIMIT=0x00100000` 次 WSPACE 轮询作为有限等待上限。它仍会在
host 永不 drain 时丢弃字符并继续运行，但给连接中的慢速 JTAG host 更充分的排空窗口。
CoreMark 算法、seed、CRC、计时源和 VALID 判定均未修改。

Vendor-timing SoC smoke 将主机 drain 限制为每 65,536 个 logic cycle pop 一个 FIFO 字节。
在 64-byte FIFO 下，完整输出仍到达：

```text
MBPASS 24 8679CF21
CMSELF PASS seed=0000E9F5 list=0000E714 matrix=00001FD7 state=00008E3A final=0000E714 iterations=1 cycles=1479468 score=INVALID
```

strict `microbench` 与 `selfcheck` parser 均通过。behavioral 与 Quartus 21.4 registered-vendor
timing 两种完整 SoC 场景都显示 `SOC_B25_ALL_PASS`，CAL-OK/WAIT/FAIL、`t`、启动诊断页与
UART exactly-once 检查全绿。full `c` 仍留给真板，不把仿真时间当作目标时间，也未报告
CoreMark 分数。

## Image identity

两次 offline build 的 ELF/BIN/HEX/MIF/manifest 逐字节一致，image size 仍为 20,448 bytes，
BSS 仍在 `0x58f8`；64 KiB BRAM geometry 与 stack reserve 不变。

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `boot.bin` | 20,448 | `241b0ce4dface8c4a9db782b63e4ada8674f5c8b51c00f228a795e98fc1aedab` |
| `boot.hex` | 61,344 | `93cbacda0b8d22864534da5f62ec8f6161ff69ede9eca10e0df2638e995709ab` |
| `boot.mif` | 204,942 | `0743295f90cb75e4d21092012c723bc9da4b6d055f13d46958cbd572bd610a2f` |
| build manifest | 3,641 | `d9a087765da1839ed4a2847132999e8755807300f06c015b6f5bae4cd632cd3a` |

该 MIF 与 T-045 的 payload 不同，后续必须按它重新 Gate/physical/assembler，不能沿用旧
SOF。T-049 未运行 Quartus、JTAG、板卡、Flash、reset 或 power 操作。

完整命令、lock 与 artifact hashes 见
[`docs/tasks/evidence/T-20260920-049.json`](../tasks/evidence/T-20260920-049.json)。
ignored 运行数据位于 `build/agents/T-20260920-049/`。
