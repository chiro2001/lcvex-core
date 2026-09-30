# Handoff T-20260902-042: FP iterative DIV/SQRT finish -> slot_result cut

```text
task=T-20260902-042
state=review
base=0900dba35cae17dd174ed53260ff26d855decb3d
head=4cbc6a7fd9093009a46f11f937d17cbabd65ea00
branch=fix/T-20260902-042-fp-slotidx-slotres-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-042
sent_at=2026-09-04T04:58:00+08:00
received_at=2026-09-04T05:00:00+08:00
reported_at=2026-09-04T05:14:00+08:00
```

## 结论

针对 T-20260902-041 signoff STA 的 `sys_clk_50` setup top-1
（`fp_exec|slot_idx[2]` → `fp_exec|slot_result_r[26]`，
49 逻辑级 / 25.478 ns / -5.200 ns），在 release `FP_ITER=1`
共享标量单元中增加 **FP-P3T round6 迭代 FDIV/FSQRT 最终舍入预级**：

1. 新增 `IT_FIN` 流水状态和 `div_pre/div_pre_lo/div_pre_hi/sqrt_pre/sqrt_pre_lo/sqrt_pre_hi`
   中间寄存器（复用现有 `fp_pre_t`）。
2. 原来的 FDIV/FSQRT 在迭代完成或 special 命中时，直接由当前
   `operand_a/b` 走 `div_finish`/`sqrt_finish_iter`（含 unpack + round_pack）
   并当拍写出 `scalar_result`，拆成两拍：
   - 完成拍：只做 unpack/FZ flush、special-value 判定并捕获商/根商
     到 `div_pre*`/`sqrt_pre*`；
   - `IT_FIN` 拍：只从 `div_pre*`/`sqrt_pre*` 做最终 `finish_pre`
     round/pack，写出 `scalar_result`。
3. 覆盖：标量 S/D/H 的 FDIV、FSQRT，以及 half-lane 的
   `div_pre_lo/hi`、`sqrt_pre_lo/hi` 双 lane 路径。
4. 该切级把 T-041 top 中最后一个仍从 slot operand mux 直达
   `slot_result_r` 的迭代结果组合锥打断为两段；不增加 DSP，只增加
   少量 `fp_pre_t` 寄存器与新状态。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| `fp_exec` slot/operand mux → scalar_unit | 保持组合（未改） |
| FDIV/FSQRT 完成判断 / unpack / FZ flush / special 判定 | 完成拍 → `div_pre*` / `sqrt_pre*` |
| FDIV/FSQRT 最终 `finish_pre` round/pack | `IT_FIN` 拍 → `scalar_result` |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026，未改 |

## Latency 变化

迭代 FDIV/FSQRT 每个 scalar slot 的最终舍入增加 1 拍；
NEON 多 slot 每 slot 增加 1 拍（2S 增加 2 拍）。
其它预舍入/非迭代路径保持不变。

| 操作/格式 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar FDIV.S | 259 | 260 |
| scalar FSQRT.S | 67 | 68 |
| scalar FSQRT.D | 67 | 68 |
| scalar FSQRT.H | 68 | 69 |
| scalar FDIV.H | 516 | 517 |
| NEON FSQRT.2S | 133 | 135 |
| scalar FADD/FMUL/FMA/FCMP/FMIN/FMAX/FRINT/FCVTZS | 不变 | 不变 |
| NEON 非迭代 FADD/FMUL/FMLA/FMIN/FRINT/FCVTZS | 不变 | 不变 |

`tb/sv/lcvex_fp_exec_tb.sv` 已同步更新上述 6 个迭代延迟断言。

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- 不引入猜测执行、不改核心接口、不改提交 ABI、不加 SDC false_path。
- `div_finish_pre`/`sqrt_finish_pre` 与原有 `div_finish`/
  `sqrt_finish_iter` 使用完全相同的 unpack/FZ/special/round 规则，
  仅把最终 round_pack 延迟一拍。
- `div_pre*`/`sqrt_pre*` 与其它流水寄存器一起在 reset/kill 时清零；
  `IT_FIN` 在 `valid=0` 时回到 `IT_IDLE`，不会悬挂。
- 原 `it_h_lo_bits/it_h_lo_flags` 半精度 lane 完成缓存被替换为
  `div_pre_lo/hi`、`sqrt_pre_lo/hi` 预舍入缓存，行为等价且多一拍。

## 验证（本 worktree）

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、raw 位语义，以及更新后的 6 个迭代延迟断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS
- `git diff --check` PASS。
- 未运行 Quartus/full-FP synthesis/STA；实际 slack 改善需集成者在合并
  SHA 上按同 source/QSF/SDC 重跑 FP-P5。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260902-042-fp-slotidx-slotres-cut.md`
- `docs/tasks/evidence/T-20260902-042.json`

## 下一步

1. 集成者在合并 SHA 上按同 source/QSF/SDC 重跑 full-FP
   synthesis → fitter → signoff STA，确认
   `slot_idx -> slot_result_r` 是否离开 `sys_clk_50` setup top-10、
   `sys_clk_50` setup 是否转非负。
2. 若新 top 为 `div_pre* -> slot_result_r` 的 round/pack 子段或
   `slot_idx -> div_pre*` 的 unpack 子段，可按同样思路继续细分
   round_pack 或提前寄存 slot operand mux。
3. 保持 T-032/T-034/T-036/T-038/T-040 已切成果；不要用 SDC false_path
   掩盖同域 setup；保持 EMIF/hold/recovery/removal/min-pulse/DDR 绿色目标。
