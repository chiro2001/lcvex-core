# T-20260920-036：B25 board runner AST compatibility seal

```text
task=T-20260920-036
state=review
base=f75b42f8b5aa2de606af7b28d198ec295ae329c5
branch=infra/T-20260920-036-b25-board-runner-ast-compat-seal
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-036
sent_at=2026-09-20T19:34:40+08:00
received_at=2026-09-20T19:34:40+08:00
reported_at=2026-09-20T19:44:26+08:00
```

## 结果

T-035 bundle 已逐文件 hash 核对后复制到
`build/agents/T-20260920-036/tools/`。仅修改了
`validate_scripts.ps1` 和 `verify_seal.ps1`：前者使用显式
`Token[]`/`ParseError[]` 的 `Parser::ParseFile` 引用参数，两个脚本均使用普通
PowerShell 数组和 `+=`，结果直接序列化数组；seal 语义未改变。其余七个文件
保持 byte-identical。

T-036 manifest SHA-256 为
`2972d24292de061ed06e98aa68ce3f4443ca041caa3cba1bca632e223542dfcc`。七个未改文件
的源/最终 hash 与逐文件最终 hash 已冻结在
[`T-20260920-036.json`](../tasks/evidence/T-20260920-036.json)。

## 本地验证

- `bash -n`：wrapper 与 `run_board_once.sh` 通过。
- `python3 -m py_compile`：`direct_terminal.py`、`seal_manifest.py` 通过。
- manifest `jq` schema/consumer/root、PowerShell transport、binder 和
  single-use/preflight gate 审计通过。
- `git diff --check` 通过。

## Fresh GamePC 验证

唯一远端窗口命令为：

```text
/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex T-20260920-036 runner_t036 -- bash build/agents/T-20260920-036/remote-validation-wrapper.sh
```

wrapper 首先检查并确认指定 root/bootstrap 均 absent，然后一次上传 bootstrap 并以
`pwsh.exe -File` 创建 root/incoming；随后一次上传 sealed bundle。AST 返回
`REMOTE_AST_RESULT=PASS`，六个 PowerShell 文件的 `parse_error_count` 全为 0；仅在
AST PASS 后执行 `verify_seal.ps1`，返回 `REMOTE_SCRIPT_SEAL_RESULT=PASS`，九个文件
的 bytes 与 SHA-256 全部 match。root/bootstrap 均保留，未删除、覆盖、替换或重试。

完整日志在 `build/agents/T-20260920-036/remote-seal/`，hash 和远端结果见 evidence。

## 边界与 handoff

全程只做 filesystem、PowerShell AST、manifest 和 SHA 操作；没有执行
`preflight.ps1`、`program_once.ps1`、`postflight.ps1`、`direct_terminal.py` 或
`run_board_once.sh`，也没有执行 `jtagconfig`、`quartus_pgm`、`nios2-terminal`、
`jtagserver`、process query、FPGA/JTAG/Flash/reset/power 操作。硬件、JTAG、
programmer、terminal、process enumeration/query/termination、FPGA configuration、
Flash、reset/power 计数均为 0。

后续集成仅需审阅本 handoff/evidence 并合并；不得替换或重跑已 sealed 的 T-036
远端 root/bootstrap 或 bundle。
