# LCVEX 项目交接给 Codex（2026-08-30）

## 1. 当前权威基线

- 仓库：`/home/chiro/projects/mycpu/lcvex`
- 分支：`feature/p7-final`
- HEAD：`71d6830d053bf172989f43316b3cf48dfb09c5eb`
- origin：已同步
- 工作区：干净
- 集成线：单核 + 多核 + FPGA 共用 `feature/p7-final`

## 2. 项目目标

LCVEX：ARMv8.2-A AArch64 单核 in-order CPU，Verilator/Cocotb/QEMU 11.1.0 差分验证，Catapult A10 FPGA 平台，已扩展：
- P7 FP/NEON
- A 线：开源综合代理（完成）
- B 线：V82 非 SVE profile（完成）
- C 线：2/4/8/16/32 核（2/4 功能完成，8/16/32 规模/有限 smoke）
- 性能增强线（PE）：路线图已完成，F0 基线完成，F3/F1 待实施
- FPGA-G 线：BRAM OOM 已解决，真实 SoC synthesis 通过，fitter 阻塞在 L1D/L2 cache RAM

## 3. 已完成并合入的关键工作

### 3.1 单核/FP/NEON/多核
- P6/P7 功能，Linux lite 35M 锁步记录
- C2 双核 MSI、C3 四核、C4 8/16/32 规模
- C3 merge：`fccb674`
- C4 8 core，16/32 no-FP scale

### 3.2 性能线
- `docs/PERFORMANCE_WORKLOAD_PLAN.md`：14 个 workload
- `docs/PERFORMANCE_SNAPSHOT.md`：P-SNAPSHOT
- PE-A：`docs/PERFORMANCE_ENHANCEMENT_PLAN.md`
- PE-EXT：`docs/PERFORMANCE_ENHANCEMENT_PLAN_INDEPENDENT.md`
- 最终路线图：
  - `docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md`
  - `docs/PERFORMANCE_ENHANCEMENT_ROADMAP.md`
- PE-F0 已完成：
  - `docs/PERFORMANCE_BASELINE_MATRIX.md`
  - Artifacts：`docs/evidence/artifacts/T-20260830-037/`
  - 脚本：`scripts/run_perf_matrix.py`
  - 最多 9 配置 × 14 workload = 126 行
  - 核心结论：缓存主要降事务，不降周期；单 outstanding 访存是瓶颈；F3 优先

### 3.3 FPGA 线
- A10 顶层参数化：`L1_SETS=64 / L2_SETS=64 / L2_WAYS=1`
- 显式 M20K BRAM wrapper 已合入主线：
  - `rtl/lcvex_bram_boot.sv`（SYNTHESIS 分支走 altera_syncram）
  - G2/G3/G2-INT/G4 均验证
- FPGA-G4：
  - 真实 SoC RTL A10 Synthesis：PASS（46m17s，13.5GB）
  - Fitter：未收敛，cache data 阵列 LUT 化
  - 报告：`docs/handoffs/T-20260830-032-fpga-g4.md`

### 3.4 审计/治理
- AUD-01..AUD-13、EXT-01/02/03、HIST-EVID-FIX 等已完成
- Gate D 13/13，make test 通过
- 时间戳 0 error/0 warning

## 4. 当前最重要阻塞 / 下一步

### FPGA（最高优先）
- **Fitter 不能收敛的原因：L1D/L2 cache data 阵列仍是行为级 byte array，综合为 LUT/ALM**
- 解决路径：为 `lcvex_l1_d_wb` 和 `lcvex_l2_wb` 的 data 阵列建立显式 M20K/MLAB RAM wrapper（仿照 `lcvex_bram_boot_altsyncram`）
- 完成后重跑 A10 synthesis → fitter → STA → assembler
- T-067 仍 blocked：完整 B5 full flow 尚未解除；不要自动重启 B5 full flow

### 性能增强（用户已暂停派发）
- 等用户明确继续派发后：
  1. **F3**：受限 outstanding / MSHR / store buffer（F0 证明最直接）
  2. **F1**：前端取指 FIFO / early restart / critical-word-first
  3. F2/F4/F5/F6/F7 按路线图 DAG
- 已有最终路线图 DAG 在 `docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md` / ROADMAP

## 5. 当前任务/权限状态

- **当前无 running subagent**（所有已派发任务已 ready/done）
- 用户明确：暂停派发，直到其说继续
- 不要擅自启动新 subagent / Quartus full flow / 重型 Verilator 并行

## 6. 本地/远程环境规则

- 所有本地重型 Verilator 构建：
  ```bash
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- ...
  ```
- 一次只跑一个重型 Verilator；`-j1`
- 远端 Windows：
  - `192.168.101.5`
  - 工程根：`D:\Projects\fpga-altra\lcvex`
  - Quartus Pro 21.4 Build 67
  - 只允许隔离 build 目录实验，不修改原始 QSF/SDC/RTL，不读 license
- 多 Agent 流程事件驱动，禁止 sleep 轮询
- 所有 subagent 必须使用独立 worktree

## 7. 关键文档索引

| 文档 | 用途 |
|---|---|
| `docs/T-20260828-071-073-parallel-lines-plan-v2.md` | 三线并行计划 |
| `docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md` | 最终性能增强路线图 |
| `docs/PERFORMANCE_ENHANCEMENT_ROADMAP.md` | DAG/实施顺序 |
| `docs/PERFORMANCE_BASELINE_MATRIX.md` | F0 基线 |
| `docs/C3_FOURCORE_PREWORK.md` | 四核拓扑 |
| `docs/C4_SCALE_PREWORK.md` | 8/16/32 口径 |
| `docs/handoffs/T-20260830-032-fpga-g4.md` | G4 真实 SoC A10 结果 |
| `docs/handoffs/T-20260830-029-fpga-g2.md` | G2 BRAM M20K |
| `docs/handoffs/T-20260830-031-fpga-g2-int.md` | BRAM 主 RTL 集成 |

## 8. 明确禁止/不要做

1. 不启动完整 B5 full flow，直到 L1D/L2 RAM wrapper 完成且用户允许
2. 不引入 SVE/SME、不引入 ACE/CHI
3. 不要把规模/FPGA 实验结果写成 Linux SMP/板级/架构合规已通过
4. 不删除未知用户文件/工程
5. 不读取 license
6. 不无命令自动继续派发新任务（当前处于暂停状态）
7. 不伪造性能收益、不伪造 FPGA full flow 通过

## 9. 后续推荐第一步

等用户说“继续”后：
1. 创建任务：**L1D/L2 显式 M20K/MLAB RAM wrapper**
2. 创建任务：**F3 受限 MSHR / store buffer**
3. 两者可并行准备，但注意 F1/F3 都改 core 需串行合入
