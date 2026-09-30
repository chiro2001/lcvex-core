# F1F cache-off 修复后完整 Gate D

> 任务：`T-20260901-008`  
> 冻结 SHA：`4cf213769262d1a565577ac22229bf39ee89f3c4`  
> 结论：**PASS，标准完整串行 Gate D 全绿**。

## 执行

在全新 detached worktree `/home/chiro/projects/mycpu/lcvex-wt-T-20260901-008-gate`
运行：

```sh
systemd-run --user --scope \
  --unit=lcvex-t20260901-008-gate-d-serial \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% -- \
  env MAKEFLAGS=-j1 VERILATOR_JOBS=1 \
  bash -lc 'bash sim/difftest/run_gate_d.sh'
```

脚本单次完整执行 exit 0，最终输出：

```text
PASS: Gate D 系统回归全部通过
```

日志共有 151 个 `OK(green)`，没有 `FAIL(red-expected)` 或 `RED:`。通过范围包括：

- `make test` 与 coverage；T-005 的 cache-off dotted-reference 首因没有复现；
- M2/R1 base + 全缓存定向锁步；
- delay2-cache 定向与 3000 条随机 smoke；
- P5a hardening、Gate C、P5a MMU、P4b；
- 随机 seeds 1、2、3 各 100,002 条，合计 300,006 条；
- 指令覆盖期望集 62/62，observed families 63；
- baremetal-C 构建与 200 条锁步。

QEMU 为 11.1.0，本地 fork `84f07211cc5b4fc6a371559bf8a5de4fb068e648`；
Verilator 为 5.050。随机 trace/result hashes 见任务 evidence。

## 资源与 artifact

- scope：`lcvex-t20260901-008-gate-d-serial.scope`
- start/finish：`2026-09-01T09:43:27+08:00` / `2026-09-01T11:03:10+08:00`
- wall：4783.626 秒；CPU：2391.767 秒；memory peak：6GB
- MemoryMax=15G，MemorySwapMax=0，CPUQuota=50%，`MAKEFLAGS=-j1`，`VERILATOR_JOBS=1`
- 日志：`/home/chiro/projects/mycpu/lcvex-artifacts/T-20260901-008/gate_d_serial.log`
- 日志 bytes/lines：341054 / 1973
- 日志 SHA256：`b4a418e2854afc6ff6b52893a893d50843a9f0e7ca2844c32f1d8a15ed09ec1a`

scope 已退出，detached worktree tracked 状态干净。未运行 Linux、CI、Quartus 或板测。
标准 Gate D 使用默认 F0；它不解除 F1a 的三个 delay2 性能护栏失败，也不等于
F1a-on 性能签核。
