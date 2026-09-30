# T-20260905-017：R18 FP round-pack prescan cut

```text
task=T-20260905-017
state=review
base=738cc142c0dae5269dffe9b8020094cb77ec8094
implementation=ebcf674abbbb81b0dac68faf12442c1c48e48d8e
branch=timing/T-20260905-017-r18-fp-prescan-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-017
cone_source=T-20260905-014 R17 full-FP post-fit directional report
reported_at=2026-09-05T20:02:00+08:00
```

## 结论

T-014 在 R17 candidate 上报告了 `pp_pre -> pack_pre` 50/50 条路径，最差
`pp_pre.sig[249] -> pack_pre.is_tiny`，data delay `22.460 ns`、logic levels
59。T-017 在不修改 core、NEON、QEMU 或 SDC 的前提下，把该路径再切成真实的
`pack_scan` 寄存器边界：

```text
pp_pre --(256-bit leading-one/zero scan + e)--> pack_scan
       --(tiny/normal classification)--------> pack_pre
       --(normalize + GRS)--------------------> pack_mid
       --(increment/overflow/subnormal/pack)-> result
```

`round_pack_scan` 负责 256-bit leading-one/zero 扫描和 `exp2 + lead` 的派生
指数；`round_pack_pre` 只消费已登记的 scan payload 并完成 tiny/normal 分类，
不再包含 priority scan。`round_pack_p1` 和 `round_pack_p2` 的 raw-bit、GRS、
舍入、溢出、subnormal、FZ/AHP 和 FPSR 逻辑保持原语义。

## 状态与控制边界

- `IT_PREP` 从普通 `pp_pre` 写入 `pack_scan{,_lo,_hi}`，不产生 `iter_done`。
- 新增 `IT_PACK_SCAN=4'd10`：从已登记 scan payload 写入
  `pack_pre{,_lo,_hi}`，只做 tiny/normal 分类，不产生 `iter_done`。
- `IT_PACK_PRE=4'd11`：从 `pack_pre*` 写入 `pack_mid*`，完成 normalize/GRS，
  不产生 `iter_done`。
- `IT_PACK=4'd12`：仅由 `round_pack_p2` 完成最终 increment/overflow/subnormal/
  pack，并暴露一个 `iter_done/result` 窗口。
- `pack_scan*`、`pack_pre*`、`pack_mid*` 和 state 在异步 reset、`iter_kill`
  （优先于 pause）时清零/回 `IT_IDLE`；在新边界各阶段 `valid=0` 时清零并放弃
  当前 transaction。最终消费也清零所有 round-pack payload。
- `iter_pause` 继续门控整个状态机；暂停 `IT_PACK_SCAN` 或后续阶段时保持
  payload，不重读 live operand，解除后只推进一个阶段。DIV/SQRT 的
  `div_pre/sqrt_pre -> IT_FIN -> IT_PACK` 路径未经过 `IT_PACK_SCAN`。
- 没有修改公共端口、架构状态、响应保持/单 outstanding 协议或提交路径。

## Latency 影响

相对于当前 R17/T-010 已测表，普通 `pp_pre` round-pack 操作每个 scalar slot
增加一拍；NEON 复用 slot 时每个受影响 lane 增加一拍。以下是合并 candidate
应复核的 nominal request-to-response 表（暂停周期另加）：

| 路径 | R17 当前 | T-017 预期 |
| --- | ---: | ---: |
| scalar FADD/FSUB S/D/H | 9 | 10 |
| scalar FMUL/FMA 四族 | 8 | 9 |
| scalar SCVTF/UCVTF | 7 | 8 |
| scalar FCVT（含 H source 单 lane） | 6 | 7 |
| NEON FADD/FSUB.2S | 17 | 19 |
| NEON FADD/FSUB.4S | 33 | 37 |
| NEON FMUL/FMA.2S | 15 | 17 |
| NEON SCVTF/UCVTF.2S | 13 | 15 |
| scalar FDIV S/D | 261 | 261 |
| scalar FDIV H | 518 | 518 |
| scalar FSQRT S/D | 69 | 69 |
| scalar FSQRT H | 70 | 70 |
| NEON FSQRT.2S | 137 | 137 |
| CMP/FMIN/FMAX/FRINT/FCVTZS/U 等 pp_other | 不变 | 不变 |

DIV/SQRT 不进入新 state，故 nominal latency 不变；最终数值和 flags 仍须由
合并 SHA 的 directed/lockstep 套件实测确认。T-017 没有作 physical improvement
或 timing closure 声明。

## Focused test

新增 [`tb/sv/lcvex_fp_scalar_r18_tb.sv`](../../tb/sv/lcvex_fp_scalar_r18_tb.sv)，
直接实例化 `FP_ITER=1` scalar，覆盖：

- normal 和 minimum-subnormal 的 raw result/FPSR flags；
- `IT_PREP -> IT_PACK_SCAN -> IT_PACK_PRE -> IT_PACK` 状态及 metadata 传递；
- 新 `IT_PACK_SCAN` 上的 pause/hold/release；
- 新边界上的 kill+pause 优先级、reset、valid-drop 和 reissue，检查无 stale
  payload/ghost done。

该测试文件仅作合并后的 focused SV 测试入口；本 owner lane 按任务要求没有运行
Verilator、Cocotb、QEMU、Quartus、assembler、JTAG、烧写、上电或板测。

## 静态验证与集成注意事项

- `git diff --check`：PASS。
- Icarus static parse 命令已执行，未发现 T-017 新增错误；Icarus 13.0 对源文件
  原有 3 个 `inside` 表达式（`rtl/lcvex_fp_scalar.sv:3120/3618/4048`）报告
  `sorry: "inside" expressions not supported yet` 并返回 3，因此不能把该结果
  记作完整编译绿灯。没有使用该限制绕过断言或修改参考值。
- 当前 T-010 的既有 `tb/sv/lcvex_fp_exec_tb.sv` 仍含旧状态数值/普通 latency
  断言；集成者须在临时 batch candidate 上串行更新或相应复核
  `IT_PACK_PRE=11`、`IT_PACK=12` 及每 slot +1 的普通路径表，不能把本 focused
  TB 的静态 parse 当作联合 L0-L2 证据。
- 集成者必须在精确合并 SHA 上运行受影响的 L0-L2、严格 lockstep 和一次新的
  physical flow；只有 post-fit/STA 才能确认旧 `pp_pre -> pack_pre.is_tiny` 是否
  离开 top-N 以及新 `pp_pre -> pack_scan` cone 的实际代价。

## 修改文件

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_scalar_r18_tb.sv`
- `docs/handoffs/T-20260905-017-r18-fp-prescan-cut.md`
- `docs/tasks/evidence/T-20260905-017.json`
