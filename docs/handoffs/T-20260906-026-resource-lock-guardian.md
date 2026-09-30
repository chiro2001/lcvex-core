# T-20260906-026：resource-lock guardian 加固

状态：done  
base：`bc2afb02`  
implementation：`8f0d06540e8a381fe40c23484ee47b7f2269169e`  
reported_at：`2026-09-06T08:05:39+08:00`

## 结论

用户报告的 fail-open 成立并已修复。外层 `resource-lock` Bash 不再是唯一 guard
持有者：主 guardian 在实际任务启动前建立 pidfd lease keeper，并完成 readiness
握手后才放行任务 `exec`。实际任务不继承 guard FD。

对外层 Bash 或主 guardian 分别执行单点 `SIGKILL` 时，仍有 keeper/另一持有者保持
guard；第二个 owner 只能看到 `BUSY guardian=active`，并且内核 `flock` 获取失败。
只有实际任务根进程退出、pidfd 变为 readable 后，keeper 才释放最后一份锁。

## 验证

隔离自测先让任务关闭全部 `fd >= 3`，再分别强杀外层 Bash 和主 guardian。两次
故障注入中锁均保持 BUSY；阻塞竞争者只在任务退出后获得 guard。原有互斥、元数据、
退出码、准入和双锁测试也全部通过。未对生产 owner 做故障注入。

精确哈希与验证矩阵见
[`T-20260906-026.json`](../tasks/evidence/T-20260906-026.json)。

## 边界

整机故障、同时强杀全部持锁者或目标 daemonize 仍可能留下远端孤儿，因此 GamePC
接管 stale 状态后仍必须执行远端作业存活检查。
