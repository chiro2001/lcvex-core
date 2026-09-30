# T-20260920-055：strict CoreMark parser 的 Windows terminal wrap 支持

```text
task=T-20260920-055 state=done
base=6e4b595060ede58971089e4407656194710e5e1e
branch=fix/T-20260920-055-coremark-terminal-wrap-parser
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-055
```

## 结果

Windows `nios2-terminal` transcript 在 column 120 对 T-053 的 compact `CMRESULT` 行做了
CSI 光标重定位并重绘最后一个字符，导致 direct-terminal 的连续字段 regex 误超时，也让
原 strict parser 只看到 compact 行前半段。Parser 现在只在以下条件同时满足时折叠这一
种显示伪影：`CMRESULT VALID` 行恰好占满 CSI 列号、ANSI 重绘字符等于上一行末字符，且
后缀从 `hz=25000000` 开始。原始 transcript 不变；未知 ANSI、错误列号、字符不匹配或
缺失字段仍拒绝。

新增合成 positive/negative 回归共 9/9 PASS。随后在 `local` resource-lock 下完整重跑
`run_microbench_tests.sh`：两次 clean build 的 ELF/BIN/HEX/MIF/manifest 逐字节一致，
host correctness `8679CF21`、CoreMark selfcheck/full_math、parser positive/negative 和
image contract 均通过；MIF SHA 仍为 `0743295f...610a2f`。

对 T-053 已封存的原始 92,694-byte transcript
运行 `parse_microbench.py --mode all` 后，microbench、自检与 official full CoreMark 均
通过；full parser 重新计算并交叉核对上游报告：

```text
iterations                 = 300
target cycles              = 442,800,996 @ 25,000,000 Hz
CoreMark/s × 1000          = 16,937  (16.937 CoreMark/s)
CoreMark/MHz × 1000        = 677    (0.677 CoreMark/MHz)
seed/list/matrix/state CRC = E9F5/E714/1FD7/8E3A
final CRC                  = 5275
upstream raw cross-check   = PASS
```

Transcript 中 `t` 返回 `MBPASS 24 8679CF21`；`v` 返回 `CMSELF PASS`，cycles
`1,479,468`、`score=INVALID`（这是 selfcheck，不是分数）。`c` 的 compact record 与上游
size/ticks/seconds/iterations/CRC/compiler flags/BRAM location/success marker 全部核对。

## 限制与安全

本修复只处理离线文本表示，不会重跑或改写 T-053 硬件证据。原 board runner/terminal
wrapper 状态仍是 exit 1：它对 `c` 使用的完整单行 regex 未识别 column-120 redraw；raw
transcript strict parser 则 PASS。失败后 task runner 已按合同执行唯一一次 golden restore；
golden programmer 与 postflight 的 exact SOF/hash/checksum/JTAG UART/PHY 均 PASS。没有
候选、terminal 或 golden 重试，也没有 Flash/reset/power 操作。

证据与 artifact hash 见
[`docs/tasks/evidence/T-20260920-055.json`](../tasks/evidence/T-20260920-055.json)。
