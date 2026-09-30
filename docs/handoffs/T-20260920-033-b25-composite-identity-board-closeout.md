# T-20260920-033：B25 composite live identity board closeout

```text
task=T-20260920-033
state=blocked
base=4d7f6ea23cc868ffc8cdbbc81aab24db26e57ce7
reported_at=2026-09-20T18:47:35+08:00
evidence_parent_sha=67ddc2017fd78905f3c81037cf4227cc8ebc31f4
branch=verify/T-20260920-033-b25-composite-identity-board-closeout
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-033
remote_root=D:/Projects/fpga-altra/lcvex/build/T-20260920-033-b25-composite-identity-board-closeout
```

## 结论

本任务在唯一的
`resource-lock run gamepc lcvex T-20260920-033 board_t033 -- bash .../run_once.sh`
窗口内，于 GamePC PowerShell parser 阶段 fail-closed。五个不同的新建 `.ps1` 文件各执行
一次 parser invocation（总数 5，不是同一脚本的内部 retry），均返回 255；远端命令行拆掉了
`-Command` parser wrapper 中的 PowerShell pipeline，导致
`Out-Null` 被当作外部命令。按 T-032/T-033 合同，setup/parser 失败后不修脚本、不替换
上传物、不重试。

因此本轮没有执行 preflight、root prepare、server copy、candidate/golden
`quartus_pgm`、nios2-terminal 或任何 JTAG 硬件动作。candidate/golden marker 均未创建，
programmer invocation 均为 0，terminal session 为 0；标准 jtagserver 未停止，也没有
reset、power cycle、Flash/JIC/EPCQ 操作。remote root 由本任务未创建；由于 preflight
未到达，不能把 root 状态写成已验证 absent。

## 已完成的本地封存

- `bash -n run_once.sh`：PASS。
- `python3 -m py_compile direct_terminal.py seal_manifest.py`：PASS。
- `jq` manifest predicate 与 `git diff --check`：PASS。
- 本地脚本 manifest：`build/agents/T-20260920-033/script-manifest.json`，SHA-256
  `185be9bd1ed17ad08829ebc2a50c1c91bb9712977ad00b570b1ef3e794d9dcbd`。
- GamePC parser 失败日志均已保留在
  `build/agents/T-20260920-033/preflight/parser-*.log`；完整 wrapper summary 在
  `build/agents/T-20260920-033/final/summary.txt`。

## 边界与后续

本任务没有 hardware acceptance，也没有 golden restore 证据，不能报告 board PASS 或
最终 golden 状态。证据 JSON 记录了精确命令、SHA、状态码和零调用计数：
[`T-20260920-033.json`](../tasks/evidence/T-20260920-033.json)。若仍需板测，应新开任务，
先设计并封存不会被 Windows command layer 拆解的 parser transport，再取得新的单次
硬件窗口批准；不得在本任务内恢复执行。
