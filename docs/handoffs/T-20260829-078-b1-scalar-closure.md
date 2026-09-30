# T-20260829-078 B1 标量/解码闭合 handoff

- 状态：review
- 任务 ID：T-20260829-078（B1）
- base SHA：`3d717e763209923f5ddaedeeeafa9d0b9985ba6c`
- head SHA：`fe36fe4ad4e798aa5f4678ce944fff3925de058d`
- 分支：`feature/T-20260829-078-b1-scalar-closure`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-078`
- sent_at：2026-08-29T02:26:00+0800
- received_at：2026-08-29T02:38:05+0800
- reported_at：2026-08-29T02:38:05+0800

## 交付物

| 文件 | 说明 |
| --- | --- |
| `rtl/lcvex_decode.sv` | logical shifted-register 的 `shift_type=3`（ROR）解除 UDEF；ADD/SUB shifted-register `shift_type=3` 保持保留/UDEF |
| `sim/cocotb/test_alu.py` | ALU 级 ROR X/W、逻辑 ROR + inv_b（BIC/ORN/EON 路径）定向单元测试；drive 增加显式默认值避免跨测试状态泄漏 |
| `sim/cocotb/test_b1_logic_ror.py` | 新增核心级定向 cocotb：逻辑 ROR 全 op 族、XZR/SP、32 位零扩展、ADD/SUB ROR 保留负测 |
| `tb/sv/lcvex_b1_decode_tb.sv` | 新增解码器级 SV TB：ROR 接受、ADD/SUB ROR UDEF、XZR/SP 解码语义 |
| `docs/handoffs/T-20260829-078-b1-scalar-closure.md` | 本 handoff |
| `docs/tasks/evidence/T-20260829-078.json` | 证据 JSON |

## 实现摘要

- `BASE-DP-018`：
  - `rtl/lcvex_decode.sv` 的 logic shifted-register 分支不再把
    `shift_type=3` 置为 invalid；ALU 已有的 ROR 移位单元直接承接，
    因此 ORR/AND/EOR/BIC/ORN/EON/ANDS/BICS 的移位寄存器 ROR 生效。
  - `ADD/SUB` shifted-register 分支保留 `shift_type=3` UDEF 判定。
- 相邻低风险确认/补充：
  - XZR 源/目的语义在逻辑移位寄存器和 ADD/SUB 移位寄存器中已存在；
    解码器级 TB 增加定向断言。
  - SP 语义（ADD/SUB 立即数非 S 形式写 SP、S 形式丢弃）由解码器级 TB
    覆盖。
  - 32 位写零扩展由 ALU 结果通路和 ROR W 形式测试覆盖。
- 未发现其它 V82-BASE 小缺口需要本次实现；SVE/SME、MOPS、MTE、
  RCpc、LSE128 扩展、FP16 memory 等均按原 profile 保持
  blocked/deferred/未实现，未擅自扩大范围。

## 已执行校验

```text
conda run -n lcvex make -C sim/cocotb SIM=verilator \
  TOPLEVEL=lcvex_alu COCOTB_TEST_MODULES=test_alu \
  SIM_BUILD=sim_build_alu_b1
# TESTS=15 PASS=15 FAIL=0

conda run -n lcvex verilator --binary --timing --assert -Wall -j 2 \
  --top-module lcvex_b1_decode_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv tb/sv/lcvex_b1_decode_tb.sv
./obj_dir/Vlcvex_b1_decode_tb
# PASS: logical ROR accepted, ADD/SUB ROR UDEF, XZR/SP semantics

python3 -m py_compile sim/cocotb/test_b1_logic_ror.py sim/cocotb/test_alu.py
```

## 阻断 / 不适用

- 无实现层面阻断。
- `sim/cocotb/test_b1_logic_ror.py` 是完整 SoC 级定向测试，因本环境完整
  SoC Verilator 编译排队/资源限制未能完成一次运行；其内容已通过
  `py_compile` 和与解码器级/ALU 级测试同源的指令编码核对。集成者可在
  Gate/主机资源充足时按
  `make -C sim/cocotb TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_b1_logic_ror SIM_BUILD=sim_build_b1_core`
  复跑。
- 未修改 `docs/V82_PROFILE_MANIFEST.md`（不属于本任务写集）；需集成者在
  合并/复核时把 `BASE-DP-018` 状态由 blocked 更新为 implemented。

## 下一步

1. 集成者复核本分支并确认 `BASE-DP-018` 可计入 V82-BASE。
2. 在资源充分环境复跑 `test_b1_logic_ror` 完整核心路径（可选 L2）。
3. 按写集由集成者更新 manifest/任务 JSON 状态。
