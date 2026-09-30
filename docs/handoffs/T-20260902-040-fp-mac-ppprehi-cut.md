# Handoff T-20260902-040: FP scalar DSP MAC -> pp_pre_hi product-register cut

```text
task=T-20260902-040
state=review
base=5315bbb61a7614406b2f8e1b72b72edcbf087dfa
head=f280d048943ad0bff8764106ea9f276500825c10
branch=fix/T-20260902-040-fp-mac-ppprehi-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-040
sent_at=2026-09-04T03:06:00+08:00
received_at=2026-09-04T03:07:00+08:00
reported_at=2026-09-04T03:24:16+08:00
```

## 结论

针对 T-20260902-039 STA 指出的 `sys_clk_50` setup top-1
（`scalar_unit|mult_1~mac_11~reg0` →
`scalar_unit|g_iter.pp_pre_hi.sig[153]`，62 逻辑级 / 27.811 ns /
-7.685 ns，top-2..10 为同源 `pp_pre_hi.sig[*]` 路径），在 release
`FP_ITER=1` 共享标量单元中增加 **FP-P3T round5 乘法器乘积级**：

1. 新增 `IT_MUL` 流水状态和 `pm_pre/pm_pre_lo/pm_pre_hi` 中间寄存器。
2. 原来的 MUL/FMA pre-round 第 2 拍（`IT_ARITH`）直接完成
   `fma_pre_parts`/`binary_pre_parts` 并写入 `pp_pre*`，拆成两拍：
   - `IT_ARITH`：只捕获 DSP 乘法器输出（`product`、乘积符号、乘积指数）
     → `pm_pre*`；
   - `IT_MUL`：从 `pm_pre*` 和仍然有效的 `ap_pre*` 完成 FMA 的
     align/add 或 MUL 的最终 pre-round 打包 → `pp_pre*`；
   - `IT_PREP`：继续原有的 `finish_pre`/round-pack 输出。
3. 该切级直接打断 T-039 路径中 DSP MAC 输出 → `pp_pre_hi.sig[*]`
   的 `product_ext/c_ext/magnitude` 组合锥。ADD/SUB/SCVTF/UCVTF
   保持原有两拍预舍入链路不变。
4. 覆盖：标量/NEON half-lane 的 `FP_OP_MUL` 与 FMADD/FMSUB/FNMADD/FNMSUB，
   以及对应 `pp_pre_lo/hi` 路径。不增加 DSP，只增加乘积中间寄存器与
   新状态。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| `fp_exec` slot/operand mux → scalar_unit | 保持组合（未改） |
| scalar_unit `unpack_fp` + FZ flush + 位宽/控制捕获 | 第 1 拍 → `ap_pre*` |
| MUL/FMA DSP 乘法器输出（product/sign/exp2） | 第 2 拍 → `pm_pre*` |
| FMA align/add、MUL 最终 pre-round 打包 | 第 3 拍 → `pp_pre*` |
| `finish_pre` round/pack | 第 4 拍 → `scalar_result` |
| ADD/SUB/SCVTF/UCVTF | 仍按原第 2 拍直接写 `pp_pre*` |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026，未改 |

## Latency 变化

仅 MUL/FMA 及其 NEON/half-lane 版本每个 scalar slot 增加 1 拍；
ADD/SUB/SCVTF/UCVTF、FCVT、CMP/minmax/FRINT/FP->int、FDIV/FSQRT
不变。

| 操作/格式 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar FMUL | 5 | 6 |
| scalar FMADD/FMSUB/FNMADD/FNMSUB | 5 | 6 |
| NEON FMUL.2S | 10 | 11 |
| NEON FMLA/FMLS | 每 slot +1 | 每 slot +1 |
| scalar FADD/FSUB/SCVTF/UCVTF | 5 | 5 |
| NEON FADD.2S | 9 | 9 |
| scalar CMP/MINMAX/FRINT/FCVTZS/FCVTZU | 4/5/5/5 | 不变 |
| scalar FDIV/FSQRT 迭代 | 259/67/516 等 | 不变 |

`tb/sv/lcvex_fp_exec_tb.sv` 已更新：
- 新增 `FMUL.S` latency = 6 断言。
- 新增 `FMADD.S` latency = 6 断言。
- 新增 `NEON FMUL.2S` latency = 11 断言。
- 原有 FADD.S=5、NEON FADD.2S=9 等保持不变。

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- 不引入猜测执行、不改核心接口、不改提交 ABI、不加 SDC false_path。
- MUL/FMA 的 special-value 处理仍从 `ap_pre*` 的已解包/FZ-flush 操作数
  按原规则完成；只有乘法器本身从最终 pre-round 组合锥移到 `pm_pre*`。
- `pm_pre*` 在 reset/kill 时与其它流水寄存器一起清零；`valid=0` 时
  `IT_MUL` 会回到 `IT_IDLE`，不会悬挂。
- ADD/SUB/SCVTF/UCVTF 的流水级数和结果路径未变，确保 T-034/T-038 已切
  成果不回退。

## 验证（本 worktree）

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、raw 位语义，以及新增 FMUL/FMADD/NEON FMUL 延迟断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS
- `git diff --check` PASS。
- 未运行 Quartus/full-FP synthesis/STA；实际 Fmax/slack 需集成者在合并
  SHA 上重跑 FP-P5。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260902-040-fp-mac-ppprehi-cut.md`
- `docs/tasks/evidence/T-20260902-040.json`

## 下一步

1. 集成者按同 source/QSF/SDC 重跑 full-FP synthesis→fitter→signoff STA，
   确认 `mult_1~mac_11~reg0 -> pp_pre_hi` 是否离开 setup top-N、
   `sys_clk_50` setup 是否转非负。
2. 若新 top 为 `pm_pre* -> pp_pre*` 的对齐/加法子段或 `ap_pre* -> pm_pre*`
   的 DSP 输入段，可继续按同样思路在 `product_ext/c_ext` 或加法器前再切一级。
3. 保持 T-032/T-034/T-036/T-038 已切成果，不要用 SDC false_path 掩盖同域
   setup；保持 EMIF/hold/recovery/removal/min-pulse/DDR 绿色目标。
