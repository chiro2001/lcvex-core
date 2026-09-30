# Handoff T-20260902-034: FP pre-round/iterative pipeline cut

```text
task=T-20260902-034
state=review
base=09452367976bef32e0518aa57e1538a80b5b97de
head=caefd9573f86f1da6bde93dc074fe90df4a8ee2b
branch=fix/T-20260902-034-fp-pre-iter-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-034
sent_at=2026-09-03T22:07:00+08:00
received_at=2026-09-03T22:07:30+08:00
reported_at=2026-09-03T22:25:21+08:00
```

## 结论

针对 T-20260902-033 STA 指出的 `sys_clk_50` setup top
（`fp_exec|req_r.kind[1]` → `scalar_unit|g_iter.pp_pre.sig[120]`，
54 逻辑级 / 28.908 ns / -8.734 ns），在发布 `FP_ITER=1` 共享标量单元的
预舍入/迭代路径上增加 **FP-P3T round3 两级预舍入切级**：

1. 新增 `IT_ARITH` 流水状态和 `fp_arith_pre_t` 中间寄存器
   `ap_pre/ap_pre_lo/ap_pre_hi`。
2. 原来的“单拍完成 unpack/FZ-flush + align/effective-add/multiply 并写入
   `pp_pre*`”的预舍入第一拍，拆成两拍：
   - 第 1 拍（`IT_IDLE` 出口）：只做 unpack、FZ flush、raw bit/format/control
     捕获，写入 `ap_pre*`；
   - 第 2 拍（`IT_ARITH`）：只从 `ap_pre*` 做 `binary_pre_parts` /
     `fma_pre_parts` / `int_to_fp_pre`，写入 `pp_pre*`；
   - 第 3 拍（`IT_PREP`）：继续原有的 `finish_pre`/round-pack 输出。
3. 该切级直接打断 T-033 路径中的 `slot/operand mux -> unpack -> align/mult ->
   `pp_pre.sig` 组合锥。`pp_pre*` 的 D 端现在由新寄存器 `ap_pre*` 驱动，
   不再由 `req_r.kind` 的同一拍组合链直达。
4. 覆盖：标量 ADD/SUB/MUL、FMA 四族、SCVTF/UCVTF，以及对应的 half-lane
   `ap_pre_lo/hi` 路径。FCVT、CMP/MINMAX/FRINT/FP→int（`pp_other` 路径）、
   FDIV/FSQRT 多周期迭代路径保持原流水结构不变。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| `fp_exec` slot/operand mux → scalar_unit | 保持组合（少量控制） |
| scalar_unit `unpack_fp` + FZ flush + 位宽/控制捕获 | 第 1 拍 → `ap_pre*` |
| ADD/SUB/MUL/FMA 的 align/effective-add/multiply，SCVTF/UCVTF 的幅值/指数准备 | 第 2 拍 → `pp_pre*` |
| `finish_pre` round/pack | 第 3 拍 → `scalar_result` |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026，未改 |

## Latency 变化

非迭代 pre-round 运算每个 scalar slot 增加 1 拍；NEON 每 slot 各增加 1 拍。

| 操作/格式 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar ADD/SUB/MUL/FMA/SCVTF/UCVTF | 4 | 5 |
| NEON 2S/2D 非迭代（FADD 等） | 7 | 9 |
| scalar FCMP/FMIN/FRINT/FCVTZS/FCVTZU | 4 | 4（未改 `pp_other` 路径） |
| NEON FRINTZ.2S 等 | 7 | 7（未改） |
| scalar FCVT | 4（未断言） | 4（未改） |
| scalar FDIV/FSQRT 迭代 | 259/67/516 等 | 不变 |

`tb/sv/lcvex_fp_exec_tb.sv` 已更新：
- FADD.S fixed latency：4 → **5**
- NEON FADD.2S fixed latency：7 → **9**

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- 不引入猜测执行、不改核心接口、不改提交 ABI、不加 SDC false_path。
- FDIV/FSQRT 多周期状态机及 kill/reset 行为未改；`ap_pre*` 在 reset/kill
  时随其它流水寄存器一起清零。
- 只增加固定 pipeline latency，并同步更新了定向延迟断言。

## 验证

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、新增 FADD/NEON FADD 延迟断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- `git diff --check` PASS。
- Cocotb P7-1/3/4/5 未在本任务运行（已用定向 `lcvex_fp_exec_tb` 与四个 SV
  raw-bit/流水测试覆盖；可由集成者按需复跑）。
- 未运行 Quartus/full-FP STA（应由集成者在合并 SHA 上重跑 FP-P5 验证实际
  slack/Fmax 收益）。

## 边界/风险

- FCVT 和 `pp_other` 路径本轮未再细分；若下一轮 STA 显示它们成为新 top，
  可按同样思路继续加 unpack/finish 或 raw capture 级。
- 性能代价为 pre-round 算术/转换 +1 拍（NEON 每 slot +1），属于时序优先的
  预期取舍，待 FP-P4/性能矩阵评估。
- 未验证 A10 综合/布局布线；实际是否闭合 `sys_clk_50` 需 FP-P5 rerun。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260902-034-fp-pre-iter-cut.md`
- `docs/tasks/evidence/T-20260902-034.json`

## 下一步

1. 集成者在合并 SHA 上按同 source/QSF/SDC 重跑 full-FP synthesis→fitter→signoff STA，
   确认 `req_r.kind -> pp_pre` 是否离开 top-N、`sys_clk_50` setup 是否转非负。
2. 若新 top 为 `ap_pre* -> pp_pre*` 或 `pp_pre* -> finish*` 的子段，继续对
   normalize/round 或乘法器输出做更细切级；若 FCVT/`pp_other` 变 top，按本轮
   两段式方案扩展。
3. 保持 T-032 的 ID/EX GPR 前递切级和 EMIF 闭合成果，不要用 SDC false_path
  掩盖同域 setup。
