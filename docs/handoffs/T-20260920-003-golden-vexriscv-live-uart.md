# T-20260920-003：当前 golden VexRiscv JTAG-UART 交互交接

## 结论

用户给出的命令本身正确，且已在当前设备上直接连接成功：

```powershell
D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe `
  -c "JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]" -d 1 -i 0
```

当前 FPGA 为 `02E060DD / 10AT115S`，设计 hash 是 `193DE4BC8A30F3ED5F1F`，包含
`JTAG UART #0`。直连后收到了 VexRiscv Linux 日志，内核参数明确为
`console=ttyJ0 rdinit=/init`，时钟源为 50 MHz，说明电缆、device/instance、terminal 与
target→host 通路均正常。

但当前运行实例在约 12 分钟观察内停留在 PLIC 初始化之后，没有出现 `/init` 或
`vex #`。同一会话只发送了一次无副作用 echo 标记，没有得到输入 echo、标记输出或
提示符；随后短重连也没有新输出。因此本次没有证明当前实例的 shell 双向交互，阻塞点
是 golden CPU/Linux 尚未到用户态，而不是命令行或 JTAG-UART 枚举参数。

## 已验证的交互方法

GamePC 的历史成功文件仍完整存在：

- `D:\Projects\fpga-altra\a10-linux-riscv\build\console_tx.ps1`
- `D:\Projects\fpga-altra\a10-linux-riscv\build\console_tx.txt`

脚本使用相同 cable/device/instance，通过普通文件重定向 stdin，输入
`echo SIM_TTY_OK012345`，历史 transcript 同时包含命令 echo、`SIM_TTY_OK012345`、新的
`vex #` 提示符和 exit 0。因此 golden 到达 shell 后，人工直接输入或普通文件 stdin
都能完成双向交互。

还确认了一个非破坏性的枚举恢复步骤：terminal 退出后，首个直连或首次
`jtagconfig.exe -n` 可能暂时看不到 JTAG-UART；保留既有 PID 5640，等待很短时间后再做
一次只读 `jtagconfig.exe -n`，本次即可恢复 `JTAG UART #0`。不需要重启 server。

## 安全与最终状态

没有运行 programmer，没有配置 FPGA，没有写 Flash/JIC/EPCQ，没有 reset/power，未启动
或停止任何 JTAG server，也未停止未知进程。只用 Ctrl-C 结束了任务自己的 terminal。
最终 `gamepc FREE`，标准 `jtagserver.exe` PID 5640 保留，无残留 terminal；最终只读
枚举再次看到 `JTAG UART #0`。

当前 Goal 明确禁止 reset/power，因此不能为获得新鲜 golden shell 而重启板卡。下一步
继续 T-20260920-001 的本地厂商时序 full-SoC 验证。全部命令、时间与 artifact hash 见
[`T-20260920-003.json`](../tasks/evidence/T-20260920-003.json)。
