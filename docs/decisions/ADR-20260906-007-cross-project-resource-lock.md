# ADR-20260906-007：跨项目重型资源锁与动态本机预算

日期：2026-09-06

状态：accepted

## 背景

LCVEX 原先以“本机最多 50% CPU/内存、Verilator cgroup 小于 16 GiB”避免同机多个
Agent 的重型任务相互挤压。该办法不能协调 `/home/chiro/projects` 下的其他项目，
也会在本机已独占时不必要地限制可用资源。GamePC 同样缺少跨项目的原子占用事实源。

## 决定

跨项目重型资源事实源固定为：

```text
/home/chiro/projects/.resource-locks/resource-lock
```

- 本机 heavy 作业必须取得 `local`；GamePC heavy 作业必须取得 `gamepc`。
- 同时需要两项资源时由包装器固定按 `local`、`gamepc` 顺序取得。
- 返回 75 表示资源忙，调用方等待，不允许绕过包装器裸跑。
- 持有 `local` 后不再强制 50% 或 16 GiB 固定上限。集成者依据当前
  `MemAvailable`、历史峰值、桌面负载和任务类型选择最低准入、并行度与可选 cgroup。
- 每次重任务在 evidence 中记录锁资源、owner 元数据、准入快照、并行度、实际
  cgroup（若有）和峰值资源。
- 独占锁不授权结束 VRChat、SteamVR 或其他非任务进程，也不替代运行中资源监控。
- 本机与 GamePC 是独立资源，输入/产物隔离时可以由不同项目同时使用。

## 迁移与失效处理

协议启用前已运行的任务以受 `gamepc` 锁保护的同步前台 watcher 暂时接管；watcher
必须等远端目标进入终态后才退出。后续每个 stage 重新原子取得锁。

锁使用 owner PID、boot ID、start ticks 和稳定 guard inode 上的 `flock`。
外层 Bash 取锁后启动主 guardian；guardian 在放行实际任务前，先为任务
根 PID 建立 `pidfd` 并启动备用 lease keeper。实际任务显式关闭 guard FD，
而外层 Bash、主 guardian 和 keeper 保留同一 locked open-file description。
因此外层 Bash 或主 guardian 任一单点 `SIGKILL` 都不会在任务存活时释放锁。

正常退出清理 PID 文件；异常退出时，只要 guardian/keeper 仍存活，guard
锁就仍是最终互斥事实，`status` 显示 `BUSY guardian=active`。整机崩溃、同时
强杀所有持锁者或违反协议让任务 daemonize 仍可能产生远端孤儿；新的
GamePC owner 在接管 stale 状态后仍必须检查远端 EDA/作业进程。

## 后果

本机独占任务可按实际资源提高内存上限或并行度，减少固定 16 GiB造成的无谓失败；
跨项目同时启动同类 heavy 作业的风险由原子锁消除。代价是该协议只提供独占互斥，
不提供公平队列或容量切片；若未来要同机并行多个受限 heavy 作业，需另设容量令牌。
