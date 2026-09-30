# T-20260829-082 B2a FP/ASIMD 算术闭合 handoff

- 状态：review
- 任务 ID：T-20260829-082（B2a FP/ASIMD 算术）
- base SHA：`def2c4baa69706d64f674f7551bf21df5d670a48`
- head SHA：`5a2662aab5c4381eaa5c439d822c23ad5447ad24`
- 分支：`feature/T-20260829-082-b2a-fp-arithmetic`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-082`
- sent_at：2026-08-29T02:52:00+0800
- received_at：2026-08-29T03:00:00+0800
- reported_at：2026-08-29T03:50:00+0800

## 交付物

| 文件 | 说明 |
| --- | --- |
| `rtl/lcvex_fp_scalar.sv` | 把 fused multiply-add 数据路径泛化到 `FMT_HALF`，使标量 H FMADD/FMSUB/FNMADD/FNMSUB 使用与 S/D 相同的 raw-bit/NaN/舍入/FPSR 规则 |
| `rtl/lcvex_decode.sv` | 标量 FMA 的 `esz=11`（FP16）接入；NEON three-same 增加 4H/8H `FMLA/FMLS` 编码 |
| `rtl/lcvex_neon_fp.sv` | 注释更新：向量 H FMLA/FMLS 接入，向量 H FCVT/FCMGE/FCMGT 等仍 UDEF |
| `tb/sv/lcvex_fp_scalar_p7_5_tb.sv` | 新增标量 H FMA 四族 raw-bit 定向向量（含 SNaN、0*Inf、signed zero） |
| `tb/sv/lcvex_neon_fp_p7_5_tb.sv` | 新增 4H FMLA/FMLS raw-bit 定向向量 |
| `sim/cocotb/test_p7_5_fp16_sqrt_minmax_round.py` | 新增 pipeline 级测试 `test_b2a_h_fma`（标量四族 + 4H FMLA/FMLS） |
| `tb/sv/lcvex_b1_decode_tb.sv` | 增加 H FMA/H FMLA/FMLS 解码定向断言 |
| `docs/handoffs/T-20260829-082-b2a-fp-arithmetic.md` | 本 handoff |
| `docs/tasks/evidence/T-20260829-082.json` | 证据 JSON |

## 实现摘要

- 标量 FP16 FMA 四族：
  - decoder 允许 `insn[31:24]==0x1f && esz=11`，与 S/D 共用同一
    `FP_OP_FMADD/FMSUB/FNMADD/FNMSUB` 和 `fp_wb_we`/FPEN/commit 路径。
  - `lcvex_fp_scalar.fma_op` 改为按 `fp_fmt_t` 选择 HALF/SINGLE/DOUBLE，
    `with_sign` 支持半精度符号位；`half_lane_calc` 增加 FMA 分派。
  - 标量 H 架构写回仍由既有 core 只取低 16 位，因此模块内 32-bit 槽的
    高 half 仅为向量复用，不作为标量架构状态。
- NEON 4H/8H FMLA/FMLS：
  - decoder 在 three-same 族中接入 `0x0E400C00/0x0EC00C00` 编码（Q 位选定
    4H/8H），并正确设置 `neon_fp_ra_en` 和 `neon_fp_operand_c = Vd`。
  - `lcvex_neon_fp` 复用 scalar H FMA lane 计算，4 个 scalar lane 各处理
    一个 32-bit 槽内两个 16-bit lane，FPSR 按 OR 合并。
- 保留约束：
  - raw-bit NaN（SNaN quiet + IOC、QNaN payload、default NaN）、signed zero、
    FPCR.FZ16/DN/RMode、FPSR sticky、FPEN trap 和单 commit 单 V effect 边界
    均未改变；没有修改 `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv`、filelist
    或 QEMU fork。
  - 仍保持 UDEF：标量 FMA `esz=10`、向量 H FCVT、FCMGE/FCMGT、由-element
    FMA、定点向量转换、复杂向量访存/SVE/完整 FP 异常 trap。

## 已执行校验

```text
# 标量 raw-bit L1：通过
conda run --no-capture-output -n lcvex verilator --binary --timing --assert -Wall -j 6 \
  --top-module lcvex_fp_scalar_p7_5_tb -Mdir obj_dir_fp_p7_5 -o lcvex_fp_scalar_p7_5_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_p7_5_tb.sv
./obj_dir_fp_p7_5/lcvex_fp_scalar_p7_5_tb
# PASS：H FMA 四族、SNaN + IOC、0*Inf default NaN、signed zero。

# 解码器 L1：通过
conda run --no-capture-output -n lcvex verilator --binary --timing --assert -Wall -j 6 \
  --top-module lcvex_b1_decode_tb -Mdir obj_dir_b1_decode -o lcvex_b1_decode_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv tb/sv/lcvex_b1_decode_tb.sv
./obj_dir_b1_decode/lcvex_b1_decode_tb
# PASS：标量 H FMA 与 4H FMLA/FMLS 解码断言。

# P7-4 标量 FMA/转换回归：通过
conda run --no-capture-output -n lcvex verilator --binary --timing --assert -Wall -j 6 \
  --top-module lcvex_fp_scalar_p7_4_tb -Mdir obj_dir_fp_p7_4 -o lcvex_fp_scalar_p7_4_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv tb/sv/lcvex_fp_scalar_p7_4_tb.sv
./obj_dir_fp_p7_4/lcvex_fp_scalar_p7_4_tb
# PASS：S/D FMA、转换、NaN/舍入/FZ 全部回归通过。

python3 -m py_compile sim/cocotb/test_p7_5_fp16_sqrt_minmax_round.py
git diff --check
```

## 阻断 / 不适用

- 无实现层面阻断。
- 向量 H FMLA/FMLS 的 raw-unit 与 cocotb 核心级用例已加入，但本环境完整
  `lcvex_neon_fp_p7_5_tb` Verilator 编译因资源/时长未能在本轮完成一次运行；
  需集成者或主机排空后在资源充分环境复跑。
- 未修改 `docs/V82_PROFILE_MANIFEST.md`（不在本任务允许写集）；`EXT-FP-007`
  /`EXT-NEON-FP-002` 的 FP16 扩展由集成者确认后补记。
- 未执行 QEMU strict lockstep（L2）和 Gate D（L3）；本次交付为 owner L1 raw
  unit 与已添加的 pipeline 用例。

## 下一步

1. 集成者在资源充分环境复跑 `sim-sv-p7-5-fp16-sqrt-minmax-round` 和
   `sim-cocotb-p7-5-fp16-sqrt-minmax-round`，确认标量/向量 H FMA 与既有 P7-5
   回归全绿。
2. 若具备 L2 条件，补充 A76 required 的 H FMA 定向锁步并归档。
3. 由集成者更新 manifest/任务状态，把 FP16 FMA 纳入对应 V82-SELECTED-EXT 行。
