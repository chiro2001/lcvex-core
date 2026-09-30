# 05 验证方法学

> 状态：**单核 F 候选已有完整本地 Gate D 全绿记录；checkpoint v4 联合恢复已通过；
> 多核真实差分、可信 CI/main 晋级、Quartus/板测等尚待验证。**
> 依据：`docs/VERIFICATION.md`、`docs/DIFFTEST.md`、`docs/COMMIT_PACKET.md`、
> `docs/TEST_ENHANCEMENT_PLAN.md`、T-097/T-099/T-20260829-117/T-20260830-022
> evidence/handoff。

## 1. 测试层级

| 层 | 内容 | 当前覆盖 |
| --- | --- | --- |
| L0 | microbench / 快速 Verilator-only 行为 | 有 Makefile/脚本，用于裸机 C |
| L1 | SV TB / Cocotb / SVA / lint | 大量单元、Cache、MMU、外设、FP/NEON、多核模块级定向 |
| L2 | hard_* 定向 QEMU 锁步差分 | 标量/异常/MMU/Cache/FP/NEON/A76 矩阵/P6 |
| L3 | 完整 Gate D + 覆盖记账 | T-099 在 `3dcffe0` PASS；T-20260830-022 在功能 RTL 基线 `a110ba3` 再 PASS 13/13 |
| L4 | 多 seed/长 Linux/nightly/Quartus/板测 | 部分：Linux lite 35M 历史证据；可信 CI/nightly/板测后置 |

## 2. 定向 / 随机 / 覆盖率

- **定向**：覆盖整数 ALU、分支、访存、exclusive/LSE、异常、MMU、Cache、
  barrier/maintenance、FP/NEON raw-bit、多核 message-passing/CAS/barrier 等。
- **随机**：Gate D 中 seed 1–3 × 100,000 条提交与 QEMU 全一致；B4 随机覆盖
  报告 `expected_hit=62/62`、`observed_families=63`（T-098 引用）；历史口
  径也有 60/60。
- **覆盖率**：`make coverage` 合并 L1D/L1I/L2/MMU/MEMIF SV TB 的
  Verilator coverage 到 `build/coverage/merged.dat`。覆盖率仅针对已列 TB 的
  行/翻转/分支，不是 RTL 全模块或 ISA 全量覆盖。
- **Baremetal-C**：Gate D 中 200 条裸机 C 与 QEMU 一致；另有 microbench 运行器。

## 3. Gate D 13/13

当前最新本地 Gate D 证据为 T-20260830-022：在功能 RTL 基线
`a110ba3aeea212834edd86949845bd07eda99aba` 上完成
`make test`、`bash sim/difftest/run_gate_d.sh --parallel` 和
`CORE_COUNT=1`/`l2_cluster` lint，全部 PASS，最终
`PASS: Gate D 系统回归全部通过`。此前 T-20260829-099 在 F 单核候选
`3dcffe0e6ddd7946c0bf560ca36778c6a1531f28` 的 detached worktree 也完成过
同一全量回归。13 个顶层 step 全 PASS：

1. `make test`
2. `make coverage`
3. M2-4b/4c 定向锁步（base + 全缓存，40/40）
4. lockstep-build-l1dl2-delay2
5. 随机 smoke 镜像重新生成
6. delay2-cache-*（32 项并行）
7. P5a-Hardening + M2 定向（26 项并行）
8. Gate C 异常/EL0-EL1（7 组）
9. P5a MMU 数据翻译（3 组）
10. P4b 异常/系统指令（5 组）
11. 随机 seed 1–3 × 100k
12. 指令覆盖记账
13. baremetal-C 200 条锁步

注意：这是**本地 Gate D 证据**，不等于可信 CI、Gate E/F 或 `main` 晋级。

## 4. Checkpoint v4

- T-20260829-097 把系统 sidecar 从 v3（540B）升级到 v4（548B，magic
  `LCVXSYS4`），新增 `CONTEXTIDR_EL1` 字段；同步更新 QEMU fork、
  `checkpoint.py`、`lockstep_coordinator.cc`、RTL 恢复端口和测试程序。
- 已通过：`make compile`、QEMU fork rebuild、v4 struct smoke、manifest smoke、
  resume manifest smoke。代码已进入 `feature/p7-final` 历史。
- **已完成（AUD-12，T-20260829-117）**：完整 `checkpoint_sys_v4` QEMU/DUT
  联合恢复已在功能基线上通过。使用非零 `CONTEXTIDR_EL1=0x56781234` 保存
  `LCVXSYS4` sidecar，经 QEMU `-incoming` + DUT `--restore-sys` 恢复后继续
  锁步 4 条指令，MRS 读回完全一致；配套 v2/v3 兼容、timer/GIC/MMIO/manifest/
  resume/manifest smoke 全部 PASS。
- 剩余边界：AUD-12 是定向联合恢复 smoke，不是 Gate D、Linux 长跑或全量
  系统寄存器矩阵；未做全 64 位随机/边界 CONTEXTIDR 矩阵。
- 旧 v1/v2/v3 sidecar 仍可读，v4 缺失字段回退 0。

## 5. 负向测试与失败保存

- 负向覆盖：UDEF/保留编码、EL0 越权、fault/abort、atomic STXR 失败、
  FP raw-bit/NaN/signed-zero、Cache writeback fault、reset stale-response 等。
- 失败保存：`COMMIT_PACKET.md` 要求保存指令编码/反汇编、执行前状态、RTL
  提交包、QEMU 状态、最近提交；`DIFFTEST.md` 和任务 evidence 记录失败现场
  保留/重现要求。
- 失败现场大产物（RAM/trace/checkpoint）不进 Git，记录 URI/SHA/retention。
- 未做：全量变异测试、形式化 property 全覆盖、完整多核 litmus。

## 6. CI 现状

- `.github/workflows/ci.yml` 分 `pr-fast`（无 QEMU）、`pr-difftest`（QEMU 锁步）、
  `nightly`（长回归 + 延迟注入 + patch 重放）。
- **GitHub Actions 自动触发已禁用（T-20260830-007）**：push/PR/schedule 不再
  自动运行，仅保留人工 `workflow_dispatch`；本地 CI 脚本和 `run_gate_d.sh`
  不受影响。
- 项目策略：CI 未完全可信前，以本地 Gate D 为准；`main` 只接受本地 Gate D
  全绿 + CI 通过（当前 `main` 晋级仍后置）。
- 未在 CI 中看到完整 Gate D/Linux/Quartus/板测，属于已知限制。

## 7. 建议审计问题

- Gate D 的 13/13 是否与当前 head SHA 一致？是否需要在新 head 重跑？
- checkpoint v4 是否已有完整 QEMU/DUT 联合恢复证据？
- 覆盖率是否覆盖 FP/NEON、AXI4、写回 Cache、CDC、多核目录？
- 失败保存路径和 artifact retention 是否足够外部复现？
