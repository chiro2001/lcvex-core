# Handoff T-20260902-044: FP iterative DIV/SQRT div_pre/sqrt_pre -> slot_result cut (round_pack leading-one predecode)

```text
task=T-20260902-044
state=review
base=cf0414c0cc2e5ec8dc9a07fc8333826268cb0f94
head=e57780aef322f5df2b9fb1330baf552e8485c785
branch=fix/T-20260902-044-fp-divpre-slotres-cut2
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-044
sent_at=2026-09-04T06:35:00+08:00
received_at=2026-09-04T06:38:00+08:00
reported_at=2026-09-04T06:50:02+08:00
```

## 结论

- 针对 T-20260902-043 signoff STA 的 `sys_clk_50` setup top-1
  `scalar_unit|g_iter.div_pre.sig[245] -> fp_exec|slot_result_r[9]`
  （54 逻辑级 / 25.589 ns / -5.047 ns），在 release `FP_ITER=1`
  共享标量单元的迭代 FDIV/FSQRT 最终 `round_pack` 内部再切一级：
  **将 256-bit 最高有效位 leading-one 预解码提前到 `div_finish_pre` /
  `sqrt_finish_pre` 捕获拍**，并让 `IT_FIN` 只使用已寄存的 leading-one
  索引完成移位/舍入/打包。
- 该改动不新增流水状态、不增加 FDIV/FSQRT 延迟，不改 FP/NEON raw-bit、
  FPCR snapshot、FPSR OR、FCMP NZCV、FP→GPR、单在途/顺序提交/hold response。
- 不增加 DSP；只在 `fp_pre_t` 增加 `lead[7:0]` 与 `lead_valid` 两个字段
  （约 9 bit/instance），并复用原有 round_pack 组合逻辑。没有用 SDC
  false_path 掩盖。
- 本 worktree 完成 L0/L1 本地验证：Verilator 编译、`lcvex_fp_exec_tb`、
  四个 SV 套件、四个 Cocotb 套件全绿。未运行 Quartus full-FP
  synthesis/fitter/STA（需集成者在合并 SHA 按同 QSF/SDC 重跑）。

## 切级位置

| 路径段 | 本轮边界 |
| --- | --- |
| 迭代 DIV/SQRT 完成判断 / unpack / FZ flush / special 判定 | 完成拍 → `div_pre*` / `sqrt_pre*`（沿用 T-042） |
| **256-bit sig 最高有效位 leading-one 查找** | **完成拍与 `div_pre*`/`sqrt_pre*` 同拍预解码 → `fp_pre_t.lead`** |
| 最终 `round_pack` 的 shift/round/overflow/subnormal/pack | `IT_FIN` 拍从已寄存 `lead` 开始 → `scalar_result` |
| `slot_*_r` 结果捕获/响应 | 沿用 T-026 |

具体实现：

1. `fp_pre_t` 增加 `logic [7:0] lead` 和 `logic lead_valid`。
2. `div_finish_pre` / `sqrt_finish_pre` 在非 special 有限分支计算
   `lead = leading_one_index(sig)`；若 sig 全零则 `lead_valid=0`，
   保持原有 zero 语义。
3. 把原 `round_pack` 拆成：
   - `round_pack_h`：接收已预解码的 `h_in/h_valid`，执行原有的
     shift/round/overflow/subnormal/pack；
   - `round_pack`：保持公共入口，先做 leading-one 查找再调 `round_pack_h`，
     所有非迭代路径行为完全不变。
4. `finish_pre` 对 `pre.lead_valid` 的 `fp_pre_t` 直接调用 `round_pack_h`，
   从而避免在 `div_pre.sig -> slot_result_r` 的长锥内重新跑 256-bit
   priority scan。

## Latency 变化

无变化。迭代 FDIV/FSQRT 的完成拍已经捕获 `div_pre*`/`sqrt_pre*`；
leading-one 预解码与该捕获同拍完成，不增加额外周期。

| 操作/格式 | T-042 后 | 本任务后 |
| --- | ---: | ---: |
| scalar FDIV.S | 260 | 260 |
| scalar FSQRT.S | 68 | 68 |
| scalar FSQRT.D | 68 | 68 |
| scalar FSQRT.H | 69 | 69 |
| scalar FDIV.H | 517 | 517 |
| NEON FSQRT.2S | 135 | 135 |
| 其它非迭代路径 | 不变 | 不变 |

## 语义保持

- FP/NEON raw-bit 编码、NaN payload/quieting、FZ/DN/RMode、FPCR snapshot、
  FPSR sticky OR、FCMP NZCV、FP→GPR 写回、单在途/顺序提交/hold response
  均未改变。
- `round_pack_h` 是原 `round_pack` 的逐行等价体，只是 leading-one 由
  已寄存索引提供；`round_pack` 公共入口仍对所有旧调用执行原查找。
- `lead_valid=0`（零 sig 或非迭代预舍入）时仍走原 `round_pack`，不改变
  特殊值、subnormal、overflow、flush 行为。
- 不引入猜测执行；不修改核心接口/ABI；不加 SDC false_path。

## 资源/PPA 预估

- 不新增 DSP、不新增流水状态、不新增大的 256-bit 寄存器。
- 每个 `fp_pre_t` 实例增加 9 bit 存储；该结构已有多个流水实例，预计寄存器
  增加为个位数到低两位数级别，远小于 T-042 已增加的 1,373 regs。
- 组合逻辑 net 变化：把迭代路径的 leading-one priority scan 从
  `IT_FIN -> slot_result` 移到完成拍 `div_finish_pre -> div_pre` 捕获端；
  总逻辑量相近，切断的是 STA 报告的 54 级路径。

## 验证（本 worktree）

- `make VERILATOR_JOBS=1 compile` PASS。
- 直接 Verilator `lcvex_fp_exec_tb` PASS（单在途、held response、kill/reset、
  FDIV/FSQRT 迭代、raw 位语义；延迟仍为 260/68/68/69/517/135）。
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
- `docs/handoffs/T-20260902-044-fp-divpre-slotres-cut2.md`
- `docs/tasks/evidence/T-20260902-044.json`

## 下一步

1. 集成者在合并 SHA 上重跑 full-FP synthesis → fitter → signoff STA，
   确认 `div_pre.sig -> slot_result_r` 是否离开 `sys_clk_50` setup top-10，
   setup TNS/Fmax 是否改善。
2. 若新 top 为完成拍 `it_div_q -> div_pre.lead` 的 priority scan 或
   `div_pre.sig -> round_pack_h` 的 shift/round 子段，可继续在该子段
   再切寄存器。
3. 保持 T-032/T-034/T-036/T-038/T-040/T-042 已切成果；不要用 SDC
   false_path 掩盖；保持 EMIF/hold/recovery/removal/min-pulse/DDR 绿色目标。
