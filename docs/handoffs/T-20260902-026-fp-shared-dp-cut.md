# Handoff T-20260902-026: FP shared datapath cut in fp_exec/scalar_unit

```text
task=T-20260902-026
state=review
base=87354542f502e1ec74971b5d63435e9590601b89
head=eed7f77debcd5b5c2e505aad0663cd545154a357
branch=feature/T-20260902-026-fp-shared-dp-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-026
sent_at=2026-09-03T13:18:30+08:00
received_at=2026-09-03T13:21:00+08:00
reported_at=2026-09-03T13:35:30+08:00
```

## 摘要

针对 T-20260902-025 的 STA 结论（`fp_exec/scalar_unit` 的
`slot_idx -> rsp_r.v_data` 仍为 `sys_clk_50` 最差 setup，834 级
/339.743 ns），本轮在发布 FP_ITER 共享 lane 路径上做两处定向切级：

1. **移除 FP_ITER 分支中的旧全组合 scalar 结果计算**。原来
   `lcvex_fp_scalar` 在 FP_ITER=1 的 always_comb 里仍对所有算术/比较/
   转换计算一遍完整组合结果（`binary_op/compare/minmax/frint/fp_to_int`
   等），即使最终从 `pp_pre/pp_other` 流水寄存器完成输出，这些旧逻辑仍
   与响应数据/控制 mux 相连，构成从 slot operand mux 到 response 的
   巨大组合锥。现在 FP_ITER 分支只保留位操作 FMOV 的组合直接通路；
   其余操作全部只从捕获后的 `pp_pre/pp_other` 完成。
2. **新增 per-slot 结果捕获寄存器**。`lcvex_fp_exec` 在 `TX_RUN` 检测到
   `slot_done` 时先把 `scalar_result/int_result/fpsr/cmp_nzcv` 冻结到
   `slot_*_r`，再进入新的 `TX_SLOT` 状态；累计器更新和 response 构造均在
   `TX_SLOT` 从这些寄存器驱动。这样把
   `slot/operand mux -> scalar datapath -> accumulator -> response mux`
   拆成两段，避免最后一个 slot 单拍聚合直接穿过共享算术/移位路径。

## 切级位置

| 原链 | 本轮边界 |
| --- | --- |
| `slot_idx` -> slot operand mux -> scalar 全组合 add/shift | FP_ITER 分支不再为已流水操作生成旧全组合结果，仅 FMOV 保留组合 |
| scalar `pp_pre/pp_other` finish -> `scalar_result` -> `acc_next` 响应 mux | `slot_done` 当拍先写入 `slot_*_r`，下一拍 `TX_SLOT` 才更新 acc/构造 `rsp` |
| 多 slot NEON 最后 slot 单拍聚合 | 每个 slot 都经过捕获+提交两拍；不再是最后一个 slot 单拍完成聚合 |
| `kill/reset/hold response` | 新寄存器随 reset/kill 清空；`rsp_valid`/held response 语义不变 |

## Latency 变化

所有非特殊路径每个 scalar slot 增加 1 个捕获拍；NEON 每个 slot 也增加
1 个捕获拍，因此 2-slot NEON 增加 2 拍。

| 操作 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar ADD/SUB/MUL/FMA/SCVTF/UCVTF/FCVT | 3 | 4 |
| scalar CMP/MINMAX/FRINT/FCVTZS/FCVTZU | 3 | 4 |
| NEON 2S/2D/2-slot 非迭代 | 5 | 7 |
| scalar FDIV.S finite | 258 | 259 |
| scalar FSQRT.S/D | 66 | 67 |
| scalar FSQRT.H | 67 | 68 |
| scalar FDIV.H | 515 | 516 |
| NEON FSQRT.2S | 131 | 133 |
| special DIV/SQRT (NaN/Inf/zero) | 3（未断言） | 3（探测保持） |

`tb/sv/lcvex_fp_exec_tb.sv` 已同步更新固定 latency 断言。

## 验证

- `make compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、标量/NEON raw、更新后的 latency 断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS
- `git diff --check` PASS。

## 保持不变的语义

- 单在途、顺序提交、held response、`req_ready` 只在 wrapper 空闲时置位。
- FPCR snapshot、FPSR sticky OR、FCMP NZCV、FP→GPR 写回、raw-bit/NaN
  payload/FZ/DN/RMode 语义未改。
- kill/reset 清空 `slot_*_r`，不会留下 ghost response。
- `lcvex_core.sv`、`lcvex_pkg.sv` 接口/提交 ABI 未改。

## 边界/风险

- 未运行 Quartus full-FP synthesis/fitter/STA；实际 Fmax/slack 需由下一轮
  FP-P5 rerun 验证。若新 top-N 落在 `pp_pre/pp_other -> finish_*` 或
  `slot_*_r -> response` 的某个子段，仍可能需要更细的 round/normalize 切级。
- 本次仅涉及 `lcvex_fp_exec`/`lcvex_fp_scalar` 发布路径；`lcvex_neon_fp`
  4-lane 参考 formatter（FP_ITER=0）未改动。
- 性能代价为所有 FP 非特殊指令 latency +1（标量）或 +N（NEON slot 数），
  属于时序优先的预期取舍，待 FP-P4/性能矩阵评估。
- EMIF↔sys 的 CDC hold/recovery 仍属 T-20260902-027 / 后续任务，不在本轮。

## 下一步

1. 集成者合并后按同一 source/QSF/SDC 重跑 FP-P4 与 FP-P5（synthesis →
   fitter → STA），观察 `sys_clk_50` 最差 setup 是否从 `fp_exec` 内部移到
   CDC/EMIF 或更深 `round_pack` 子段。
2. 若 STA 仍红，按实际 top-N 继续对 `finish_pre/round_pack` 或
   `finish_*` 做下一轮寄存器细分。
3. EMIF↔sys 灰码/复位 CDC 由独立任务 T-20260902-027 继续闭环。
