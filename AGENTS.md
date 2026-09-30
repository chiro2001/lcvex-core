# LCVEX 项目协作规范

本文档约束在本仓库中工作的开发者和自动化代理。项目说明和设计文档使用中文；代码中的模块名、信号名、测试名和提交信息可使用英文，但必须保持语义清晰。

## 工作边界

- 目标架构固定为 ARMv8.2-A AArch64 only。
- 微架构第一阶段固定为单发射、顺序执行、非 OoO、单核。
- RTL 使用 SystemVerilog；仿真使用 Verilator；验证同时使用 Cocotb 和 SystemVerilog testbench。
- QEMU 使用最新稳定 release，不使用不稳定的 master。QEMU 修改保存在本地 fork，并以可重放的 patch 管理。
- QEMU difftest 分为 P1 批量 trace 和 P2 Unix socket 锁步两种模式；P2 推荐由
  QEMU 插件连接独立的 Verilator C++ 协调器，Cocotb 负责测试控制。
- 早期只使用 1-cycle SRAM。I/D L1、统一 L2、MMU、异常和中断按路线图逐步加入。
- Altera/Intel FPGA、NEON/FP、SVE256、JTAG/GDB、PMU 必须等核心标量差分测试通过后再实现。

## 修改规则

1. 修改前先阅读相关文档和现有测试，保留用户已有的未提交改动。
2. 文件编辑使用 `apply_patch`；不要使用脚本覆盖整个目录或删除未知文件。
3. 每个功能必须同时加入实现、测试和必要的文档。
4. 不要为了通过测试而关闭断言、跳过差分比较或修改参考结果。
5. 任何新的系统寄存器、异常或流水线状态都要说明 reset 值、读写权限和提交时机。
6. 不在早期阶段引入 FPGA 厂商 IP、时序约束或板级依赖。

## 验证规则

- RTL 的架构状态只在 commit 阶段更新。
- 每条已支持的标量指令必须有定向测试，并纳入 QEMU 单步差分测试。
- 锁步模式中，QEMU 的 `PRE/COMMIT`、Verilator 的 commit packet 和协议 `seq`
  必须严格一一对应；不得把 QEMU 的 before-instruction callback 误当作通用
  after-instruction retirement hook。
- 提交数据至少包括 PC、寄存器写回、NZCV 和下一条 PC；Load/Store 阶段增加内存副作用比较。
- Verilator、Cocotb 和 SystemVerilog testbench 都应能独立复现失败用例。
- 失败时保存指令编码、反汇编、执行前状态、RTL 状态、QEMU 状态和最近提交记录。

## Git 规则

- `main` 只接受通过验收的稳定提交：**本地 Gate D 全绿 + CI 通过**；
  CI 未可信前以本地 Gate D 为准。阶段门（如 M3 完成）由 feature
  分支快进合并进 main，避免 main 长期落后。
- 功能开发使用 `feature/<topic>`；验证和基础设施可使用 `verify/<topic>`、`infra/<topic>`。
- 长命集成分支建议按阶段命名（如 `feature/m3-isa`），阶段更替时更名
  并清理已被历史完全包含的旧分支。
- 一个提交只解决一个逻辑问题；不要把格式化、重命名和功能混在一起。
- QEMU 修改必须能由 `qemu/patches/` 中的 patch 重新应用到指定 release。
- 提交信息采用 `<scope>: <summary>`，例如 `decode: add ADD shifted-register`。
- 合并前必须记录测试命令、结果和已知限制。

## 评审重点

评审 RTL 时优先检查：流水线冲刷、数据相关、XZR/SP 语义、32 位写入零扩展、异常边界、访存字节使能、提交顺序和复位行为。评审 QEMU 修改时优先检查：是否严格单步、状态采样时机、异步事件是否关闭以及版本可重现性。

## 多 Agent 协作

详细流程见 [`docs/MULTI_AGENT_WORKFLOW.md`](docs/MULTI_AGENT_WORKFLOW.md)。当前采用
最小流程，不把未来自动化当作开发前置条件：

