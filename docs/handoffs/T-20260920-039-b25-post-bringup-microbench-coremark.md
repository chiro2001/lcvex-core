# T-20260920-039：B25 BRAM microbench/CoreMark 里程碑收口

```text
task=T-20260920-039 state=done
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
closed_at=2026-09-27T22:17:07+08:00
```

## 收口结论

64 KiB BRAM-resident correctness suite 与 EEMBC CoreMark v1.01 port 已从 clean 构建到真板
闭环。两次 clean build 的 ELF/BIN/HEX/MIF 完全一致；BIN 20,448 bytes，MIF SHA-256
`0743295f...610a2f`。corrected candidate `5b33c451` 的 Gate D 152/0 全绿；fresh
physical 25 MHz setup/hold `+9.398/+0.018 ns`；单次 assembler 生成唯一 volatile SOF
`39c29454...a2def`。

真板 `t` 输出 `MBPASS 24 8679CF21`；`v` 官方 CRC 自检通过，1,479,468 cycles 并明确
标记 `score=INVALID`；`c` 的原始 JTAG-UART transcript 经 T-055 strict parser 验证：
300 iterations、25 MHz、442,800,996 个 target cycle（约 17.712 秒）、`CMRESULT VALID`、
16.937 CoreMark/s、0.677 CoreMark/MHz。Parser 独立重算定点分数，并交叉核对上游 raw
ticks/time/iterations/CRC、compiler flags、BRAM location 和 validation success marker；
不使用 host wall time。

`direct_terminal.py` 的 c-step 整行 response regex 没有适配 Windows ConHost 的 120 列
右边界 CSI redraw，导致 `run_board_once` wrapper 状态为 1。原始 transcript 完整保留；
T-055 只归一“光标列与记录长度相符、重绘字符等于前一行末字符”的单一伪影，之后完整
strict parse 与 raw report cross-check 通过。没有重试或重发 `c`，也没有改写 transcript。

## Exact golden 与安全边界

T-053 唯一 golden programmer transaction PASS；final postflight 证明 SOF SHA
`290ab3cf...5f92`、checksum `0x31510BB6`、design hash `193DE4BC8A30F3ED5F1F`、
JTAG ID、UART/PHY 节点匹配，standard server 保留，EDA=0、port1310=0。Candidate/terminal/
golden 计数严格为 1/1/1。JIC/EPCQ/Flash 写擦、reset/power-cycle、standard/unknown
process stop 均为 0。

启动序列仍显示 `DDR-FAIL`，但本 workload 明确在 64 KiB M20K BRAM；T-041 已有独立 late-
calibration `m→DDR-OK` 正控。本 batch 不扩张为 DDR/Cache stress 或 Linux 真板验收；Full-FP
release、DDR/Cache 压力和 P7/FPGA 最终同 SHA 汇合仍后置。

完整阶段证据索引见 [`docs/tasks/evidence/T-20260920-039.json`](../tasks/evidence/T-20260920-039.json)。
T-046/T-048 的历史 blocked attempts 保持不变，由后续任务取代，不删除或改写。
