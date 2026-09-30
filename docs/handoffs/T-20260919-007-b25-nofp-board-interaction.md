# T-20260919-007：corrected no-FP B25 板级交互交接

```text
task=T-20260919-007 state=blocked-board-rx partial=true
source=a64d2a4f6c41fc80e09132e8a915cd631ab5ffc5
branch=verify/T-20260919-007-b25-nofp-board-interaction
evidence=docs/tasks/evidence/T-20260919-007.json
```

## 结论

T-006 的 corrected no-FP SOF 已通过 15 MHz 自建 server 成功配置：programmer exit 0，
configuration/operation、checksum `0x31426358` 与 JTAG ID `0x02E060DD` 全部匹配。
首次标准 console 连接后，真板明确输出：

```text
LCVEX25 BOOT
CAL-WAIT
DDR-FAIL
READY
```

因此 PC=0/M20K 修复已经由硬件证明有效，启动代码也执行到了常驻 monitor。剩余功能门
没有通过：裸字节、换行 pipe、PTY 以及参考工程相同的普通文件重定向输入均未得到状态、
`PONG` 或 `Z` 回显。最强失败证据是 v6：terminal 正常连接并自然 exit 0，输入文件依次为
`?`、`p`、`Z`（每项带 LF），但输出中没有任何目标响应。

## Golden 与工具状态

同一已封存 golden SOF 三次易失配置均成功，首个 terminal 会话能持续读到 OpenSBI 和
Linux，继续证明板卡、配置链及 JTAG-UART 输出方向有效。未经授权触发 `0x1E`/reset 时，
golden 在 360 秒内未到 `vex #`，因此本轮没有伪称当前 golden 输入正控成功。历史同板、
同 cable、同 `nios2-terminal` 的 `console_tx.ps1`/`console_tx.txt` 已证明普通文件 stdin
可产生 `SIM_TTY_OK012345` 命令回显、输出和新 prompt，但这里只作为历史参考。

标准 server PID 5640 在 terminal 退出后可能继续枚举 FPGA 链却暂时找不到 JTAG-UART；
等待 12 分钟也未恢复。它从未被停止或重启。所有第二会话的“无 UART”结果都没有拿来
指控候选 RTL；权威候选失败来自能够连接的首次/v6 会话。

## 本地诊断与下一步

两个任务私有、未入库的 focused 原型均通过：一是注册 waitrequest/read_0/RVALID 与
showahead-OFF FIFO-q 的时序等价模型，二是直接实例化生成 IP 控制逻辑并在 FIFO 边界
注入一个 RX 字节。它们说明目前没有证据直接修改孤立 bridge。

下一步应另立任务，把真实生成 IP 的注册读时序接入 full SoC，并在 READY 后先执行长时间
空轮询再注入 RX；必须先复现硬件缺口，才允许修改 `lcvex_catapult_soc_jtag_uart`。若证明
RTL 缺陷，则按完整流程重跑受影响 L0-L2、Gate D、fresh Quartus physical、assembler 和
易失板测。

最终板卡运行 golden SOF。总计只做 4 次易失配置（candidate 1、golden 3）；没有
JIC/EPCQ/Flash、power/reset，也没有停止未知或既有进程。任务 server 均按记录 PID 停止，
无残留 programmer/terminal，端口 1310 已释放，`gamepc FREE`。
