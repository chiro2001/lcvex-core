# ADR-20260905-006：时序收敛采用批次候选流水线

- 日期：2026-09-05
- 状态：Accepted
- 范围：post-fit/STA 驱动的 RTL 时序优化、联合仿真和 FPGA physical flow

## 背景

FP-P5 从早期不可收敛路径改善到接近 50 MHz 的过程中，长期采用“一次 physical
只修 top-1”的安全串行环。该方式便于归因，但每个切级后都会重复 Verilator/QEMU
矩阵和远端 synthesis/fitter/STA，Quartus 等待直接位于关键路径。多个 round 的
top-N 实际包含不同模块或不同端点族，也有大量条目只是同一共享组合锥的重复路径；
因此机械串行和机械取前 N 条都不是最优调度。

## 决策

采用 Timing Batch：每份匹配冻结 SHA 的 STA 报告先按共享节点、端点族、模块和
根因聚类，再选择最多三个独立 cone lane。lane 在独立 worktree 并行实现 RTL、
定向测试和回退提交，但不分别占用重型仿真槽。集成者把已审 lane 先合入临时
`batch/<id>` candidate，在该合并 SHA 上只运行一次联合 L0–L2；通过后才进入长期
feature 分支，并从精确 SHA 运行一次远端 physical。

`batch/*` 是可丢弃验证分支，不是稳定集成分支，更不是 `main`。`main` 仍只接收
本地 Gate D 和 CI 通过的稳定提交。

batch 的联合验证覆盖所有 member lane acceptance 声明的 L0–L2 并集，不使用可能
漏项的“代表性 L2”。长期 feature 分支只用 `--ff-only` 晋级到精确 candidate SHA；
若并发提交导致不能 fast-forward，必须在新基线重建 candidate 并重跑联合 L0–L2，
不能让 cherry-pick 后的新 SHA 沿用旧证据。

## 并行与资源模型

| 活动 | 可与 lane 编码并行 | 可与本地联合仿真并行 | 可与远端 physical 并行 |
| --- | --- | --- | --- |
| 只读 timing 分析 | 是 | 是 | 是 |
| 独立 RTL lane 编码 | 是 | 是（不同 worktree、资源合计合规） | 是 |
| 本地重型 Verilator/QEMU/Gate/Linux | 是 | 否，同一时刻单路 | 是 |
| 远端 Quartus | 是 | 是 | 否，同一远端单路 |
| QEMU fork 修改/构建 | 受全局串行门约束 | 否 | 仅只读复用时允许 |

physical(N) 等待期间允许为下一批分析和制作原型，但这些结果标记
`speculative_base`。physical(N) 返回后必须重新聚类；原路径不再存在或根因变化时，
原型不得凭旧报告进入 candidate。

## 同文件写集例外

默认仍按文件互斥。只有一个已登记 batch 父任务持有整个文件，且成员 task 声明
互斥的 `write_regions` 时，才允许多个 lane 修改同一 SystemVerilog 文件。region
必须落到明确 module/generate/function/state；公共 typedef、端口、enum、状态机
骨架、latency 表、测试入口、格式化和重命名由 integration lane 串行处理。越界
diff 直接退回；影响同一寄存器边界或同一 endpoint cone 的改动合并为单 lane。

## 验证与回退

每个 lane 保留一个逻辑提交和定向测试增量；batch evidence 记录成员 head、合入
顺序、合并 SHA、联合测试集合与 physical manifest。联合验证失败时按 lane commit
revert/bisect，不允许跨 SHA 拼接绿项。physical 必须报告每个旧 cone 的 presence、
新 top-N、TNS/endpoints、Fmax、资源和 latency 代价。只有所有 timing 类别非负且
DDR/Metastability 通过，才允许 assembler/SOF。

## 结果

预期把多条独立路径的 Verilator/QEMU 与 Quartus 固定成本从“每 lane 一次”降到
“每 batch 一次”，并让本地验证、远端 physical 和下一批分析形成流水重叠。代价是
单个 physical 结果不再天然归因到一处修改，因此强制原子 lane commit、联合候选、
区域所有权和可回退 bisect。首个新 batch 从 T-20260902-058 返回的新 top-N 开始，
不改变已冻结且正在运行的 T-058。
