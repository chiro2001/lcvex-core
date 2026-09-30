# 审计证据索引

> 用途：为 9 个审计方向提供仓库内的证据文件、handoff、evidence JSON 和已知
> commit 的索引。所有路径相对仓库根。
> 说明：`commit` 列只列出在手稿/evid中明确出现的关键 SHA，不表示该方向全部
> 证据都来自该 commit；当前材料基线为 `5f78319234a603f522af407e5378b7ef786fa1d1`。

## 01-governance

| 证据 | 路径 | 说明 |
| --- | --- | --- |
| 工作流规范 | `docs/MULTI_AGENT_WORKFLOW.md` | 任务模型、subagent、资源、禁止事项 |
| Git 工作流 | `docs/GIT_WORKFLOW.md` | worktree、合并、QEMU patch |
| 子域/热点 | `docs/domains/README.md` | 文件所有权与串行热点 |
| ADR | `docs/decisions/ADR-20260826-001-multi-agent-control-plane.md` | 多 Agent 控制面 |
| ADR | `docs/decisions/ADR-20260826-002-agent-model-routing-v2.md` | 模型路由 |
| ADR | `docs/decisions/ADR-20260828-004-dsh-control-plane.md` | dsh 控制面 |
| ADR | `docs/decisions/ADR-20260829-005-v82-profile-parallel-lines.md` | profile/并行路线 |
| 任务登记 | `docs/tasks/active/T-20260829-104.json` | 本任务写集/验收 |
| 本任务 handoff | `docs/handoffs/T-20260829-104-external-audit.md` | 本材料包交接 |
| 本任务 evidence | `docs/tasks/evidence/T-20260829-104.json` | 本材料包证据 |

## 02-reproducibility

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| 工具链 | `docs/TOOLCHAIN.md`、`env/environment.yml` | 版本来源 |
| 版本检查 | `scripts/toolcheck.sh` | 自动核对 |
| Makefile | `Makefile` | 构建/测试入口 |
| RTL 文件清单 | `rtl/filelist.f` | SHA256 见 02 |
| QEMU 版本 | `qemu/VERSION` | 固定 release/commit |
| QEMU patches | `qemu/patches/*.patch` | 13 个可重放补丁 |
| QEMU apply | `qemu/scripts/apply-patches.sh` | 干净重放/幂等 |
| QEMU README | `qemu/README.cn.md` | 使用规则 |
| manifest/checkpoint | `scripts/trace_manifest.py`、`sim/difftest/checkpoint.py` | 精确工具 |
| T-098 evidence | `docs/tasks/evidence/T-20260829-098.json` | 工具/QEMU/plugin hash |
| T-099 evidence | `docs/tasks/evidence/T-20260829-099.json` | Gate D source/tool/产物 |

## 03-rtl-quality

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| RTL 源码 | `rtl/` | 全部设计 |
| 文件清单 | `rtl/filelist.f` | 顺序 |
| lint 入口 | `Makefile` (`compile`, `sim-*`) | `-Wno-fatal`/`-Wno-UNUSEDPARAM` 说明 |
| T-090 | `docs/handoffs/T-20260829-090-verilator-stuck-diagnose.md`、`docs/tasks/evidence/T-20260829-090.json` | Verilator 卡顿诊断 |
| T-091 | `docs/handoffs/T-20260829-091-fp-scalar-verilator-opt.md`、`docs/tasks/evidence/T-20260829-091.json` | FP scalar 优化 |
| T-101 | `docs/handoffs/T-20260829-101-t067-synth-opt.md`、`docs/tasks/evidence/T-20260829-101.json` | OOM/FP 参数/除法 |
| T-102 | `docs/handoffs/T-20260829-102-t067-module-synth.md`、`docs/tasks/evidence/T-20260829-102.json` | 模块热点/生成门控 |
| T-099 | `docs/handoffs/T-20260829-099-gate-d.md` | `make test`/Gate D |
| QEMU sidecar v4 | `docs/handoffs/T-20260829-097-checkpoint-sidecar-v4.md` | RTL 恢复端口改动/compile |

## 04-isa-architecture

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| Profile manifest | `docs/V82_PROFILE_MANIFEST.md` | 117 行机器可检查清单 |
| Profile 脚本 | `scripts/v82_profile_check.py` | 校验/生成 |
| ISA 范围 | `docs/ISA_SCOPE.md` | 标量/系统/MMU/MMIO/外设 |
| ISA 缺口 | `docs/ISA_GAPS.md` | 历史缺口与证据边界 |
| B0/B5 | `docs/tasks/evidence/T-20260829-075.json`、`T-20260829-098.json` | profile 审计/冻结 |
| B1/B2a/b/c | `docs/tasks/evidence/T-20260829-078.json`、`T-20260829-082.json`、`T-20260829-084.json`、`T-20260829-085.json` | 标量/FP/ASIMD/向量闭合 |
| B3 | `docs/tasks/evidence/T-20260829-088.json`、`T-20260829-093.json`、`T-20260829-096.json` | 系统/维护/原子/ContextIDR |
| QEMU lockstep | `docs/DIFFTEST.md`、`docs/COMMIT_PACKET.md` | 协议与格式 |
| FP/NEON 协议 | `docs/P7_FP_NEON_PROTOCOL.md` | FP raw-bit/checkpoint |

