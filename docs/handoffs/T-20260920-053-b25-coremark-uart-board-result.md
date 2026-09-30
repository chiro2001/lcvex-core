# T-20260920-053：B25 microbench/CoreMark 真板闭环

```text
task=T-20260920-053 state=done
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
SOF=36,842,099 bytes / 39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def
gamepc_lock=one uninterrupted T-053 window
```

## 结果

T-053 在用户 attestation 与 T-054 限定的 preflight policy 下完成：present-only FTDI
0403:6014、MPSSE cable、JTAG ID、UART/PHY、EDA/port 与 exact SOF 文件身份都通过。
`jtagconfig -n` 初始 design hash `BD13E12CD20E8B71E260` 只作诊断；用户确认的 Flash
启动参考基线作为人工 attestation，不把该标准 server hash 冒充 live identity。

冻结 candidate `39c29454...a2def` 只配置一次：Quartus exit=0，configuration/operation/
checksum/JTAG-ID 全部 PASS。唯一 terminal session 各发送 `t/v/c` 一个字节：

- `t`：`MBPASS 24 8679CF21`；24 项 correctness 全通过；
- `v`：`CMSELF PASS`，seed/list/matrix/state=`E9F5/E714/1FD7/8E3A`，
  final=`E714`、iterations=1、cycles=1,479,468，`score=INVALID`（明确不是分数）；
- `c`：原始 transcript 含完整上游 CoreMark 输出和 `CMRESULT VALID`。T-055 strict parser
  对原始 92,694-byte transcript 做精确 Windows column-120 CSI 重绘归一后，全字段重算与
  upstream cross-check PASS：

  ```text
  iterations=300 cycles=442800996 hz=25000000
  cms_x1000=16937  (16.937 CoreMark/s)
  cmmhz_x1000=677  (0.677 CoreMark/MHz)
  seed/list/matrix/state/final CRC=E9F5/E714/1FD7/8E3A/5275
  CoreMark Size=666; Memory location=64KiB M20K BRAM
  ```

Cycles 来自板上 25 MHz logic counter，对应 17.71203984 秒；没有使用 host wall time。严格
parser核对 size、ticks、seconds、iterations、iterations/sec、CRC、GCC 16.1.0、固定 compiler
flags、BRAM location 和 upstream validation marker。CoreMark score 可信、可复算。

## Terminal 渲染偏差与 golden 收口

`direct_terminal` 的完整 c 行 regex 因 Windows ConHost 恰在 120 列做右边界重绘而超时，
使 `run_board_once` 外层状态为 1。没有因此发送任何重试字节或第二个 terminal session。
原始 transcript 完整保留；T-055 parser 只折叠列号正确且与上一字符相同的单一 CSI redraw，
随后依旧执行全部 raw report/score 校验。该偏差和 SHA-256 记录于
[`docs/tasks/evidence/T-20260920-053-attempt-02.json`](../tasks/evidence/T-20260920-053-attempt-02.json)。

失败处理按单次预算执行后，唯一 golden restore 交易 PASS；final postflight 同时证明
golden SOF SHA `290ab3cf...5f92`、checksum `0x31510BB6`、design hash
`193DE4BC8A30F3ED5F1F`、JTAG ID `0x02E060DD`、UART/PHY 节点、无 EDA 残留和 port1310
释放。standard `jtagserver` PID 5640 保留。没有 JIC/EPCQ/Flash、reset、power-cycle 或
standard/unknown process stop；candidate/terminal/golden 计数严格为 1/1/1，无重试。

启动串口显示 `DDR-FAIL`，但该 workload 的官方报告确认全部位于 64 KiB M20K BRAM；本任务
不作 DDR/Cache/Linux 验收声明，也未在唯一 t/v/c 会话中插入 `m` 命令。T-041 已有单独的
late-calibration `m→DDR-OK` 证据；外部 DDR 压力与 Linux 真板仍后置。
