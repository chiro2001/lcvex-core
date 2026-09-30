# T-20260920-002：B25 首会话普通文件输入正控交接

## 结论

方法歧义已经消除。精确 T-006 SOF 重新易失配置成功后，没有运行任何 console 预探测；
配置结束约 2 秒即启动第一个且唯一的标准 `nios2-terminal`，并用历史成功机制
`Start-Process -RedirectStandardInput <ordinary file>` 输入 `?`、`p`、`Z`（每项带 LF）。

同一会话连接成功、自然 exit 0，并完整收到：

```text
LCVEX25 BOOT
CAL-WAIT
DDR-FAIL
READY
```

但没有状态行、`PONG` 或 `Z` 回显。因此失败不再能解释为 Python pipe、后续会话 stale、
预探测占用、晚连接、错误 SOF 或配置失败；问题可靠收敛到 corrected candidate 的
host→target fabric/软件读取路径。

失败后已用同一易失路径成功恢复 content-addressed golden。最终板上运行 golden SOF；
没有 JIC/EPCQ/Flash、reset/power，也没有停止标准 server PID 5640 或任何未知进程。
任务 server PID 29352/35076 均已停止，无残留 terminal/programmer，端口 1310 已释放。

下一步只继续 T-20260920-001 的厂商时序等价 full-SoC 复现；本方法控制不得重复。精确
命令、时间、PID、hash 与产物索引见
[`T-20260920-002.json`](../tasks/evidence/T-20260920-002.json)。
