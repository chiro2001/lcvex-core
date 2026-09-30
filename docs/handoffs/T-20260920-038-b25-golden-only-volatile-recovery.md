# T-20260920-038：B25 golden-only volatile recovery

```text
task=T-20260920-038
state=review
base=2e18aa0224ad01388bf624c9476e4a2bf11c95fa
evidence_parent_sha=c8a7d8d80aad3d8d8b5e5742fb5a2fa0e0288762
head=<commit SHA reported after commit>
branch=verify/T-20260920-038-b25-golden-only-volatile-recovery
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-038
sent_at=2026-09-20T20:18:31+08:00
received_at=2026-09-20T20:18:31+08:00
reported_at=2026-09-20T20:31:25+08:00
```

## 结果

T-036 的 9 个 sealed 工具已逐文件 SHA-256 和 `cmp` 核对后复制到
`build/agents/T-20260920-038/tools/`，内容未修改。源 manifest SHA-256 为
`2972d24292de061ed06e98aa68ce3f4443ca041caa3cba1bca632e223542dfcc`；T-038
manifest 由原 `seal_manifest.py` 生成，SHA-256 为
`40ed4f8fbff7b8ec0a97f4367edee8c2d9ea3073e68132b69ffd387d6b2fdee8`。

唯一的持锁命令是：

```text
/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex T-20260920-038 golden_t038 -- bash build/agents/T-20260920-038/run_golden_recovery_once.sh
```

freshness、bootstrap、一次 bundle 上传、AST 6/6 和 seal 9/9 均通过。没有执行
reusable `run_board_once.sh`、`preflight.ps1`、`postflight.ps1` 或
`direct_terminal.py`。

golden `program_once.ps1` 仅调用一次，参数为 `-Mode golden -RunLabel recovery`。
其结果为 `PASS` / `VOLATILE_PROGRAM_PASS`：

- frozen golden SOF：36844906 bytes，SHA-256
  `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`；
  checksum `0x31510BB6`，design `193DE4BC8A30F3ED5F1F`。
- Quartus programmer exit 0，configuration/operation/checksum/JTAG-ID 全部
  PASS，stdout 明确报告 `0 errors, 0 warnings`；sealed
  `program-result.json` 的 `golden_quartus_pgm_invocation_count=1`、PID=18828。
- durable golden marker 恰好 1 个，内容为 `T-20260920-038|golden|recovery`；
  candidate marker、candidate programmer 和 terminal 均为 0。
- owned server PID 56352 已清理；preserved standard server PID 5640，post
  busy=0、port1310=0。

program 成功后直接执行一次标准
`D:\Software\intelFPGA_pro\21.4\quartus\bin64\jtagconfig.exe -n`，exit 0；输出
同时包含指定 cable、JTAG ID `0x02E060DD`、golden design hash、`JTAG UART #0`
和 `JTAG PHY #0`。因此 successful golden programmer transaction 与 final
standard-chain enumeration 联合证明 live golden。

## 边界与注意事项

没有 JIC/EPCQ/Flash、reset、power、standard/unknown process stop，也没有
GamePC 资源锁窗口结束后的远端访问。wrapper 最终 exit 1 是一次性 wrapper 的
stdout 计数 bookkeeping 缺陷：PowerShell `program_once.ps1` 将函数内的
`PROGRAMMER_PID` 输出收集进返回对象，所以 SSH stdout 没有该行；这不影响真实
结果。以 sealed `program-result.json`（programmer count=1、PASS）及
`quartus_pgm.stdout.log` 为准；没有因此进行任何重试。

完整结构化证据见
[`T-20260920-038.json`](../tasks/evidence/T-20260920-038.json)。运行产物留在
ignored 的 `build/agents/T-20260920-038/run/`，包含 marker、program result、
programmer stdout/stderr、server manifest、最终 chain 和 resource 状态。

后续仅需审阅并合并本 evidence/handoff；禁止再次访问 GamePC 或重跑任何编程、
terminal、reset、power、Flash 路径。
