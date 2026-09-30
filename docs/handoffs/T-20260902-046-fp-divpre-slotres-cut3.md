# Handoff T-20260902-046: FP iterative DIV/SQRT round_pack two-stage cut (round_pack split)

```text
task=T-20260902-046
state=review
base=f93bf7cde667065022b23110a32a88215ba09300
head=3f4a4c22a9dcf59fe307ea67cbc736e61c1b7488
branch=fix/T-20260902-046-fp-divpre-slotres-cut3
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-046
sent_at=2026-09-04T08:09:00+08:00
received_at=2026-09-04T08:09:30+08:00
reported_at=2026-09-04T08:29:52+08:00
```

## 结论

- 针对 T-20260902-045 signoff STA 新的 `sys_clk_50` setup top
  `scalar_unit|g_iter.div_pre.sig[253] -> fp_exec|slot_result_r[36]`
  （54 逻辑级 / 24.240 ns / -4.026 ns），在保留 T-044
  leading-one 预解码成果的基础上，把迭代 FDIV/FSQRT 的最终
  `round_pack` **真正拆成两拍**，而不是只把最终结果后移一拍：
  - 第一拍（IT_FIN first half）：从 `div_pre/sqrt_pre` 的已寄存
    `sig/lead` 计算移位后的有效数 `mant`、guard/sticky、discarded
    以及 special 旁路，写入新的 `fp_round_mid_t` 中间寄存器；
  - 第二拍（IT_FIN second half）：从中间寄存器完成增量舍入、进位、
    溢出/subnormal/FZ 判定与最终打包，再交给 scalar_result /
    `slot_result_r` 捕获。
- 因此原来 `div_pre.sig -> slot_result_r` 的单一 54 级组合锥在
  `it_fin_mid_*` 处被切开；路径变为：
  - `div_pre.sig -> it_fin_mid_*`（第一段：宽移位/GRS）
  - `it_fin_mid_* -> scalar_result -> slot_result_r`（第二段：
    增量/溢出/打包）
- 迭代 FDIV/FSQRT 固定流水延迟 +1；非迭代路径、FDIV/FSQRT 迭代次数、
  FP/NEON raw-bit、FPCR snapshot、FPSR OR、FCMP NZCV、FP→GPR、
  单在途/顺序提交/hold response 均不变。
- 未使用 SDC false_path；未引入猜测执行；未改变 FP 模式/FZ/DN/RMode。
- 本任务未实现“共享 leading-one 扫描”面积优化；p1/p2 不新增 256-bit
  priority scan，仍沿用 T-044 已预解码的 `lead`，共享扫描留作后续
  面积专项评估。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| 迭代 DIV/SQRT 完成 / unpack / FZ flush / special 判定 | 完成拍 → `div_pre*` / `sqrt_pre*`（沿用 T-042/T-044） |
| 256-bit sig 最高有效位 leading-one 查找 | `div_pre*`/`sqrt_pre*` 捕获拍预解码（沿用 T-044） |
| **round_pack 第一半：移位、mant、guard/sticky/discarded** | **本任务新增 `it_fin_mid_*` 捕获拍** |
| **round_pack 第二半：inc、carry、overflow/subnormal/FZ/pack** | **本任务新增 IT_FIN 第二拍 → scalar_result** |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026 |

## 实现摘要

1. 新增 `fp_round_mid_t` packed 中间结构：包含 special 旁路、
   `is_zero/is_tiny/sign`、256-bit `mant`、`guard/sticky/discarded`、
   指数 `e`、fmt/flush_zero/rmode/ahp 与 `input_flags`。
2. 新增 `round_pack_p1(fp_pre_t)`：对有限非零结果把 `round_pack_h`
   中依赖 256-bit `sig` 的移位/GRS 计算提前到中间级；
   special 直接旁路。
3. 新增 `round_pack_p2(fp_round_mid_t)`：完成 `round_increment`、
   256-bit 增 1 进位、normal overflow、tiny/q_high、FZ flush、
   最终位打包与 flag 生成；行为逐项对照原 `round_pack_h`。
4. `g_iter` 增加 `it_fin_mid_r`（S/D）、`it_fin_mid_lo/hi`（H lane）
   与 `it_fin_valid_r`；`IT_FIN` 停留两拍：
   - 第一拍只做 p1 并置 `it_fin_valid_r`；
   - 第二拍做 p2，`iter_done=1`，回 IDLE。
5. `lcvex_fp_exec_tb.sv` 的迭代延迟表同步 +1/+2，并更新注释说明
   round8 两阶段结果管级。

## Latency 变化

| 操作/格式 | T-044 后 | 本任务后 |
| --- | ---: | ---: |
| scalar FDIV.S | 260 | 261 |
| scalar FSQRT.S | 68 | 69 |
| scalar FSQRT.D | 68 | 69 |
| scalar FSQRT.H | 69 | 70 |
| scalar FDIV.H | 517 | 518 |
| NEON FSQRT.2S | 135 | 137 |
| 其它非迭代路径 | 不变 | 不变 |

注：NEON FSQRT.2S 是 2 个 scalar slot，每 slot 的迭代 round_pack
多一拍，因此 +2。

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- `round_pack_p1/p2` 合并后与原 `round_pack_h` 的
  normal/tiny/special/overflow/subnormal/FZ 行为逐项等价；
  p2 最后仍 OR `input_flags`，与原 `finish_pre` 一致。
- 不新增 256-bit priority scan；不新增 DSP；不修改核心接口/ABI；
  不加 SDC false_path。

## 资源/PPA 预估

- 新增 3 个 `fp_round_mid_t` 寄存器（约 260 bit 有效数 + 元数据），
  `g_iter` 寄存器和少量面积增加；未新增 DSP。
- 未做 T-045 建议的“非迭代 round_pack 公共入口与迭代 round_pack_h
  共享 leading-one 扫描”面积优化；该优化风险较高，建议由集成者在
  实际 Quartus 资源数据出现瓶颈时单独评估。
- 本次切级是否足以使 `sys_clk_50` setup 全绿仍需集成者在合并 SHA 上
  按同 source/QSF/SDC 重跑 full-FP synthesis → fitter → signoff STA 确认。

## 验证（本 worktree）

- `make compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS：单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、raw 位语义、延迟表全部通过；
  实测 FDIV.S=261、FSQRT.S=69、FSQRT.D=69、FSQRT.H=70、
  FDIV.H=518、NEON FSQRT.2S=137。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar sim-sv-p7-3-neon-fp sim-sv-p7-4-fma-convert sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb：
  - `sim-cocotb-fp-scalar` 5/5 PASS
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS
- `git diff --check` PASS。
- 未运行 Quartus/full-FP synthesis/STA；实际 slack/资源需集成者在合并 SHA
  上按同 source/QSF/SDC 重跑 FP-P5。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260902-046-fp-divpre-slotres-cut3.md`
- `docs/tasks/evidence/T-20260902-046.json`

## 下一步

1. 集成者在合并 SHA 上重跑 full-FP synthesis → fitter → signoff STA，
   确认 `div_pre.sig -> slot_result_r` 是否离开 `sys_clk_50` setup top-10，
   setup TNS/Fmax 是否改善。
2. 若新 top 为 `div_pre.sig -> it_fin_mid_*` 的宽移位/GRS 子段，可继续在
   该子段再切；若为 `it_fin_mid_* -> slot_result_r` 的增量/打包子段，
   本任务已经切断原目标。
3. 如资源仍紧张，再评估共享 leading-one 扫描；不要回退 T-032/034/036/038/
   040/042/044/046 已切成果；不要用 SDC false_path 掩盖同域 setup。