## 05-verification

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| 验证计划 | `docs/VERIFICATION.md` | 层级/门 |
| 差分测试 | `docs/DIFFTEST.md` | P1/P2/checkpoint/失败 |
| 提交包 | `docs/COMMIT_PACKET.md` | commit/trace/失败必存 |
| 测试增强 | `docs/TEST_ENHANCEMENT_PLAN.md` | microbench/覆盖/registry |
| Gate D 13/13 | `docs/handoffs/T-20260829-099-gate-d.md`、`docs/tasks/evidence/T-20260829-099.json`（验证 SHA `3dcffe0e6ddd7946c0bf560ca36778c6a1531f28`） | 13 步 PASS |
| Checkpoint v4 | `docs/handoffs/T-20260829-097-checkpoint-sidecar-v4.md`、`docs/tasks/evidence/T-20260829-097.json` | sidecar v4/限制 |
| Baremetal/microbench | `scripts/build-microbench.sh`、`docs/TEST_ENHANCEMENT_PLAN.md` | 200 条 C |
| CI | `.github/workflows/ci.yml` | fast/difftest/nightly |
| 随机/覆盖 | `scripts/insn_coverage.py`、`Makefile` (`coverage`) | seed 和 coverage |

## 06-multicore

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| 集群契约 | `docs/MULTICORE_CLUSTER_CONTRACT.md` | C0 |
| 多核差分 | `docs/LCVX_DIFF_MC_V2.md` | D0 |
| C1/C2 实现 | `docs/tasks/evidence/T-20260829-079.json`、`T-20260829-086.json` | 双核壳层/MSI |
| C2 remainder | `docs/tasks/evidence/T-20260829-092.json`、`docs/handoffs/T-20260829-092-c2-remainder.md` | 原子/屏障/reset |
| C3 pre | `docs/C3_FOURCORE_PREWORK.md`、`docs/handoffs/T-20260829-089-c3-fourcore-prework.md`、`docs/tasks/evidence/T-20260829-089.json` | C3 前置 |
| C4 pre | `docs/C4_SCALE_PREWORK.md`、`docs/handoffs/T-20260829-100-c4-scale-prework.md`、`docs/tasks/evidence/T-20260829-100.json` | 规模契约 |
| C4 baseline | `docs/C4_DUALCORE_BASELINE.md`、`docs/handoffs/T-20260829-103-c4-dualcore-baseline.md`、`docs/tasks/evidence/T-20260829-103.json` | CORE_COUNT=2 baseline |
| C4 JSON | `fpga/opensynth/c4_dualcore_baseline.json` | 机器可读测量 |

## 07-fpga

| 证据 | 路径/commit | 说明 |
| --- | --- | --- |
| FPGA 计划 | `docs/FPGA_PLAN.md`、`docs/P7_FPGA_PARALLEL_PLAN.md` | 平台/阶段门 |
| 平台包 | `fpga/catapult_a10/` | QSF/SDC/Qsys/SFL/JTAG |
| 平台 manifest | `fpga/catapult_a10/platform_manifest.json` | 来源/hash/再生成 |
| SHA256SUMS | `fpga/catapult_a10/SHA256SUMS` | payload 哈希 |
| T-063 | `docs/tasks/evidence/T-20260828-063.json`、`docs/handoffs/T-20260828-063-catapult-project-create.md` | 远程工程创建/IP 再生成 |
| T-064 | `docs/tasks/evidence/T-20260828-064.json`、`docs/handoffs/T-20260828-064-catapult-fullflow.md` | full flow/STA |
| T-065/T-067 | `docs/tasks/active/T-20260828-065.json`、`T-20260828-067.json`、`docs/handoffs/T-20260828-067-b5-fullflow-rerun.md` | B5 接线和 blocked |
| T-101/T-102 | 见 03 | OOM/热点 |
| 开源代理 | `fpga/opensynth/README.md`、`a1_generic_synth_stats.json`、`a3_correlation_report.md`、`a4_trend_report.md` | 非替代 Quartus |

## 08-security-boundary

| 证据 | 路径 | 说明 |
| --- | --- | --- |
| 工作流禁止事项/资源 | `docs/MULTI_AGENT_WORKFLOW.md` §2.1.10、§4、§10 | cgroup、禁止事项 |
| 远端写规则 | `docs/tasks/active/T-20260828-065.json`、`T-20260828-067.json`、`T-20260829-101.json` | 远端写集/license 规则 |
| 平台 manifest note | `fpga/catapult_a10/platform_manifest.json` | 来源锁定，无 license |
| 审计任务写集 | `docs/tasks/active/T-20260829-104.json`、`docs/audit/*` | 本材料数据边界 |

## 09-risks

| 证据 | 路径 | 说明 |
| --- | --- | --- |
| 全部风险来源 | `docs/V82_PROFILE_MANIFEST.md`、`docs/ROADMAP.md`、`docs/ISA_GAPS.md`、`docs/C3_FOURCORE_PREWORK.md`、`docs/C4_SCALE_PREWORK.md`、`docs/FPGA_PLAN.md`、`docs/P7_FPGA_PARALLEL_PLAN.md` | 后置/未完成 |
| T-067 风险 | `docs/handoffs/T-20260829-101-t067-synth-opt.md`、`T-20260829-102-t067-module-synth.md` | OOM/可综合 |
| 多核风险 | `docs/handoffs/T-20260829-089-c3-fourcore-prework.md`、`T-20260829-092-c2-remainder.md`、`T-20260829-100-c4-scale-prework.md` | C3/C4/回归 |
| checkpoint 风险/证据 | `docs/handoffs/T-20260829-097-checkpoint-sidecar-v4.md`、`docs/handoffs/T-20260829-117-aud-12.md`、`docs/tasks/evidence/T-20260829-117.json` | v4 联合恢复已由 AUD-12 闭环；仍无长链/全寄存器矩阵 |
| Gate/CI | `docs/ROADMAP.md`、`docs/GIT_WORKFLOW.md`、`.github/workflows/ci.yml` | 晋级门/CI |
