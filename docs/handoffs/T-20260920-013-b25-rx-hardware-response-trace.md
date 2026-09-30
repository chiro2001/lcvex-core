# T-20260920-013：B25 RX response path 可观测性交接

```text
task=T-20260920-013
state=focused-pass-verilator-deferred
base=84cee3f202889fcfc036ea4545c51d1d36f9bca5
implementation=7fd221ef2894daa31dc3397a165d0931e8a7a60b
review_fix=747655978c92a3c1d71824d6c7d18ed1cfd14bd7
runner_fix=25c052a79d7bbcb53a1c9b078b74f0a9dbce69d9
oracle_fix=2ef00c37e0004c2096b7bc0897e52f858382abb9
```

## 实现

本 lane 只增加 observation-only 状态，没有改变任何功能 ready/valid、请求、响应、缓存、
core/coh/router、vendor HDL 或 boot image。

新增只读状态寄存器：

- `0x09003018`：最近一次匹配 CPU UART DATA response 的 bridge 低 32 位；
- `0x09003020`：PoC/router response 低 32 位；
- `0x09003028`：core dmem response 低 32 位；
- `0x09003030`：bridge/PoC/dmem 的 RVALID 事件计数（各 8 位）及 fault sticky；
- `0x09003038`：bridge/Avalon accepted DATA-write 脉冲计数、TX-seen、最后字节。

三个 response 阶段各自以精确 `UART_DATA` 读请求 accept 建立 pending token；匹配 response
无论 fault 与否都会清除 token，只有无 fault 且 bit15=RVALID 时才更新 raw payload 和事件
计数。fault 独立 sticky。TX 字段只记录既有 bridge `tx_valid` 脉冲，不宣称 vendor FIFO
已经 enqueue。

## 验证

focused runner：

```text
fpga/catapult_a10/tools/run_rx_response_trace.sh --focused
```

结果：

- boot image contract：1204 bytes，BIN `7d8cf878…0322d4`，HEX
  `e24afca9…598e3c`，MIF `491f30c4…655c90`；
- 新增 status offset 的 Icarus reset/read/write-ignore/unknown/backpressure 测试 PASS；
- 既有 vendor registered waitrequest/showahead-OFF bridge Icarus 测试 PASS，
  `JTAG_UART_TEST PASS`。
- observation-only unit Icarus 测试 PASS，覆盖 reset、response backpressure、空
  `RVALID=0`、fault 清 pending/sticky/no-count、pending reset 和 TX pulse。

review-fix 同时把长空轮询目标改为明确的 32-bit `65536`，并增加 bounded timeout；
timeout 会失败退出而不会永久等待。每个 `? / p / d / Z` 注入前保存三层计数，完成后
分别检查 modulo-256 恰好 `+1`、完整 vendor DATA payload 为 `0xA400|byte`，并确认空轮询不产生
valid-event count。

完整 SoC response trace 命令为：

```text
fpga/catapult_a10/tools/run_rx_response_trace.sh --verilator
```

第一次 combined gate 已取得 `local`，但旧 runner 的
`-GBOOT_IMAGE=relative/path` 丢失了 string parameter 所需的双引号，Verilator 在
elaboration 前失败，vendor `--all` 尚未开始。runner fix `25c052a7` 改为
`"-GBOOT_IMAGE=\"$BOOT_HEX\""`，`bash -n`、argv 保留引号检查和最小 Verilator lint
均通过。随后 r2 已成功编译并运行到 response trace；第一失败是测试 oracle 仍期待
`0x8000|byte`，而 generated vendor DATA word 正确包含 TX/RX/AC 状态位，实际为
`0xA400|byte`。bridge、PoC、dmem 三层 full-word 完全一致，因此分类为
`test-oracle correction`，不是 response-path divergence。精确 evidence 与日志 hash 见
[`T-20260920-013.json`](../tasks/evidence/T-20260920-013.json)。

## 下一步与限制

资源锁可用后只运行一次修正 oracle 后的 `--verilator`，确认四个 `? / p / d / Z` 的
`0xA400|byte` 在 bridge、PoC、dmem 三层一致且各自 fault 为零，随后进入 vendor `--all`。
若出现首个不一致边界，
停止在 observation lane，不修改功能 RTL；之后再与 T-014 合并到临时 batch candidate。
