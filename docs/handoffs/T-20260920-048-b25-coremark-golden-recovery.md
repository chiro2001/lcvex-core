# T-20260920-048：T-046 后 exact golden-only recovery

```text
task=T-20260920-048 state=blocked
base=890002aa503159aa9310f14718acf88145d4975e
branch=verify/T-20260920-048-b25-coremark-golden-recovery
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-048
remote_root=D:/Projects/fpga-altra/lcvex/build/T-20260920-048-b25-coremark-golden-recovery
started_at=2026-09-27T15:50:39+08:00
finished_at=2026-09-27T15:50:48+08:00
```

## 结果

T-047 的九个 sealed 工具逐文件 SHA-256 与 `cmp` 完全一致；fresh root/bootstrap、
PowerShell AST 6/6 与 seal 9/9 均通过。初始冲突检查为 EDA=0、port 1310=0、标准
`jtagserver.exe`=1。脚本创建唯一 `golden-quartus-pgm.once` marker 后，唯一 golden
`quartus_pgm` 尝试以 `Error (213013): Programming hardware cable not detected` 失败，
未检测到器件、未执行配置操作。task-owned server 由脚本清理；没有 candidate、terminal、
JTAG reset、Flash 或 power 操作，也没有第二次 programmer 尝试。

`ftd2xx_shim.log` 仅 72 bytes：两次 `FT_CreateDeviceInfoList()` 都返回 `n=0`。随后在
锁窗口之外进行的一次只读 GamePC PnP 查询未发现匹配 `FTDI/Single RS232-HS/MPSSE/Blaster`
的条目。这与 programmer 的 cable-not-detected 错误一致，说明当前 GamePC 未枚举目标
Blaster；无法证明 live FPGA 当前身份。不得把 standard JTAG server 的缓存视图当作
golden 配置成功证据。

## Evidence

- sealed source manifest：SHA-256
  `2972d24292de061ed06e98aa68ce3f4443ca041caa3cba1bca632e223542dfcc`；
- generated task manifest：`build/agents/T-20260920-048/script-manifest.json`，SHA-256
  `8caae59b8e4083ea87a745a61f55b1813604e10c30936b8acf438513afdd9697`；
- summary：`build/agents/T-20260920-048/run/summary.txt`，SHA-256
  `d662ef633d8a3c89d13d43fe5176ceef870c7c7aaf7aef945c77be7e0954b32c`；
- raw programmer stdout：38 bytes，SHA-256
  `bf9f06b0b4b6a948962f90f2f6119b42117712812c39f01dbc13bcae544b38bc`；
- owned FTDI shim log：72 bytes，SHA-256
  `bdd9448e0fecea152a819226aa09535d1a24afb61c439a55d1b462bf1429738c`；
- durable golden marker：SHA-256
  `4e0e88a27d0e8d6871b035894ca711266e4df6bb6192711f9557ad0a336b6e97`；
- structured evidence：[`docs/tasks/evidence/T-20260920-048.json`](../tasks/evidence/T-20260920-048.json)。

`gamepc` lock 已释放。恢复需要 GamePC 重新枚举 Blaster；本 task 的单次 programmer budget
已消耗，禁止在 T-048 重试。T-049 处理本地 BRAM monitor 的 UART TX FIFO 背压/超时缺陷，
不访问板卡。
