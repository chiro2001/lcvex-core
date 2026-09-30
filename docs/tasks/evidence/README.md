# 任务验证证据

每个进入 `review` 的任务提交一份 `<task-id>.json`，格式参考 `TEMPLATE.json`。它是
精确命令、结果和 artifact manifest 的机器事实源；handoff 只引用 run/artifact ID
并解释结论，不重复整份数据。

owner 创建初版，记录 `base_sha/head_sha` 和自己运行的证据，此时 `merge_sha` 可以
为空。集成者合入后填写 `merge_sha`，追加 `runner_role=integrator` 的复跑；任务
`done` 前必须补齐，归档后不可改写。后续回归另建任务/evidence。

每次运行至少记录 run ID、source SHA、执行者角色、层级、精确命令、seed、工具与
QEMU 版本/hash、耗时、退出码和结果；实际可采集时再记录 CPU、cpuset、峰值 RSS、
磁盘增量。大产物不入 Git，只记录持久 URI、owner/retention、SHA256 和重建命令。
