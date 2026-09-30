# T-20260920-014：B25 firmware command trace 交接

```text
task=T-20260920-014
state=done-lightweight-validation-heavy-deferred
base=84cee3f202889fcfc036ea4545c51d1d36f9bca5
branch=verify/T-20260920-014-b25-rx-firmware-command-trace
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-014
received_at=2026-09-20T06:19:59+08:00
reported_at=2026-09-20T09:20:58+08:00
```

## 完成内容

本 lane 只修改了 boot monitor、其说明/镜像 checker 以及指定 SoC TB 的输出断言：

- `_start` 在首次输出前显式清零页索引、有效 `getc` 计数/最近 raw 值、dispatch
  计数/类别字节、成功 DATA 写计数和 timeout drop 计数；
- `uart_getc` 只在 RVALID 时记录 raw DATA 低 16 位并递增 valid 计数；低 16 位保留
  RVALID/status bits，因此 generated vendor DATA word 为 `0xA464`（`0xA400|0x64`），
  RXCPU packed event 为 `0004A464`（valid count=4）。
- `monitor_byte` 对 ping/status/memory/debug/printable echo/ignored control 记录
  class 和 byte，不改变任何原有比较、分支或命令语义；
- `uart_putc` 只在实际 `str w2,[UART_DATA]` 后递增 successful-write，64 次有限等待
  超时路径递增 drop，retry limit 保持 64；
- 启动和手动 `d` 固定输出一条 25-byte `RXDBG`，不推进 autonomous rotation；
- 每次 autonomous `0x40000` 空轮询只输出一页并轮转：
  `RXDBG` 25B → `RXPATH` 44B → `RXCPU` 43B → `RXDBG`；所有行含 CRLF 且小于 64B；
- `RXPATH` 读取冻结硬件 offsets `+0x18/+0x20/+0x28/+0x30`；三个 response offset
  只在对应 RVALID=1 时更新，空轮询不会覆盖最近有效响应；`+0x30` 的 fault 位为
  bit2=dmem、bit1=PoC、bit0=bridge。`RXCPU` 读取软件
  packed events 和 `+0x38` TX event；读取结果不参与功能握手或架构状态。

## 验证结果

- `bash fpga/catapult_a10/boot/build.sh`：PASS；AArch64 image `2011` bytes。
- `check_image_contract.py --emit`：PASS；manifest SHA-256
  `5174c22be48096a75f4a5776327bbc039b4d4ca3f01c493d137e426d6b6da8d2`。
- `check_image_contract.py --check`：PASS；独立 checker 已绑定页前缀、页长度、首次
  autonomous 页和五个硬件 offset literals。
- 静态页长度检查：`RXDBG=25B`、`RXPATH=44B`、`RXCPU=43B`，PASS；SoC TB 的
  RXCPU getc expectation 已按 generated vendor `0xA400|byte` 修正为 `0004A464`。
- combined r3 full-SoC 的 response trace 已 PASS；RXCPU 实际观察到 `0004A464`，对应
  r3 smoke log SHA-256 前缀 `941e7775`。该变更分类为 test-oracle correction，
  不涉及 firmware、RTL 或 vendor HDL 功能修改。
- Icarus probe 未作为权威验证：仓库既有 RTL 的 `inside`/SVA 语法在 Icarus 中失败，
  exit `138`，不是本 lane source error；log SHA-256 见 evidence。
- Vendor-timed Verilator/full-SoC 首次 resource-lock 返回 `75`，当时 local 被
  `pypto-x/u5-region-readonly` 占用；按照 stop rule 未重试、未轮询，结果 deferred。

精确命令、artifact/source hash、资源锁和失败边界见
[`T-20260920-014.json`](../tasks/evidence/T-20260920-014.json)。

## 边界和下一步

本 lane 未修改任何 RTL、vendor HDL、QSF/SDC、test registry 或 task JSON，也未运行
Quartus/GamePC/JTAG/板卡。待 local 锁可用后只需执行一次 vendor-timed full-SoC；通过后
由集成者与 T-013 临时 batch candidate 合并并运行受影响的 L0-L2 union。该 lane 本身不
授权任何 functional response-path RTL 修复。
