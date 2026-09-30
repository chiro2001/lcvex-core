# LCVEX 性能增强路线图（浓缩版）

> 来源：`docs/PERFORMANCE_ENHANCEMENT_FINAL_PLAN.md`（T-20260830-035 综合）
> 性质：规划；未实施任何性能增强，未启动 Quartus。

## Top 优先级

1. **P0 F0 测量闭环 + 缓存矩阵**：先建立 nocache / L1 / L1+L2 / delay 矩阵与 IPC/stall/cache/总线计数。
2. **P0 F1 前端取指 FIFO、早取、critical-word-first**：隐藏取指延迟，降低分支/循环气泡。
3. **P1 F3 受限 outstanding / MSHR / store buffer**：2-entry、按序提交，隐藏访存延迟。
4. **P1 F5 共享 L2 数据阵列 + probe 并行**：解决多核目录-only / 全局单事务 / 串行 probe。
5. **P1 F7 总线 line burst / 多 ID**：把 8×8B 串行 beat 变成 burst，提升 EMIF/DDR 带宽。

## 方向优先级表

| ID | 方向 | 优先级 | 依赖 | 状态 |
|---|---|---|---|---|
| F0 | 性能计数与缓存配置矩阵 | P0 | 无 | 规划 |
| F1 | 取指 FIFO / early restart / critical-word-first | P0 | F0 | 规划 |
| F2 | BTB / 方向预测 / RAS | P1 | F1 | 规划 |
| F3 | 受限 outstanding / MSHR / store buffer | P1 | F0；与 F1 串行合入 | 规划 |
| F4 | refill / writeback / 数据阵列服务 | P1 | F0、F3 | 规划 |
| F5 | 共享 L2 数据阵列 / 目录 / probe 并行 | P1 | C2/C3 关闭、F3、F0 | 规划 |
| F6 | 仲裁 / backpressure / 维护异常 QoS | P0/P1 | F0 | 规划 |
| F7 | 总线 line packet / 突发 / 多 ID | P1/P2 | F0、F3、F4 | 规划 |
| F8 | 多 bank / 更宽 line / 预取 | P2 | F0、F3、F7、FPGA | 规划 |
| F9 | 更深流水线 | P2 | F1、F3、STA | 规划 |
| F10 | 顺序 2-wide | P2 | F1、F3、F6、提交协议 | 规划 |

## 实施 DAG

```text
F0 (测量)
 ├─→ F1 (前端) → F2 (分支预测)
 ├─→ F3 (MSHR/store) → F4 (refill/writeback)
 │                 └─→ F5 (共享L2/probe) → F7 (总线/多ID)
 └─→ F6 (仲裁/backpressure)
                         └─→ F8 (bank/宽行/预取)
                         └─→ F9 (深流水，需STA)
                         └─→ F10 (2-wide，需提交协议)
```

关键串行点：
- F1 与 F3 都改 `lcvex_core.sv`，可并行设计但合入必须串行。
- F2 必须等 F1 的取指 epoch/flush 稳定。
- F5 必须等 C2/C3 正确性关闭和 F3 事务 ID。
- F7 必须等 F3 和 F4。
- F9/F10 必须等前端、访存和提交协议基础，并由 STA/ILP 数据驱动。

## P-line 对应重点

- F0/F3/F4/F7 → `mem_seq`、`mem_random`、`mem_ldst`、`kernel_matmul/sort/hash/crc`
- F1/F2 → `ctrl_branch`、`alu_latency`、`alu_ilp`、`kernel_*`
- F10 → `alu_ilp`、`fp_scalar`、`fp_fp16`、`neon_vect`
- F5/F7 → 未来多核 P-MC（mailbox、reduction、ping-pong、barrier）

## 合入前必须

- 复跑 F0 无优化基线，记录 source/image/tool SHA。
- 每个 RTL 改动默认开关关闭，保留旧路径。
- 按 L0→L1→L2→L3 验证，确保架构状态只在 commit 更新、事务 ID 精确配对、CORE_COUNT=1 与 C2/C3 不回归。
- 不宣称未实现收益。
