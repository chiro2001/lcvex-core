# T-20260906-025：跨项目资源锁与动态本机预算

状态：done  
base：`8d35b6d61669a7b61c8b2fb49e3665bf0e585db4`  
implementation：`f9792d12d42d6bd8323f8ce311b7136c74d4d034`  
reported_at：`2026-09-06T07:49:12+08:00`

## 结论

`/home/chiro/projects/.resource-locks/resource-lock` 已成为 LCVEX 与其他项目共享
本机 heavy 和 GamePC 的原子互斥入口。包装器由本地监督进程持有 guard，目标命令
即使关闭继承 FD 也不会提前释放锁；正常退出传播子进程退出码并清理自己的 PID。

取得 `local` 后不再强制 50% CPU/内存或 16 GiB cgroup 上限。集成者仍须按启动时
资源、历史峰值和桌面负载选择并记录最低准入、并行度及可选 cgroup。共享锁不是
终止非任务进程、忽略 OOM 风险或并行启动多个本机 heavy 作业的许可。

现有 T-024 fitter 没有被重启；物理代理已用同步 adopted watcher 取得 `gamepc`，
生产状态已从假 `FREE` 修正为可审计的 `BUSY`。后续 STA/custom STA 也必须取得
`gamepc` 锁。

## 验证

隔离自测覆盖忙锁冲突、PID/metadata、关闭继承 FD、退出码传播、正常清理、可选
内存准入和双资源锁，结果 PASS。精确命令和 SHA256 见
[`T-20260906-025.json`](../tasks/evidence/T-20260906-025.json)。

## 已知边界

协议提供独占互斥，不提供公平队列或容量切片。本地监督进程若被 `SIGKILL`，远端
作业可能仍存活；接管 stale GamePC 状态后仍必须执行远端作业存活准入检查。
