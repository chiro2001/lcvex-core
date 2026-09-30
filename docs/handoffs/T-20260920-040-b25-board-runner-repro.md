# T-20260920-040：tracked B25 board runner 与 SOP

```text
task=T-20260920-040
state=review
base=763622496991b5cd7c743c5ff05b9678b763483c
head=902c6b51c449651e86e84b6523805c5b903c671b
branch=infra/T-20260920-040-b25-board-runner-repro
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-040
sent_at=2026-09-20T21:42:29+08:00
received_at=2026-09-20T21:42:29+08:00
reported_at=2026-09-20T22:07:17+08:00
```

## 结果

T-036 的九个 sealed 脚本先逐文件 `cmp` 与 SHA-256 核对后迁入
`fpga/catapult_a10/tools/board_runner/`，随后改为受 Git 管理的参数化 runner。
candidate/golden、Quartus/source-server 路径、server pin、电缆、terminal 步骤和
安全策略不再硬编码在执行脚本中，而由每任务 `board-contract.json` 提供。contract
经过 fail-closed Python 校验，并与 11 个 runner 文件共同进入 schema-v2 seal。

`direct_terminal.py` 现在执行 contract 定义的有序 startup、单字节步骤、响应和
postcondition。允许多次状态轮询时，每次发送都必须收到响应，且只有独立
`accept_regex` 未满足时才发送下一次；超时不会静默重发。wrapper 从封存的
`program-result.json` 读取 programmer count，修复了 T-038 暴露的 stdout 计数误判。
terminal→golden quiescence 为 contract 限定的 0–60 秒等待，不是 retry。

SOP 已更新为实际 T-037/T-038 路径，并正式记录 cached standard-server design hash、
PowerShell ref/binder、single-use marker、owned PID 和 exact golden 联合证明规则。

## 验证

- `make b25-board-runner-check`：19/19 PASS；包括格式/身份/安全策略、路径与 host
  注入、server path traversal、terminal plan 和“无效 contract 到不了 fake ssh/scp”。
- `make test-registry-check`：89 项与 Makefile/runner 一致性 PASS。
- `bash -n`、Python compile、JSON、`git diff --check` 全部 PASS。
- 最终 fresh r3 GamePC no-hardware window：PowerShell AST 7/7、parse failure 0；
  seal 12/12 bytes/SHA 全匹配，wrapper exit 0。

前两个 no-hardware 窗口也保留：首窗 AST/seal 实际 PASS，但 CRLF exact-grep 使本地
wrapper exit 1；r2 PASS 后又因 fail-closed 校验加固而被 r3 字节取代。三窗都只执行
fresh root/bootstrap、上传、AST 和 seal；preflight、process query、Quartus、JTAG、
programmer、terminal、配置、Flash/reset/power/process-stop 全部为 0。

完整结构化事实和 artifact SHA 见
[`T-20260920-040.json`](../tasks/evidence/T-20260920-040.json)。下一步由集成者合入，
再为 T-041 生成 exact contract；新 runner 的第一条 live 路径不得在审阅前执行。
