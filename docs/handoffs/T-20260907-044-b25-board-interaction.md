# T-20260907-044：B25 易失配置与板级交互交接

```text
task=T-20260907-044 state=blocked-board-functional partial=true
acceptance_status=volatile-configuration-pass-console-functional-fail-golden-control-pass
candidate=d2f5cfdd2791945a82d47300b94debd0e40a96d6
execution_head=8eab1d0aff2c6e8d9887dfffb86854df54b549f7
branch=verify/T-20260907-044-b25-board-interaction
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-044
evidence=docs/tasks/evidence/T-20260907-044.json
```

## 结论

T-043 冻结的 B25 SOF 已两次通过 Quartus/JTAG 成功配置到 FPGA 易失 SRAM，但两次均
没有输出 `LCVEX25 BOOT`、`READY`、状态行或 `PONG`，发送 `?`、`p`、`Z` 也没有
响应。T-044 的板级功能验收因此未通过。

这不是烧写链路的模糊失败：第二次复测严格照历史成功流程执行，`quartus_pgm` exit 0，
SOF checksum `0x33878BC3`、JTAG ID `0x02E060DD`、`Configuration succeeded`、
`Successfully performed operation(s)` 和 0 errors/0 warnings 全部匹配。任务自建
15 MHz server 停止后 2.049 秒即启动
`JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]` 的 device 1 / instance 0；
terminal 正常连接并在 30 秒后 exit 0，但没有收到一个目标字符。

## Golden 正控

随后用同一自建 server、同一电缆和同一 Quartus 21.4 programmer 配置历史 golden：

```text
file=D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/vex_soc_ddr.sof
bytes=36844906
sha256=290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92
checksum=0x31510BB6
programmer_exit=0
elapsed=00:00:44
```

配置成功后，直接运行历史 `nios2-terminal` 命令能读到 `OpenSBI v1.9`、完整平台信息和
`Linux version 7.2.0`。短捕获未到 `Run /init`，所以这里只把它作为板卡、FTDI、
programmer 与 JTAG-UART 输出通路的正控，不扩大为完整 Linux 验收。脚本化 golden
terminal 阶段曾因 PowerShell 把空 byte array 折叠成 null 而停在写 stdin 文件处；
该错误发生在 golden 配置成功之后，直接 terminal 已补足正控。

当前板卡最终运行的是 golden SOF，不是失败的 B25 SOF。

## 安全边界与清理

- 只执行了三次易失 SOF 配置：B25 两次、golden 一次。
- 没有生成或写入 JIC/EPCQ/Flash，没有 power cycle 或板级 reset。
- 预存标准 `jtagserver.exe` PID 5640 全程保留。
- 任务自建 server PID 3452、66544、45192 均只按记录 PID 停止；端口 1310 已释放。
- 没有残留本任务 `quartus_pgm` 或 `nios2-terminal`，没有停止未知进程。
- 最终共享资源状态为 `gamepc FREE`。

## 故障收敛与下一步

外部链路已经被同路径 golden 正控证明有效，故障范围收敛到 B25 位流内部。当前最高
置信、但尚未由本任务证明的根因是综合专用 M20K wrapper 的同步读响应错拍：
`lcvex_bram_boot_altsyncram` 在接受新地址的同一时钟沿执行
`rdata_r <= req_q >> ...`，而 `req_q` 是 `altera_syncram` 沿后才更新的输出，首个
PC=0 取指可能因此返回旧值或上电值。行为级 RAM 直接读 byte array，现有仿真不会暴露
这个差异。

下一任务应先用厂商时序等价的同步 RAM stub 让旧 RTL 稳定复现 stale first read，再加入
明确 pending/capture 阶段并验证请求 offset、fault、backpressure 与 debug port 对齐。
修复必须重新跑受影响 L0-L2、BRAM oracle、B25 SoC smoke、Gate D 和 fresh physical
flow，之后才能生成新 SOF；不要再次烧写当前旧 B25 SOF。

精确时间、PID、命令、SOF/日志哈希及边界见
[`T-20260907-044.json`](../tasks/evidence/T-20260907-044.json)。
