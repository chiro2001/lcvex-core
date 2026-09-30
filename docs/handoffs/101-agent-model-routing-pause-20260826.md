# Handoff 101：模型路由 v2 与正式实现前暂停

## 元数据

- task: PAUSE-20260826-MODEL-ROUTING
- owner: root/integrator
- date: 2026-08-26
- base_sha: 8052572d328031d8edbdce97ae03747fa07486d8
- head_sha: bd13000b90eb8a654bfbcb1cd5a50baa68545653
- branch: feature/p6-system-reg-shim
- worktree: /home/chiro/projects/mycpu/lcvex
- dependencies: T-20260826-001 已完成；T-20260826-002 暂停
- qemu_release: QEMU 11.1.0（本交接未运行 QEMU）
- config/toolchain: 文档/任务治理变更；未启动重型构建或 Linux 长跑
- evidence: 本交接记录模型联通结果；正式实现证据仍归属各任务 JSON

## 当前长期目标

完成 ARMv8.2-A AArch64 单核 CPU 全路线：P6 Linux/Gate E → P7 选定 FP/NEON →
P8 SVE256 → P9 JTAG/GDB/简化 PMU → P10 FPGA；全过程保持逐指令 difftest、分层
验证、可压缩/可切片 checkpoint、可复现 evidence 和多 Agent worktree 协作。

## 已完成的流程工作

- `ee56278`：多 Agent 控制面、worktree、任务/evidence/handoff 模板。
- `7e1e457`：登记 A0 第一波任务。
- `7f07422`、`71f7734`、`1b88804`：T-20260826-001 registry/query 实现、合并复测和归档。
- `bd13000`：模型路由 v2 与 ADR-20260826-002。

## 当前模型路由

| 类型 | 派单方式 | 用途 |
| --- | --- | --- |
| Terra | `model=gpt-5.6-terra, reasoning=xhigh` | 复杂跨域方案和依赖拆解 |
| Sol | `model=gpt-5.6-sol, reasoning=high` | 限定可见范围的方向性审核，只给大方向/阻断风险 |
| Luna | 省略 `model`，`reasoning=max` | 耗时任务、监控、长跑和相对简单编码 |
| DeepSeek | 暂停派单 | 用户重新启用前不分配新任务 |

模型联通探针结果：Luna 默认通道可创建并写入小文件；Sol 显式通道可创建并写入
小文件；Terra 显式通道可读取两份规划文档并输出约 2.8KB 跨域分析；DeepSeek 工具
和共享文件系统也可用，但当前按用户要求停用。所有探针文件均已清理，未改仓库。

## T-20260826-002 当前状态

- 状态：`active` 但实现暂停，尚未进入 review/done。
- 集成基线：root `bd13000`；任务记录见 `docs/tasks/active/T-20260826-002.json`。
- 失败现场：`/home/chiro/projects/mycpu/lcvex-wt-T-20260826-002`，存在未提交的
  `scripts/trace_manifest.py`、`scripts/trace_slice.py` 和 smoke 草稿；不要 reset、
  删除或与新 worktree 混用。
- 旧草稿问题（来自初步评审）：未完整绑定 Image/DTB/QEMU/plugin hash；parent trace
  内容关系不够强；同路径覆盖风险；gzip CRC/截断、空切片和非法范围未收口；全局
  seq 与切片 local seq 需要明确；交付物尚不完整。
- 旧 Sol 评审消息曾出现平台加密封装，不能作为正式 acceptance；不得声称其已通过。

## 正式恢复顺序

1. 先用 Terra `[xhigh]` 在限定文档范围内完成 T-002 的复杂边界/依赖拆解（必要时）。
2. 再用 Sol `[high]` 只读审查 task JSON、指定 difftest 文档和目标 diff，输出方向性
   acceptance；不要求逐行方案。
3. 由默认 Luna `[max]` 接手同一任务的实现 worktree，完成代码、低资源 smoke、handoff
   和 evidence；不得启动 Linux 长跑。
4. 集成者在 merge SHA 上复跑 L0–L2，确认失败现场和 manifest 后再归档任务。

## 暂停边界

- 当前不修改 RTL、不修改 QEMU fork、不启动 Gate D/Linux 长跑。
- DeepSeek 不派新任务。
- 重新开始时先检查 root `git status`、T-002 worktree diff 和任务 JSON，再按上述顺序
  派发；不要把本交接中的历史计数当作新的验证证据。
