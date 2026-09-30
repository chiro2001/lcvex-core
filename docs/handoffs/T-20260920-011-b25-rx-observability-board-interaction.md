# T-20260920-011：RX observability 真板交接

```text
task=T-20260920-011 state=blocked-cpu-visible-rx-consumption partial=true
acceptance=BOOT/READY/bridge RX PASS; status/PONG/diagnostic/echo FAIL
final_board_state=golden SOF running
```

## 结论

使用冻结的 T-010 SOF 完成了两次成功的易失配置。候选每次均满足 Quartus
Programmer exit 0、configuration/operation success、checksum `0x316ED173` 和器件
`0x02E060DD`。启动端输出稳定为：

```text
LCVEX25 BOOT
CAL-WAIT
DDR-FAIL
READY
```

普通文件输入控制中，8 个输入字节全部被 production bridge 的 RXDBG 捕获，但没有
命令响应。为排除“启动输出尚未排空、`uart_putc` 因 TX FIFO 满而丢回复”，随后按用户
指定命令直接启动同一个交互终端，等到 `READY` 和多份零事件快照后，再逐项输入：

```text
?  -> RXDBG event 0001013F
p  -> RXDBG event 00020170
d  -> RXDBG event 00030164
Z  -> RXDBG event 0004015A
```

四次跃迁分别准确记录累计 1/2/3/4 个 RVALID 事件和最后字节
`3F/70/64/5A`。153 份快照中 DATA-read counter 始终快速递增，说明 CPU/SoC 仍在
持续轮询 DATA 寄存器；但状态行、`PONG`、诊断回复和 `Z` 回显全部缺失。因此，主机
输入方式、发送时机、JTAG Atlantic RX 以及 bridge 捕获已排除，剩余故障域是 bridge
返回数据到 PoC/core load 写回以及固件 compare/branch 之间。

## 安全收口

功能验收失败后，golden SOF 易失回滚再次满足 configuration/operation/checksum/JTAG
ID 全部通过。独立 postflight 看到 golden design hash
`193DE4BC8A30F3ED5F1F`、四个既有调试节点、标准 `jtagserver` PID 5640；无残留
Quartus/terminal，1310 端口空闲，`gamepc FREE`。全程没有 Flash/JIC/EPCQ、板级或
SoC reset、power cycle，也没有停止未知或预存进程。

## 下一步

不要再重复主机 stdin、terminal 重连或发送时机实验，也不要直接猜测性修改 RTL。
下一任务先在厂商时序等价仿真中跟踪以下四层，并用最小可证伪测试定位第一处分歧：

1. production bridge 形成的 DATA read response；
2. PoC/interconnect 返回的 response data 与握手；
3. core dmem response 的 data/valid；
4. load 扩展、提交写回值及固件比较分支。

真板直接终端 transcript SHA-256 为
`1f4e15615532afd8793dd037cfad19d44d04b92a1e135ff71ff91af59b53871c`；完整
配置、回滚、快照分组和 artifact hash 见
[`T-20260920-011.json`](../tasks/evidence/T-20260920-011.json)。
