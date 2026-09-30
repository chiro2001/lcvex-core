# T-20260920-053 continuation：Flash-attested initial baseline

T-053 首次只读 preflight 已封存为
[`docs/tasks/evidence/T-20260920-053.json`](../tasks/evidence/T-20260920-053.json)。它确认
FTDI 0403:6014、MPSSE cable、JTAG ID 与 UART/PHY 当前可见，但 standard `jtagconfig -n`
报出的 `BD13E12CD20E8B71E260` 不等于归档 SOF 的 `193DE4BC8A30F3ED5F1F`。当时没有配置
FPGA，也没有消耗 candidate、terminal 或 golden transaction 预算。

随后用户确认板卡上电后已从 Flash 加载并启动 VexRiscv/Linux 参考设计，并要求重新检查
烧录方式。SOP 与参考项目记录确认：正确方式是 `quartus_pgm -m JTAG -o p;<SOF>` 直接
加载 volatile SOF，不写 Flash；standard server design hash 可能是缓存观察值，不能单独
作为 live image proof。T-054 为这一明确的人为初始状态 attestation 增加了窄化政策：默认
任务的 exact-golden hash gate 不变；只有 T-053 固定 candidate/golden 和固定 attestation
token 可以忽略初始 hash 相等性，但 cable/JTAG-ID/UART/PHY、EDA/端口、SOF identity 均保留；
测试结束仍必须一次 exact-golden 编程并 postflight 证明。

T-054 在本地 `make b25-board-runner-check` 25/25 PASS 后已 fast-forward 到本分支
`9299d18e`。新 T-053 contract 已按固定 SOF 身份生成并通过 local validator；`run_t053.sh`
使用新的独立 ignored 输出目录 `run-attested-flash-baseline`，旧失败现场不覆盖。

下一步在一个 `gamepc` resource-lock 窗口内执行 remote AST/seal、present-only PnP 与
user-attested read-only preflight；只有全部通过才进入一次 candidate、一个 `t/v/c` terminal
session、一次 final golden restore。尚未执行本轮任何配置；远端 AST/seal 门禁仍在前。