- 主/集成 Agent 负责静态派单、写集互斥、worktree 创建/回收、重型测试队列、
  串行集成和里程碑更新；当前不需要常驻任务管理服务。任务多到手工管理成为瓶颈
  时，才增加仓内薄 `taskctl.py`。
- 每个写任务在 `docs/tasks/active/T-*.json` 登记唯一 ID、owner、`base_sha`、依赖、
  `writes/reads`、验证套餐和 handoff/evidence；只由集成者更新。子 Agent 每次只做
  一个完整垂直任务包，默认只有 `done` 的依赖算满足，同一写集保留到任务关闭。
- 时序收敛默认使用批次流水线：一次 post-fit/STA 把 top-N 按共享组合锥、端点族和
  模块聚类，选择 2–3 个独立 cone lane 并行实现；各 lane 先汇入独立 batch
  candidate，再在该合并 SHA 统一运行受影响的 L0–L2 和一次 physical flow。
  “先合入”只指临时 candidate，不是未验证代码进入 `feature/*` 或 `main`。
- 同一文件的并行 lane 仅能在一个已登记 batch 父任务下使用精确 `write_regions`
  例外；区域必须是互斥的 module/generate/function/state，公共 typedef、端口、状态枚举、
  latency 表和测试入口只由 integration lane 串行修改。无法证明互斥时仍按文件写集
  串行，不允许让多个 Agent 自行解决同文件冲突。
- 每个会修改文件或产生构建/测试产物的 Agent 使用唯一 topic 分支和仓库外 direct
  sibling worktree：`/home/chiro/projects/mycpu/lcvex-wt-<task-id>`。纯只读审阅可共享
  指定快照；一旦写入或运行生成器/测试就必须进入独立 worktree。不得操作别人的
  worktree、分支或失败现场。
- A0/A1 不并行修改 QEMU fork；共享 QEMU binary/header 只读，QEMU 构建和 patch
  重放串行。完成所有 QEMU 路径参数化前保持 direct sibling，确保 `$REPO/../qemu`
  仍正确解析。
- 不同 worktree 会隔离仓库相对 `obj_dir*` 和 `build/`；仍须避免同一 worktree 内
  两个作业写固定目录，并串行外部 QEMU build、共享 cache 和其他显式共享路径。
  只使用入口已支持的路径 override，不能设置未接线变量后声称隔离成功。
- Agent 的分析、编码和只读评审可并行；重型构建、锁步、Linux 长跑和 Gate
  按本地、远端及共享热点分别进入资源队列。所有本机 heavy 作业必须先通过
  `/home/chiro/projects/.resource-locks/resource-lock` 取得 `local`，所有 GamePC
  heavy 作业必须取得 `gamepc`。取得独占锁后不再强制本机 50% CPU/内存或
  16 GiB 硬上限；集成者按当时资源和任务峰值选择并记录准入门槛、并行度及可选
  cgroup，且不得影响用户交互进程。CI 仍最多使用 75%；`scripts/test_planner.sh`
  只是建议器，不是全局 reservation。
- 本地重型仿真队列与远端 Quartus 队列是两个资源槽，输入和输出路径隔离时可以
  重叠；上一批 physical 运行期间，下一批只能做分析/原型，必须等最新 timing
  报告重新排序并确认路径仍存在后，才能进入下一个 batch candidate。
- 验证层级为 L0=microbench、L1=单元/SVA、L2=定向 QEMU 锁步、L3=Gate D、
  L4=nightly/长 Linux。Agent 跑受影响的 L0–L2；集成者在合并 SHA 复跑任务要求的
  子集，并在冻结 candidate 的 detached gate worktree 运行 L3。
- handoff 只保存实现摘要、边界、结论、风险和 evidence 链接；精确命令、source
  SHA、seed、版本、资源和 artifact hash 以 `docs/tasks/evidence/<task-id>.json`
  为准。owner 创建 evidence，集成者补合并 SHA 复跑后定稿；已归档文档不改写。
- `TASKS.md`、`PROJECT_STATUS.md` 和 `ROADMAP.md` 由集成者按批次更新。完整 log、
  trace、波形、RAM 和 checkpoint 不进 Git，也不把大文件写系统 `/tmp`。
