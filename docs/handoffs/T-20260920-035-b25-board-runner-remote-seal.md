# T-20260920-035：B25 board runner remote seal

```text
task=T-20260920-035
state=blocked
base=5609f1518a22a7ceae5ebcc3fc314931410ab82f
branch=infra/T-20260920-035-b25-board-runner-remote-seal
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-035
sent_at=2026-09-20T19:21:18+08:00
reported_at=2026-09-20T19:30:20+08:00
```

## 本地 bundle

已逐文件核对 T-034 evidence manifest（manifest SHA-256
`5f7d83702ccf745d1e16a29ec2eba10f40f0cd06c66cd7b28d02624fa9dc60a2`）后复制到：

`build/agents/T-20260920-035/tools/`

只实施了两处 reviewed diff：

```diff
-$parent = Split-Path -Path $root -Parent
+$parent = [System.IO.Path]::GetDirectoryName($root)
+if ([string]::IsNullOrWhiteSpace($parent)) {
+    throw ('task root parent is empty: ' + $root)
+}
```

以及 `run_board_once.sh` 在记录 `PREFLIGHT_STATUS` 后立即 fail-closed：

```diff
 printf 'PREFLIGHT_STATUS=%s\n' "${preflight_status}" >>"${summary}"
+if [[ ${preflight_status} -ne 0 ]]; then
+  printf '%s\n' 'FLOW=BLOCKED_PREFLIGHT_NO_HARDWARE' >>"${summary}"
+  exit 2
+fi
```

其余七个源文件保持 byte-identical。T-035 manifest SHA-256 为
`40b9c0b4bad3c2979d36694e547c4831411886299d350511ee2a6bdd3a988e48`，逐文件必须
byte-for-byte 复制的数据如下：

| 文件 | bytes | SHA-256 |
|---|---:|---|
| `prepare_task_root.ps1` | 1866 | `9e292639a9430760752caa4d247c5d8a8e482452ff8f2ec6af13e5353b0a866d` |
| `validate_scripts.ps1` | 2496 | `91a7f57279f0f2b9cf62ae2350850a7314ac9c7aa401f45c165bacfe29dfc5d8` |
| `verify_seal.ps1` | 2909 | `cb9bb5e85b2e8675c2d700a3474848b7a1333730a2d9b81eb5cfc87662556ef9` |
| `preflight.ps1` | 4120 | `29f46fca907c56288ebb7cd0a99a57750f3e0c7e452b940f76e36f1ace5aad31` |
| `program_once.ps1` | 16007 | `d0a888b39bc255573290fe4c1d49fe7b9a48abedc6043b29332b94878a38978e` |
| `postflight.ps1` | 4558 | `3bad7a13a6e3765982b16247602a814dac45d9dc6b34ddc9ca605d8941f540f8` |
| `direct_terminal.py` | 16101 | `059bb54fa1f1d3c01209ead636ca5cfcc536d2e4b4a2d41819a3d18f9a4a2e66` |
| `run_board_once.sh` | 9819 | `f27bf274b062a67022ee3f974476b380f88c5700f45b37d45b3c2ba59fd6b018` |
| `seal_manifest.py` | 1886 | `e95f87a2e91b73202edca05b9b441ad6def328c9c061e86cb111dd5ebf7c2cde` |

本地 `bash -n`、`py_compile`、manifest `jq`、consumer ID/root、inline PowerShell
禁项和 single-use control-flow 审计均通过。远端 validation wrapper 是
`build/agents/T-20260920-035/remote-validation-wrapper.sh`（SHA-256
`594438aae452b817dc865ac503a1f52f2076f3a1301f9538ae0dd9291802644f`），仅供本次
T-035 使用，不属于可复用 bundle。

## GamePC 结果

所有远端动作均在唯一窗口中执行：

`/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex T-20260920-035 runner_t035 -- bash build/agents/T-20260920-035/remote-validation-wrapper.sh`

顺序和结果为：

1. `cmd.exe` existence check 通过，指定 root/bootstrap 均 absent。
2. 修正版 `prepare_task_root.ps1` 一次 SCP 到
   `D:/Projects/fpga-altra/lcvex/build/T-20260920-035-prepare.ps1`，再以
   `pwsh.exe -File` 一次创建 root/incoming，返回 `PREPARE_ROOT_RESULT=PASS`。
3. sealed bundle+manifest 一次 SCP 成功。
4. `pwsh.exe -File incoming/validate_scripts.ps1` 返回失败：`Argument types do not match`。
5. wrapper 立即停止，`verify_seal.ps1` 未执行；没有 preflight、program_once、terminal、
   postflight、jtagconfig、quartus_pgm、nios2-terminal、jtagserver 或 process query。

远端 root/bootstrap 已创建并保留，未删除、覆盖、替换或重试。AST 失败后没有再做远端探测；
seal 未执行。hardware、JTAG、programmer、terminal、process query 均为 0，且 remote
retry=false。
本地 AST 日志在 `build/agents/T-20260920-035/remote-seal/remote-ast.log`；seal 日志
不存在，因为 seal 未开始。完整 evidence 见
[`T-20260920-035.json`](../tasks/evidence/T-20260920-035.json)。

## Handoff 边界

后续任务若要复用脚本，必须从上述 `tools/` 和 `script-manifest.json` 按 SHA-256
byte-for-byte 复制；本地 manifest 生成后脚本不得再编辑。不得复用或修改本次远端
root/bootstrap；应在新任务中先解决远端 PowerShell `Parser::ParseFile` 的
`Argument types do not match` 兼容性问题，并重新取得授权后再做 AST/seal。硬件、
programmer、terminal、JTAG 和 process 计数均为 0。
