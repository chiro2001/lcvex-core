# T-20260920-034：B25 参数化 runner transport/seal

```text
task=T-20260920-034
state=blocked
base=464026858d6f4061d14640ae065d7201a9e00691
reported_at=2026-09-20T19:15:04+08:00
branch=infra/T-20260920-034-b25-board-runner-transport-seal
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-034
```

## 本地 bundle

已在 ignored 目录 `build/agents/T-20260920-034/tools/` 生成参数化 bundle：

- `prepare_task_root.ps1`、`validate_scripts.ps1`、`verify_seal.ps1`、`preflight.ps1`、
  `program_once.ps1`、`postflight.ps1`；
- `direct_terminal.py`：单 terminal 会话，输入前严格检查 BOOT/CAL/DDR/READY、零 RXDBG
  与 TX-drain，按 `? -> p -> d -> Z` 节奏发送，`d` 只接受 event count=3/last byte=0x64，
  最终只接受 RXDBG=4/0x5A，并保留 RXPATH/RXCPU 全门；
- `run_board_once.sh`：TaskId、TaskRoot、本地输出、run label、bootstrap 路径和远端主机均为
  参数；sealed 后只有一次 candidate、一次 terminal（candidate 成功时）和一次 golden
  restore 路径；
- `seal_manifest.py`：生成 9 文件确定性 bytes/SHA256 manifest。

本地验证通过：`bash -n`、Python `py_compile`、manifest `jq`、consumer ID/root 静态审计、
PowerShell transport 禁止项审计和 `git diff --check`。最终 manifest SHA-256 为
`5f7d83702ccf745d1e16a29ec2eba10f40f0cd06c66cd7b28d02624fa9dc60a2`；逐文件数据见
[`T-20260920-034.json`](../tasks/evidence/T-20260920-034.json)。

## GamePC 结果

唯一允许的远端 root 与 bootstrap 初始 freshness 检查通过，且所有 SSH/SCP 均经由
`resource-lock run gamepc lcvex T-20260920-034 runner_t034 -- ...`。bootstrap 按要求
先 SCP 到 existing build parent，随后以 `pwsh.exe -File` 调用；但远端在 root 创建前
失败，错误来自本地首版第 29 行的 `Split-Path -LiteralPath $root -Parent` 参数集组合。
上传文件 SHA-256 为
`a83101c92a4afe9a67266f3afdd94b00bd9b900697e642294d7ed6d5a7db08e9`，远端回读确认原样
存在；root 仍 absent，bootstrap 未覆盖。

因此没有上传 sealed bundle，也没有执行 `validate_scripts.ps1`、`verify_seal.ps1`、
`preflight.ps1`、`program_once.ps1`、`postflight.ps1` 或 terminal。candidate/golden
programmer、JTAG、nios2-terminal、server 操作计数均为 0。错误后的额外诊断调用仍只
运行同一个 bootstrap，未写 root、未覆盖 bootstrap、未触碰硬件；完整日志和 SHA 记录在
evidence JSON 中。

本地已将 `prepare_task_root.ps1` 修正为 `Split-Path -Path $root -Parent`，但按任务合同
不能把修正版替换到已存在的远端 bootstrap，因此本任务必须 blocked。后续新任务应从
 fresh bootstrap/root 开始，先复用修正版完成远端 AST/hash，再单独申请板测窗口。

最终本地修正版 SHA-256 为
`2d81bf5a529106f7660676f941e973c855139d5efb231550c42469359fccd104`；失败的远端
bootstrap SHA-256 为
`a83101c92a4afe9a67266f3afdd94b00bd9b900697e642294d7ed6d5a7db08e9`，两者不可混用。
root 保持 absent，硬件调用保持 0；bootstrap 失败后没有远端重试、替换上传或硬件动作。
