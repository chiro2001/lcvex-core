# Handoff T-20260902-020: FP-P3T fp_exec/scalar_unit Register Cuts

```text
task=T-20260902-020
state=review
base=87e7e0b047e1e80bd2f1f192fd3f1dbf3b2bd4be
head=c60306f3bf1f218b8feca86c4e935d1a3a664385
branch=feature/T-20260902-020-fp-p3t-register-cuts
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-020
sent_at=2026-09-03T07:03:00+08:00
received_at=2026-09-03T07:04:00+08:00
reported_at=2026-09-03T07:27:00+08:00
```

## 摘要

针对 T-20260902-019 STA 报告的 `fp_exec/scalar_unit` 组合关键路径
（`req_r.is_double` → `rsp_r.v_data[84]`，data delay 339.36 ns），在
`lcvex_fp_scalar#(FP_ITER=1)` 的发布路径增加 **pre-round + round/pack
两拍寄存器切级**：

1. 新增 `fp_pre_t` 中间量，保存精确幅值/指数/符号/特殊值结果与输入 flags。
2. ADD/SUB/MUL、FMADD/FMSUB/FNMADD/FNMSUB、SCVTF/UCVTF、FCVT 的有限路径
   先在第一拍完成 unpack/align/effective-add/shift/compare，把 `round_pack`
   推迟到第二拍；特殊值（NaN/Inf/zero）在 pre 阶段解析并锁存。
3. 半精度 32-bit 槽的两个 16-bit lane 分别使用 `pp_pre_lo/pp_pre_hi`，
   在第二拍完成两个 lane 的 round/pack 与合并，保持 H raw-bit 打包不变。
4. 迭代 FDIV/FSQRT 仍走原多周期状态机，不改变复位/kill/held-response/
   FPCR snapshot/单在途语义；`lcvex_fp_exec` 槽推进仍统一由
   `scalar_iter_done` 驱动。

发布结构仍为 `lcvex_core → lcvex_fp_exec → 1× lcvex_fp_scalar#(FP_ITER=1)`，
没有引入多 transaction、没有改变写回/提交顺序、没有修改 decode/FPEN。

## 切级位置

- `unpack/classify + align/effective-add/shift/compare` → `pp_pre*` 寄存器
- `round_pack + half-pair merge + scalar/NEON result formatting` → 下一拍输出
- 保持 `iter_busy/iter_done` 契约，`kill`/`reset` 同时清空 `pp_pre*`。

## Latency 表更新

| 操作/格式 | 变更前 | 变更后 | 说明 |
| --- | ---: | ---: | --- |
| scalar ADD/SUB/MUL/FMA/SCVTF/UCVTF/FCVT | 2 | 3 | pre-round 1 拍 + round/pack 1 拍 + wrapper 1 拍 |
| NEON 2S/2D 非迭代（每个 slot 均 pre-round） | 3 | 5 | 每 slot 增加 1 拍 |
| NEON 4S/8H 非迭代 | 5 | 9 | 按 4 slot 推得（未单独锁定） |
| scalar FDIV.S/D finite | 258 | 258 | 不变 |
| scalar FDIV.H | 515 | 515 | 不变 |
| scalar FSQRT.S/D | 66 | 66 | 不变 |
| scalar FSQRT.H | 67 | 67 | 不变 |
| NEON FSQRT.2S | 131 | 131 | 不变 |
| special DIV/SQRT | 2 | 2 | 不变 |

`tb/sv/lcvex_fp_exec_tb.sv` 固定检查已更新：
- FADD.S：2 → **3**
- NEON FADD.2S：3 → **5**

## 验证

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（含单在途、held response、
  kill/reset、FDIV/FSQRT 迭代、latency fatal 断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- `make VERILATOR_JOBS=1 sim-sv` PASS（core scalar + FPCR/FPSR smoke）。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS
- `git diff --check` PASS。
- A76 required lockstep L2 子集未在本任务运行；Cocotb 已覆盖 P7-1/3/4/5
  流水线、FPEN、backpressure、UDEF。

## 边界/风险

- 未运行 Quartus synthesis/fit/STA（由后续 FP-P5 rerun 验证实际时序收益）。
- 当前切级覆盖使用 `round_pack` 的主要算术/转换路径；CMP/MIN/MAX/FRINT/
  FCVTZS/FCVTZU 仍保持原组合路径，若后续 STA 显示这些路径成为新的 top-N，
  需要进一步切级。
- 只允许写集内文件有改动：`rtl/lcvex_fp_scalar.sv`,
  `tb/sv/lcvex_fp_exec_tb.sv`，本次未改 `lcvex_core.sv`/package。

## 下一步

1. 集成者复跑/合并后，按同一 source/QSF/SDC 基线重跑 FP-P4 功能/性能与
   FP-P5 synthesis → fitter → signoff STA。
2. 根据 STA top-N 决定是否继续对 CMP/MINMAX/FRINT 或迭代器 finalize 再切级。
