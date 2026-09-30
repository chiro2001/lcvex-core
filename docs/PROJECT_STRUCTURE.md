# LCVEX 工程结构（2026-08-26）

本文梳理仓库的源码、验证体系、构建入口和产物/临时目录约定，作为新开发者的
导航文档。目标架构与阶段约束以 `AGENTS.md`、`ROADMAP.md` 为准。

## 顶层布局

| 目录 | 职责 |
|---|---|
| `rtl/` | 全部 SystemVerilog RTL（单核 SoC：core + 存储层次 + 外设） |
| `tb/sv/` | 独立 SystemVerilog testbench（Verilator + Verilator 原生驱动） |
| `sim/cocotb/` | Cocotb 定向单元/集成测试 |
| `sim/difftest/` | QEMU 差分验证：trace/checkpoint 工具、锁步协调器、运行脚本 |
| `sim/mmio/` | MMIO C++ 行为模型（Verilator 锁步平台内的外设模型） |
| `sim/microbench/` | baremetal microbench 运行器（被测 ELF 的宿主执行） |
| `baremetal/` | 裸机测试程序与启动代码（含 lite initramfs 的 `init.S`） |
| `scripts/` | 构建、CI、测试规划、覆盖率、trace/checkpoint 工具脚本（手工派单成为瓶颈后再考虑 `taskctl.py`） |
| `qemu/` | QEMU fork 管理：版本、patch、difftest 插件 |
| `docs/` | 设计/计划文档、任务/决策规范、`handoffs/` 阶段交接 |
| `docs/tasks/` | 每任务 JSON、任务索引、模板及小型 evidence |
| `docs/decisions/` | 跨子域架构/流程 ADR（不可改写历史结论） |
| `docs/domains/` | 稳定子域、接口和文件所有权地图 |
| `configs/` | 构建配置 |
| `env/` | 环境辅助 |
| `.github/workflows/` | CI（本地 Gate D 可信前 CI 仅辅助） |

## RTL 层次（`rtl/`，约 8700 行）

```text
lcvex_core.sv          SoC 顶层/内核
├─ 指令通路：lcvex_decode（译码）、lcvex_regfile（X0-30/SP/NZCV）、
│  lcvex_alu（算术逻辑）、lcvex_muldiv（乘除）
├─ 系统寄存器/异常：PSTATE、SPSR/ELR、ID 寄存器（lcvex_pkg.sv 常量）、
│  异常入口/返回、ERET 目标语义
├─ 存储层次：lcvex_l1_i / lcvex_l1_d / lcvex_l2 / lcvex_mmu
├─ 内存通路：lcvex_mem（仲裁/延迟/路由器/RAM）
└─ 外设：lcvex_pl011（UART）、lcvex_pl061（GPIO）、lcvex_gic（中断）、
   通用定时器
```

`lcvex_pkg.sv` 集中存放：总线类型、异常编码、ID/系统寄存器复位值、
各 `A64_*` 使能参数（如 `A64_FP_SIMD`）。模块间依赖全部通过
`filelist.f` 组织，Verilator/仿真统一引用。

## 验证体系（三层）

1. **SV testbench**（`tb/sv/`）：单模块定向测试，`make sim-sv*` 系列目标，
   覆盖 core/l1i/l1d/l2/mmu/pl011/pl061/mmio fabric/crc/backpressure。
2. **Cocotb**（`sim/cocotb/`）：Python 定向测试，`make sim-cocotb*`，
   覆盖 ALU/regfile/core/commit backpressure/mmio fabric。
3. **QEMU 差分锁步**（`sim/difftest/`，主验证线）：
   - QEMU 11.1.0 fork + 插件 `qemu/plugins/lcvex_difftest.c`（patch 001-011 可重放）；
   - `lockstep_coordinator.cc`：Verilator C++ 协调器，与 QEMU 通过 Unix socket
     严格逐指令 `PRE/COMMIT` 对齐；
   - `checkpoint.py`：差分 checkpoint（ram/arch/dev/sys/timer/gic/mmio 七分片 gz）；
   - 运行脚本：`run_lockstep_step.sh`（首跑）/`run_lockstep_resume.sh`（续跑）；
   - 场景脚本：`run_m2_4b.sh`、`run_p4b.sh`、`run_p5a.sh`、`run_p6_*.sh`、
     `run_gate_c.sh`、`run_gate_d.sh`（Gate D 本地验收门）。

验证原则（`AGENTS.md`）：架构状态只在 commit 阶段更新；锁步 seq 严格一一对应；
失败必须保存编码/反汇编/双侧状态与提交记录；不放松差分比较。

## 构建与运行入口（Makefile）

```text
构建：compile / lockstep-build*（kernel/kernel-nofp/l1i/l1d/l2/l1dl2…）
内核：lockstep-build-kernel（主）/ lockstep-build-kernel-nofp（lite 无 FP）
测试：sim-sv* / sim-cocotb* / difftest* / difftest-rtl / difftest-qemu
验收：gate-d / m2-4b / p4b / p4c / p5a / p6-lse / p6-wfi / q6
辅助：checkpoint-*-smoke / dtb-smoke / check-encoders / qemu-sysreg-inventory
      microbench*（baremetal ELF 编译与宿主运行）
```

## 脚本（`scripts/`）

