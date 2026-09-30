# Handoff T-20260902-038: FP pp_other -> slot_result cut (round4)

```text
task=T-20260902-038
state=review
base=df41e8880058ddf6a826278346002691fc006ace
head=3c04893a2814f76e37f4fdab3f3e3ef452b4df86
branch=fix/T-20260902-038-fp-ppother-slotres-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-038
sent_at=2026-09-04T01:08:00+08:00
received_at=2026-09-04T01:10:00+08:00
reported_at=2026-09-04T01:31:46+08:00
```

## 结论

针对 T-20260902-037 STA 指出的 `sys_clk_50` setup top-1
（`scalar_unit|g_iter.pp_other.pa.exp2[1]` → `fp_exec|slot_result_r[13]`，
51 逻辑级 / 26.489 ns / -6.207 ns），在发布 `FP_ITER=1` 共享标量单元的
`pp_other` 路径上增加 **FP-P3T round4 第二级中间寄存器切级**：

1. 新增 `IT_OTHER` 流水状态和 `fp_other_mid_t` 中间寄存器 `ot_mid*`。
2. 原来的“第 1 拍 unpack/FZ flush → `pp_other*`，第 2 拍
   `pp_other*` 直接完成 min/max/FRINT/FP→int 的 finish”改为三拍：
   - 第 1 拍（`IT_IDLE`）：unpack/FZ flush/raw/control 捕获 → `pp_other*`；
   - 第 2 拍（`IT_OTHER`）：从 `pp_other*` 完成昂贵的比较/移位/饱和/幅值
     准备 → `ot_mid*`；
   - 第 3 拍（`IT_PREP`）：从 `ot_mid*` 只做最终选择/正规化/打包 →
     `scalar_result` / `int_result`。
3. 覆盖：标量/NEON 的 FMIN/FMAX/FMINNM/FMAXNM、FRINT、FCVTZS/FCVTZU，
   以及对应 half-lane `pp_other_lo/hi -> ot_mid_lo/hi` 路径。
   FCMP（`compare_finish_parts`）保留原来的两拍直接路径，未额外切级。
4. 该切级把 T-037 top 路径中的 `pp_other -> finish -> slot_result_r`
   大组合锥拆为两段，中间以新寄存器为边界；不增加 DSP，仅增加
   `fp_other_mid_t` 寄存器与组合逻辑。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| `fp_exec` slot/operand mux → scalar_unit | 保持组合（未改） |
| scalar_unit `unpack_fp` + FZ flush + 位宽/控制捕获 | 第 1 拍 → `pp_other*` |
| MIN/MAX/NM 比较/NaN 判定与选择决策 | 第 2 拍 → `ot_mid*` |
| FRINT 整数移位/round 控制 | 第 2 拍 → `ot_mid*` |
| FCVTZS/FCVTZU 幅值/移位/sticky/saturate 判定 | 第 2 拍 → `ot_mid*` |
| 最终 select / normalize / pack / int 值生成 | 第 3 拍 → `scalar_result`/`int_result` |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026，未改 |

## Latency 变化

非迭代 `pp_other` 运算每个 scalar slot 增加 1 拍；NEON 每个 slot 各增加 1 拍。

| 操作/格式 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar FMIN/FMAX/FMINNM/FMAXNM | 4 | 5 |
| scalar FRINT | 4 | 5 |
| scalar FCVTZS/FCVTZU | 4 | 5 |
| scalar FCMP | 4 | 4（保留原两拍路径） |
| NEON FMIN/FRINT/FCVTZS 2S（如 FRINTZ.2S） | 7 | 9 |
| scalar ADD/SUB/MUL/FMA/SCVTF/UCVTF/FCVT | 5 | 5（未改） |
| scalar FDIV/FSQRT 迭代 | 259/67/516 等 | 不变 |

`tb/sv/lcvex_fp_exec_tb.sv` 已更新：
- FMIN.S fixed latency：4 → **5**
- FMAX.S fixed latency：4 → **5**（新增，用于锁定 staged MIN/MAX 选择）
- FCVTZS.S fixed latency：4 → **5**
- NEON FRINTZ.2S fixed latency：7 → **9**

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- 不引入猜测执行、不改核心接口、不改提交 ABI、不加 SDC false_path。
- MIN/MAX、FRINT、FP→int 的中间结果路径与原先单拍 finish 使用相同
  unpack/FZ/round/saturate 规则，仅把组合链的“决策/移位”和“最终打包”
  分到两拍。
- `ot_mid*` 在 reset/kill 时与其它流水寄存器一起清零；`valid=0` 时
  `IT_OTHER` 会回到 `IT_IDLE`，不会悬挂。

## 验证（本 worktree）

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、raw 位语义，以及更新后的 FMIN/FMAX/FCVTZS/FRINTZ 延迟断言）。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS（首轮曾暴露 staged FMAX 选择 bug，修复后全绿）
- `git diff --check` PASS。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260902-038-fp-ppother-slotres-cut.md`
- `docs/tasks/evidence/T-20260902-038.json`

## 下一步

1. 集成者在合并 SHA 上按同 source/QSF/SDC 重跑 full-FP
   synthesis → fitter → signoff STA，确认
   `pp_other -> slot_result_r` 是否离开 top-N、`sys_clk_50` setup 是否转非负。
2. 若新 top 落于 `pp_other -> ot_mid` 或 `ot_mid -> slot_result` 的子段，
   可按同样思路继续细分（如 FRINT 的移位/sticky、MIN/MAX 的 256-bit 比较）。
3. 保持 T-032/T-034/T-036 已切成果；不要用 SDC false_path 掩盖同域 setup。
