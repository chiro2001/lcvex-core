# T-20260826-023：Gate D 并行 runner 资源与 fresh worktree 修复

日期：2026-08-26（Asia/Shanghai）  
基线：`5234b12b87ac4e630101c5ade34feb6e2fdae8c9`  
证据：[T-20260826-023.json](../tasks/evidence/T-20260826-023.json)

## 结果

- `run_lockstep_parallel.sh` 在 planner 无可用槽位时明确返回资源不足（退出码
  75），并在 CPU 列表为空时不会执行 `i % 0`；调用方可用 `--wait` 排队。
- Gate D、M2、P5a-Hardening 的并行入口加入 `--wait`；Gate C/P4b/P5a/M2/
  P5a-Hardening/Gate D 脚本在生成裸机镜像前显式创建 `build/difftest`，fresh
  worktree 不再因目录不存在而提前失败。
- 资源零槽位 smoke、shell syntax 和 fresh worktree `hard_dit` base/cache
  32 条严格锁步均通过。

## 后续

将本提交集成后，在新的 T-022 candidate SHA 上重新运行完整 Gate D；若资源仍
不足，脚本会排队而不是把调度错误伪装成架构失败。
