# T-20260920-053：corrected CoreMark 真板验收

```text
task=T-20260920-053 state=blocked
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
candidate_sof_sha256=39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def
preflight_at=2026-09-27T19:06:03+08:00
```

## 结论

用户确认板卡已上电并接入 GamePC 后，T-053 在一个 `gamepc` resource-lock 窗口内执行了
present-only PnP 和只读初始 chain preflight。`Get-PnpDevice -PresentOnly` 找到两个状态
为 OK 的 FTDI 0403:6014 条目；候选 SOF 和 golden SOF 的路径、长度与 SHA-256 均精确匹配。
EDA 冲突=0、port 1310 listener=0，标准 `jtagserver.exe` 唯一且保持运行。

唯一一次 `jtagconfig -n` 返回 exit 0，报告 MPSSE Blaster、JTAG ID `02E060DD`、JTAG
UART/PHY 节点，但 design hash 为 `BD13E12CD20E8B71E260`，不匹配冻结 golden
`193DE4BC8A30F3ED5F1F`。因此 preflight fail-closed；没有调用 board runner，也没有创建
T-053 远端 task root/bootstrap。

## 安全边界

本轮只进行了 present-only PnP 查询和一次只读 `jtagconfig -n`。Candidate programming、
terminal `t/v/c`、golden programming、Flash/EPCQ、reset/power 与 process stop 均为 0；
GamePC 锁已释放。`BD13...` 仅记录为 standard-server chain 的观察值；由于既有审计确认
design hash 可能来自缓存，不能据此断言 live FPGA 就是该设计，更不能把它当作 exact
golden 证明。

继续前必须解决初始 golden 门禁：要么用户授权在独立任务里先做一次 golden-only volatile
恢复（这会在 T-053 最终 golden restore 之外新增一次 programmer transaction），要么由用户
手动恢复并确认 exact golden 后重新执行只读前置检查。T-053 原有的一次 candidate、一次
terminal `t/v/c` 和一次最终 golden 预算均未消耗。不得直接跳过初始状态门禁。

结构化证据见 [`docs/tasks/evidence/T-20260920-053.json`](../tasks/evidence/T-20260920-053.json)。
本次原始预检日志在 ignored 的 `build/agents/T-20260920-053/run/`。
