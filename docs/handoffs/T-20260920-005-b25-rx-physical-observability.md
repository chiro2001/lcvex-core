# T-20260920-005：B25 RX 物理自报告可观测性交接

## 结论

实现提交 `8f25c8e1` 已通过受影响 L0–L2。它不猜测性改变 JTAG-UART 功能路径，而是在
现有 production bridge 的实际 DATA 完成点记录：

- `PLAT_STATUS+0x8`：32 位 completed DATA-read count；
- `PLAT_STATUS+0x10`：RVALID count、RX-seen sticky 和 last byte；
- 全部状态随 `logic_rst_n` 清零，只在 DATA read 完成时更新；
- status 响应在 backpressure 下保持稳定，写入无副作用。

BRAM monitor 在 `READY` 后立即输出：

```text
RXDBG 00000000 00000000
```

之后每 `0x40000` 次空 DATA 轮询自动上报，不依赖 host 输入；`d` 可主动请求一次相同
快照，但原有 `p/?/m/printable echo` 语义不变。真板若 read count 增长但 event word 保持
零，故障位于实际 Atlantic/vendor RX FIFO 到 DATA.RVALID 之前；若 RVALID/last byte
出现，则问题已进入 bridge 之后的软件可见路径。

最终验证结果：

- vendor/behavioral bridge 的 Icarus 与 Verilator 全绿；
- status register 的 Icarus 与 Verilator 全绿；
- vendor full-SoC 在 `262,144` 次空读取、`2,359,302` 次提交后通过周期 RXDBG、动态
  RXDBG、PONG/status/echo；CAL-OK/WAIT/FAIL 全绿；
- behavioral full-SoC 三场景全绿；
- ELF-derived boot oracle、13/13 负例与 BRAM Verilator 全绿；boot.bin 1204 bytes；
- skeleton、synthesis selector、registry 均通过。

第一次 BRAM heavy probe 因未预建指定 TMPDIR 而被 Make 回退到 `/tmp`，虽功能通过但不
作为证据；已在预建任务目录的 `heavy-final-v2` 原样重跑通过。

下一步把 `8f25c8e1` 串行合入 batch candidate，在合并 SHA 上运行完整 Gate D；Gate D
通过后才允许 fresh Quartus synthesis/fitter/STA/UCP、assembler 和一次 instrumented
易失板测。精确日志 hash 见
[`T-20260920-005.json`](../tasks/evidence/T-20260920-005.json)。