| 脚本 | 用途 |
|---|---|
| `build-*.sh` | baremetal / linux-lite / microbench / qemu 构建 |
| `run_lockstep_parallel.sh` | 并行锁步调度（资源上限/绑核/排队） |
| `test_planner.sh` | 测试规划（筛选、指定测试子集） |
| `ci-fast.sh` / `ci-nightly.sh` / `ci-difftest.sh` | CI 分层 |
| `insn_coverage.py` / `linux_insn_gap.py` / `kernel_trace_gap.py` | 指令覆盖与缺口分析 |
| `qemu_sysreg_inventory.py` | QEMU 系统寄存器清单导出 |
| `trace_slice.py` | trace 切片（完整负载中途起跑） |
| `validate_virt_dtb.py` | DTB 校验 |

## 文档地图（`docs/`）

- 架构/计划：`ARCHITECTURE.md`、`ROADMAP.md`、`DEVELOPMENT_PLAN.md`、
  `PROJECT_STATUS.md`、`LINUX_PLAN.md`、`FPGA_PLAN.md`
- 指令集：`ISA_SCOPE.md`、`ISA_GAPS.md`（当前实现/缺口快照）
- 验证：`VERIFICATION.md`、`DIFFTEST.md`、`DIFFTEST_QEMU_PLAN.md`、
  `COMMIT_PACKET.md`、`TEST_ENHANCEMENT_PLAN.md`
- 流程：`GIT_WORKFLOW.md`、`MULTI_AGENT_WORKFLOW.md`、`TOOLCHAIN.md`、
  `DEBUG_PMU_PLAN.md`
- 任务/治理：`tasks/README.md`、`tasks/TASKS.md`、`tasks/evidence/README.md`、`handoffs/README.md`、
  `decisions/README.md`、`domains/README.md`
- 交接：`handoffs/001-100`（每阶段/里程碑一手档）

## 多 Agent 工作区和所有权

- 主仓库 worktree 是集成 root；子 Agent 使用仓库外 sibling worktree，例如
  `/home/chiro/projects/mycpu/lcvex-wt-<task-id>`，每个 worktree 对应唯一 topic
  分支。统一 QEMU 路径前使用 direct sibling 以保留 `$REPO/../qemu`。不要把
  worktree 放在本目录内，也不要共享分支或 index；纯只读审阅除外。
- 任务定义在 `docs/tasks/active/T-*.json`，由集成者创建/审批；`TASKS.md` 是索引
  （当前由集成者手工快照）；当前不引入独立任务服务或 lease 数据库。
  `PROJECT_STATUS.md` 由集成者批量更新，handoff 是任务历史证据。
- 稳定子域和热点文件的预约见 `docs/domains/README.md`；`decode/pkg/core`、
  顶层 Makefile、Gate 脚本和 QEMU patch 序列默认串行集成。

worktree 会隔离不同 worktree 内的仓库相对构建产物；它不隔离同一 worktree 的
固定目录并发、外部 QEMU build、共享 cache 和全机资源。当前只使用已支持的
override，同一 worktree 不并行运行会写固定目录的目标，QEMU 修改/构建串行。
Unix socket 路径小于 108 字节，必要时把 `RUN_ROOT` 放在仓库外的短 sibling 目录。

中期结构优化不改变现有构建系统：先试点 worktree，再把重复的 `hard_*`/
`MAX_INSNS` 清单收敛到按 `isa/mmu/cache/mmio/system` 分类的测试 registry；随后
可将顶层 Makefile 的机械目标拆入 `mk/sv.mk`、`mk/cocotb.mk`、
`mk/difftest.mk`、`mk/gates.mk`。`core/decode/pkg` 和大型协调器只在稳定接口与
独立验证形成后拆分，不为追求 Agent 数量进行无语义的目录/文件切割。详见
`MULTI_AGENT_WORKFLOW.md` 第 7 节。

## 产物与临时目录约定

- `build/` 全部为 gitignored 产物；普通构建输出放任务隔离的
  `build/agents/<task-id>/`，大临时文件、RAM、checkpoint 等放
  `build/tmp/<task-id>/`；不把大文件或长期隐式输入放系统 `/tmp`。
- Agent 产物优先放 `build/agents/<task-id>/`；Linux 长跑、checkpoint 和大镜像
  放 `build/tmp/<task-id>/`。每个运行目录保存 `run.json/result.json` 或等价
  manifest，记录 source SHA、配置、工具版本、seed、资源、路径、大小和 SHA256。
  大 trace/波形/失败 RAM 不进 Git。最终小型验证清单进
  `docs/tasks/evidence/<task-id>.json`；大产物引用持久 URI/retention/owner，不能
  把会随 worktree 清理的本机路径当长期证据。
- 可共享的工具链和固定 QEMU release 应视为只读；Verilator mdir、QEMU plugin、
  socket、trace、checkpoint 和日志不得跨任务共享可写路径。`scripts/test_planner.sh`
  目前只提供建议并行度，A0 的重型作业由集成者统一排队。
- `build/tmp/` 中的 `chain/` 是差分 checkpoint 链（每 seq 七分片 gz）；
  里程碑链应保留：lite `lite-rdinit-post8m` / `lite-init-final3`、
  主线 `linux-main-pl061-20260825/main-scalar2`。
- `obj_dir*` / `sim/cocotb/sim_build*` 为 Verilator 可再生产物，可随时重建；
  历史快照构建（`build/verilator_lockstep*.pre-*`、`*.bad*`）确认无用后可删。
- 失败现场（`build/difftest/resume-run.*`，每个含 128MB ram.bin）体积大，
  只保留最近少量，历史失败以 handoff 记录为准。
- 大 trace（`kernel_boot*.trace`）不进仓库/本地常驻，走 release 管理并限制总大小。
