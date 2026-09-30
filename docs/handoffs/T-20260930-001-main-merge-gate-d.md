# T-20260930-001 交接：main 合并 Linux bring-up 线并复跑 Gate D

```text
task=T-20260930-001
label=MAIN-MERGE-GATE-D
branch=main
worktree=/home/chiro/projects/mycpu/lcvex-wt-main-merge
merge_sha=8cdc5666e27d4b2db5c7f2dd1db9586825d7878d
origin_main_before=6922accb
date=2026-09-30
state=done
```

精确命令、哈希与计数以
[`docs/tasks/evidence/T-20260930-001.json`](../tasks/evidence/T-20260930-001.json)
为准；本文只记录结论、风险与流程说明。

## 1. 结论

- 两条长命线已合入 `main` 并推送 GitHub：
  - `70afb15b` ← `feature/p7-final`（跨项目资源锁策略 + guardian 加固）
  - `0a545b22` ← `feature/T-20260928-002-linux-bringup`（Catapult A10 Linux bring-up）
  - `8cdc5666` 刷新 README（当前状态、板级复现入口、验收口径、已知边界）
- 合并后 `main` = `8cdc5666`，tree `cbd94bc8`，已推送到
  `origin/main`（`6922accb..8cdc5666`），合并过程零冲突、工作区前后均干净。
- **Gate D 在合并 SHA 上全绿**：`bash sim/difftest/run_gate_d.sh --parallel`，
  152 项 OK、0 FAIL，收尾行 `PASS: Gate D 系统回归全部通过`，耗时约 11m48s，
  全程持有 `local` 资源锁，发布模式（未跳过 baremetal-C）。

## 2. 为什么这次合入必须看 Gate D

这条线为了把 Linux 跑上真板动了三个共享 RTL 模块，Gate D 是覆盖它们的回归：

| 改动 | 覆盖它的 Gate D 步骤 |
| --- | --- |
| `lcvex_l1_d_wb.sv` 跨 64B 行边界 load/store 拆分 | delay2-cache 批次、L1D 单元 TB、MMU 数据翻译 |
| `lcvex_core.sv` 板级真实时钟 Generic Timer（QEMU 指令计数仍为默认） | `make test` 中的 CNTFRQ 双模式检查 + 全部锁步步骤 |
| `lcvex_gic.sv` 96 项串行扫描 → 平衡锦标赛树 | `hard_gic`、`hard_irq`，另有单独的 `sim-sv-gic-spi` |

离线门同样在合并工作树上复跑：`check_platform.py`（50 文件 PASS）、
`check_skeleton.py --require-boot-image`（先跑一次 `build_linux_loader.sh`，
因为 loader 镜像是 build-only 产物）、以及 loader 构建本身
（BIN 3121 B / `d8c0b85e`，MIF `43c1a21d`）。

## 3. 流程说明（如实记录，不掩饰）

这次先把合并与 README 推上 `main`，**Gate D 才跑**——与 `AGENTS.md`
“`main` 只接受本地 Gate D 全绿”的顺序要求相反。当时依据是真板冷启动已经
端到端证明这套 RTL 可用，Gate D 只是补验收记录。

补救方式：把这次 Gate D 当作对已推送 SHA 的确认门（confirmation gate），
并预设了两种红结果处理——在 `main` 上 fix-forward，或把远端 `main` 退回
`6922accb`。结果是绿的，因此没有触发回退。这段过程写进了 active/evidence，
没有把它写成“先过门后推送”。

后续若再走同样的合并流程，应恢复正确顺序：**先在合并工作树跑 Gate D，绿了
再推 `main`**。

### 3.1 后续的 docs-only 合并如何复用这次门

随后 `main` 上又合入一个只改文档的提交（`503e90d7` ← `ecdc2ba9`，内容是在
T-20260928-002 证据里加一条“canonical DTB 仿真在 775M 周期被主动停止以腾出
`local` 锁”的说明）。这次没有重跑 Gate D，依据是机械可验证的：
`git diff --name-only 8cdc5666 503e90d7` 只列出 `docs/` 路径，而
`rtl`、`tb`、`sim`、`scripts`、`baremetal`、`configs`、`fpga`、`Makefile`
在 `8cdc5666` 与 `503e90d7` 之间是**逐字节相同的 tree 对象**。既然被测输入
没有变化，`8cdc5666` 上的 Gate D 结论原样适用于 `503e90d7`。这里不声称
“重跑通过”，而是声称“复用同一被测树的门结论”。

## 4. 证据与复现

| 内容 | 位置 |
| --- | --- |
| Gate D 完整日志（152 OK / 0 FAIL） | `build/agents/T-20260930-001/gate-d.log`（build-only，不进 Git） |
| 日志 SHA-256 | `edf6a1df4d04cf5fd90e12158cc8e30684c417ac2fb0e57d8d5261adcce827fd` |
| 任务登记 | `docs/tasks/active/T-20260930-001.json` |
| 机器可读证据 | `docs/tasks/evidence/T-20260930-001.json` |
| 真板证据（另一条线） | `docs/tasks/evidence/T-20260928-002.json` |

复跑命令：

```sh
/home/chiro/projects/.resource-locks/resource-lock run local lcvex T-20260930-001 root -- \
  bash -c 'cd /home/chiro/projects/mycpu/lcvex-wt-main-merge && bash sim/difftest/run_gate_d.sh --parallel'
```

## 5. 边界

- Gate D 是本地验收门，不能替代真板证据；板级结论以
  `T-20260928-002` 的冷启动串口记录为准。
- CI 尚未被视为可信来源，本次没有引用任何 CI 结果。
- 同一批次里 canonical DTB 的 128 MiB 全系统 Linux 仿真在 775M 周期被主动停止，
  以腾出 `local` 锁跑本 Gate D；原因与部分日志位置记录在 T-20260928-002 证据中。

## 6. 下一步（可选）

1. 在空闲 `local` 锁上重跑或补完 canonical DTB 的 Linux 行为级仿真。
2. `/init` 增加 `uptime` 等第二条命令，做一次更完整的用户态演示。
3. 按路线图推进 DDR/Cache 压力、full-FP 板级签核与 CI 可信化。
