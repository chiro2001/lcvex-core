# T-20260902-006 F1a 默认-on 完整 Gate D handoff

```text
task=T-20260902-006
state=blocked
base=335d75a4c6a49760fe55b0b744477456b26a5847
head=85101d2bfc009e933025251a075a9a7193904da3
branch=verify/T-20260902-006-f1a-default-on-gated
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-006
sent_at=2026-09-02T13:05:00+08:00
received_at=2026-09-02T13:05:35+08:00
reported_at=2026-09-02T14:45:40+08:00
```

## 结论

**BLOCKED**：在当前默认 FETCH_FIFO_ENABLE=1 的合并 SHA 上，完整本地串行 Gate D
复跑返回退出码 1。`make test`、coverage、P5a-Hardening、Gate C、P5a MMU、P4b、
随机 seed 1~3 × 100k、覆盖记账和 baremetal-C 均通过；但 F1a-on 在 M2-4b/4c
与 delay2 cache 定向锁步中暴露出 9 个失败用例，涉及 3 个顶层 Gate D step。

默认-on 参数确认：

- `tb/sv/lcvex_soc_tb.sv`: `parameter int FETCH_FIFO_ENABLE = 1`
- `rtl/lcvex_core_wrap.sv`: `parameter int FETCH_FIFO_ENABLE = 1`
- `Makefile`: `PERF_FETCH_FIFO_ENABLE ?= 1`
- `rtl/lcvex_cluster_top.sv` / SoC/FPGA 顶层也已透传 `FETCH_FIFO_ENABLE=1`

## 执行

在独立 worktree 上运行单次完整串行 Gate D（未使用 `--parallel`），资源符合
`MemoryMax=15G`、`MemorySwapMax=0`、`CPUQuota=50%`、`MAKEFLAGS=-j1`、
`VERILATOR_JOBS=1`，一次只跑一个重型任务。

命令（systemd transient service 保持与 shell 解耦）：

```bash
systemd-run --user --unit=lcvex-t20260902-006-gate-d-serial \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% \
  -p MemoryAccounting=yes \
  -p 'Environment=PATH=/home/chiro/miniforge3/bin:/home/chiro/miniforge3/condabin:/usr/local/bin:/usr/bin:/bin' \
  -- build/run_gate_d_wrapper.sh
# wrapper 内：env MAKEFLAGS=-j1 VERILATOR_JOBS=1 bash sim/difftest/run_gate_d.sh
```

结果：

- exit code：`1`
- wall：`4953.450 s`（82.6 min）
- CPU：约 `2475.737 s`
- memory peak：`6,633,861,120 B`（~6.18 GiB，<15G，无 swap）
- 日志：`build/logs/gate_d_serial.log`
- 日志 SHA256：`2307ff581b21e3ae890b19907e21de3b6c63b649528086284b0029ad73971231`
- 日志 bytes/lines：`392569 / 2837`
- `OK(green)` 行：`141`
- `FAIL(red-expected)` 行：`10`（9 个具体锁步用例 + 1 个 M2 顶层 step）

## Gate D 明细

| Step | 结果 |
| --- | --- |
| `make test（单元 + SVA）` | OK |
| `make coverage（缓存/MMU TB 覆盖率）` | OK |
| `M2-4b/4c 定向锁步（base + 全缓存）` | **FAIL（7 个具体用例）** |
| `lockstep-build-l1dl2-delay2 构建` | OK |
| `随机 smoke 镜像重新生成` | OK |
| `delay2-cache-*` | **FAIL：hard_timer、hard_postpre；其余全绿** |
| `P5a-Hardening + M2 定向（13 组）` | OK |
| `Gate C 异常/EL0-EL1（7 组）` | OK |
| `P5a MMU 数据翻译（3 组）` | OK |
| `P4b 异常/系统指令` | OK |
| `随机回归（seed 1~3 × 100k）` | OK（300,006 条） |
| `指令覆盖记账` | OK（expected 62/62，observed 63） |
| `baremetal-C 工具链/镜像` | OK |
| `baremetal-C 锁步` | OK（200 条） |

## 失败用例（F1a-on 定向锁步）

全部在默认-on F1a 路径下复现，且已有 F0 Gate D 基线（T-20260901-008，
同一组测试 151 项全绿）未出现这些失败。

| 配置 | 用例 | 失败摘要 |
| --- | --- | --- |
| base | hard_timer | `CNTVCT` 第 2 条读取 RTL=1，QEMU=2（timer/RNDR 计数 off-by-one） |
| base | hard_adc_sbc | `ngc x4,xzr` 在 C=1 时 RTL 得到 -1，QEMU 得到 0（进位/标志未正确前递） |
| base | hard_sve_probe | `RNDR` 读取 RTL=0x2b，QEMU=0x2c（timer 计数 off-by-one） |
| cache | hard_timer | 同 base hard_timer |
| cache | hard_postpre | post-index `ldrb` 数据/基址写回均错：RTL x4=0xbb 且 x20 少 1 |
| cache | hard_adc_sbc | 同 base hard_adc_sbc |
| cache | hard_sve_probe | 同 base hard_sve_probe |
| delay2 | hard_timer | 同 base hard_timer |
| delay2 | hard_postpre | 同 cache hard_postpre |

失败现场已按用例保存在：

- `build/logs/fail_dumps/<case>.fail.txt`
- `build/logs/fail_dumps/<case>.coord.log`
- `build/logs/fail_dumps/<case>.qemu.log`
- `build/logs/fail_dumps/<case>.out`

## CORE_COUNT=1 / l2_cluster lint

Gate D 脚本不包含这两项，另行执行，结果均 PASS：

| 命令要点 | 结果 | wall | 日志 |
| --- | --- | --- | --- |
| `verilator --lint-only --no-assert --no-timing -Wall -Wno-fatal -Wno-UNUSEDPARAM --top-module lcvex_cluster_top -GCORE_COUNT=1 -f rtl/filelist.f rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv` | PASS | 26.067s | `build/logs/core_count_1_cluster_lint.log` |
| `verilator --lint-only --no-assert --no-timing -Wall -Wno-fatal -Wno-UNUSEDPARAM --top-module lcvex_l2_cluster -GCORE_COUNT=1 -GMEM_LINES=16 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv` | PASS | 0.793s | `build/logs/core_count_1_l2_cluster_lint.log` |

注：`lcvex_l2_cluster` 有既存 `%Warning-UNSIGNED`，非 fatal；cluster_top 有
既有 UNDRIVEN/UNUSEDSIGNAL warning，退出码 0。

## 证据

- 主任务 evidence：`docs/tasks/evidence/T-20260902-006.json`
- 完整 Gate D 日志：`build/logs/gate_d_serial.log`
- 随机 trace/result hashes 与 T-20260901-008 一致（seed 1/2/3 确定性）。
- 本任务未运行 Linux 长跑、CI、Quartus、FPGA 上板或性能矩阵。

## 风险与下一步

1. 当前默认-on F1a 不能通过 Gate D，应保持 `FETCH_FIFO_ENABLE` 默认关闭或
   先修复 F1a 锁步问题后再默认-on。
2. 建议下一步开独立 regression/fix 任务，优先定位三类首因：
   - F1a 下系统寄存器/timer/RNDR 计数 off-by-one；
   - F1a 下 ADC/SBC/NGC 进位标志前递；
   - F1a 下 post-index load/store 地址写回与数据语义。
3. 修复后需在同一合并 SHA 重跑完整串行 Gate D，再重新评估默认-on。
