# Handoff T-20260830-034: PE-A core/cache/总线外部性能静态审计与优化规划

## 元数据
- task: T-20260830-034
- label: PE-A
- owner: T-20260830-034 (PE-A internal audit)
- date: 2026-08-30
- base_sha: `e42bf7442044f74b41b4d96584f774116c533069`
- head_sha: `03a99725f8e323b5b9f0fb44bb9008451934b741`（审计期间仓库最新 HEAD；本任务未产生新提交）
- branch: `feature/p7-final`（只读审计直接在工作区完成，未创建独立写分支；只新增 docs 文件）
- worktree: 主仓库共享只读快照
- dependencies: T-20260830-009 P-line、T-20260830-021 P-SNAPSHOT、C2/C3/C4 既有多核测量
- qemu_release: 不适用
- qemu_commit: 不适用
- qemu_patches_sha: 不适用
- rtl_filelist_sha: 未生成（未运行构建/校验文件清单）
- config/toolchain: 不适用（未运行 Verilator/Quartus）
- evidence: docs/tasks/evidence/T-20260830-034.json

## 目标与边界

对 LCVEX 当前 core/cache/总线/多核做只读静态性能审计，形成可执行优化规划。覆盖：

1. Core 流水线：级数、单发射/顺序、stall、分支/前端、双发射/更深流水空间。
2. Cache：L1I/L1D/L2 命中/refill/writeback/probe/drain、outstanding、bank 化。
3. 总线/内存：mem_router、AXI4、Avalon/EMIF、宽度/beat/仲裁/outstanding。
4. 多核：共享 L2 单事务、probe 串行、目录位图、仲裁。
5. 候选方向与优先级、预期收益、风险、改动范围、验证方法、P-line 对应。

边界：不修改 RTL/测试；不启动 Quartus；不宣称任何性能收益已实现；不引入 SVE/ACE/CHI。

## 实现摘要

改动文件（仅文档）：

- `docs/PERFORMANCE_ENHANCEMENT_PLAN.md`（新增，主交付物）：
  - 现状审计（流水线、cache、总线、多核）
  - 测量缺口与前置工作
  - C1–C8 候选方向，每项含现状、预期收益、改动范围、难度/风险、新增测试、P-line 关系、优先级
  - 建议实施顺序与回归策略
- `docs/handoffs/T-20260830-034-pe-audit-plan.md`（本交接）
- `docs/tasks/evidence/T-20260830-034.json`（精确静态审计事实）

未改动：

- 未修改任何 `rtl/**`、`tb/**`、`sim/**`、`baremetal/**`。
- 未启动重型 Verilator、Quartus、FPGA 流程。
- 工作区中存在的 `rtl/lcvex_decode.sv` 未提交修改保持原样，不是本任务改动；审计期间未触碰。

关键审计结论（详见主文档）：

- 最大瓶颈：单发射 + 无取指缓冲 + 分支 ID 级 flush + 单 outstanding 访存；当前 P-line 又是无缓存默认配置。
- Top 3：
  1. P0 前端/分支/取指缓冲
  2. P0/P1 缓存接入 P-line 与访存 outstanding/MSHR
  3. P1 多核共享 L2 数据阵列与 probe 并行化
- 建议实施顺序：C2（测量）→ C1（前端）→ C3（MSHR/outstanding）→ C4（多核）→ C5（总线）→ C6/C7/C8（远期）。

## 验证证据

| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-static-source-inventory-001 | L0 | 只读检查 RTL 文件清单、核心流水线/缓存/总线/多核模块，确认无 RTL/测试改动 |
| owner-static-doc-scan-002 | L0 | 读取 P-line 计划、P-SNAPSHOT、C4/C3/C4-pre 文档和既有性能 handoff，确认测量口径 |
| owner-doc-write-003 | L0 | 生成 `docs/PERFORMANCE_ENHANCEMENT_PLAN.md`、handoff、evidence |

精确命令、路径、SHA 和状态见 evidence JSON。

## 失败现场/重现

无失败现场。未运行可能失败的重型构建。

## 已知限制与后续任务

- 本规划是静态/代理分析，不包含实测 IPC/带宽；P-line 当前只有整程序 cycle，没有分相。
- 当前 P-line 的 `lcvex_soc_tb` 默认关闭 I/D/L2，因此 cache 类候选必须先补测量基线。
- T-20260830-035 PE-EXT 平行独立审计；本规划需与其结果综合成 `docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md` 后才进入实施。
- 更深的流水线、双发射等列为远期 P2；不建议在没有前端和访存基础数据前投入。

## 集成说明

- 只新增三个 docs 文件，无 RTL/测试/共享热点改动，可与 PE-EXT 并行。
- 集成者合入前可复核主规划中的候选与 P-line 对应；之后将 PE-A/PE-EXT 合并成最终计划并拆分 PE-1/PE-2/PE-3 实施任务。
