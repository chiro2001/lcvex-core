# Handoff T-20260902-036: core next_pc/atomic compare pipeline cut

```text
task=T-20260902-036
state=review
base=39e0f8a5c9e87492dec3fc910f822e49b7da8671
head=18f5ab2850d76de8ea530a8ec16d2de4b098486a
branch=fix/T-20260902-036-core-nextpc-atomic-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-036
sent_at=2026-09-03T23:35:00+08:00
received_at=2026-09-03T23:35:30+08:00
reported_at=2026-09-04T00:00:00+08:00
```

## 结论

针对 T-20260902-035 指出的 `sys_clk_50` setup top
（`soc|core|idex_d.operand_b[7]~DUPLICATE` →
`soc|core|idex_d.next_pc[9]` / `atomic_cmp2`，45 逻辑级、
28.022 ns、-8.192 ns），在核心 ID/EX→ID 的剩余组合前递上做
**T-032 同款切级**：

1. 删除 `gprv` 中的 ID/EX `wb3_extra` 组合前递（pre/post 基址更新）。
2. 删除 `spv` 中的 ID/EX `ex_sp_wdata` 组合前递。
3. 删除 `nzcvv` 中的 ID/EX `ex_nzcv` 组合前递（含整数 ALU flags 与
   FP CMP）。
4. 新增 `decoded_insn_t.uses_sp` / `uses_nzcv` 标记，由 decode 准确指出
   当前 IF/ID 指令是否在 ID 级消费前递后的 SP/NZCV 视图。
5. 新增 `ex_id_sp_hazard` / `ex_id_flags_hazard`，并把 `wb3` 读依赖并入
   `ex_id_gpr_hazard`；三者均纳入 `stall_id`、`flush_id` 和
   `fetch_fifo_pop`，保证 IF/ID 在读到旧值前停顿，下一拍由 EX/MEM 已寄存
   前递继续提供正确值。
6. 未加 SDC false_path；未改分支/原子/异常 PC 语义；未改异步复位；
   未引入猜测执行；未触碰 T-032/034 已切 FP 与 EMIF 路径。

切级后，从 `idex_d.operand_b` Q 到 `idex_d.next_pc` / `idex_d.atomic_cmp2`
D 的单拍组合锥不再经过 ID/EX→ID 的 ALU/SP/NZCV/FP 写回前递；该路径只剩
ID/EX→EX/MEM 的已寄存边界，属于下一轮 STA 可观察的新一段。

## 实现摘要

### `rtl/lcvex_pkg.sv`
- `decoded_insn_t` 增加两个 1-bit 内部标记：
  - `uses_sp`：decode 是否消费前递后的 SP；
  - `uses_nzcv`：decode 是否消费前递后的 NZCV。
- 这两个字段只用于核心 hazard，不进入 `ex_pipe_t` / 提交包。

### `rtl/lcvex_decode.sv`
- 在 `always_comb` 尾部分析最终 `d` 与编码：
  - `uses_sp`：所有以 `[Rn]` 为基址的访存/原子（Rn=31=SP）、
    ADD/SUB immediate 与 extended-register 的 Rn=31 形式。
  - `uses_nzcv`：B.cond、CSEL/CSINC/CSINV/CSNEG、CCMP/CCMN、
    MRS NZCV。
- 即使后续异常后处理把指令变为异常，仍保留消费标记，避免分支目标/异常
  地址在条件值尚未稳定时提前解析。

### `rtl/lcvex_core.sv`
- `gprv`：删除 `idex_valid && idex_d.wb3_we` 分支，保留 EX/MEM、
  MEM/WB 的已寄存 `wb3_extra` 前递。
- `spv` / `nzcvv`：删除 ID/EX 项，只保留 EX/MEM、MEM/WB 与架构值。
- `ex_id_gpr_hazard`：扩展到同时覆盖普通 GPR ALU 写回和 `wb3` 基址更新；
  并补充 `ifid_valid && d.valid` 门控。
- 新增：
  ```systemverilog
  logic ex_id_sp_hazard;
  assign ex_id_sp_hazard =
      ifid_valid && d.valid && idex_valid && idex_d.sp_we && d.uses_sp;
  logic ex_id_flags_hazard;
  assign ex_id_flags_hazard =
      ifid_valid && d.valid && idex_valid && idex_d.set_flags && d.uses_nzcv;
  ```
- 三个 hazard 均加入 `stall_id`、`flush_id` 与 `fetch_fifo_pop`。

## 语义保持

- 架构状态（GPR/SP/NZCV）仍在 commit 阶段更新；提交包、提交顺序、内存
  副作用、exclusive 监视器、异常优先级/ELR/FAR 未变。
- 分支目标、条件分支、CBZ/TBZ、BR/BLR/RET、CSEL/CCMP、MRS NZCV 在
  ID 级依赖 SP/NZCV 时改为“停顿一拍 + EX/MEM 已寄存前递”，结果与 QEMU
  一致；`difftest-hazard` 与 `difftest-rtl` 均验证。
- pre/post 基址更新（`wb3`）不再从 ID/EX 组合前递；依赖方由
  `ex_id_gpr_hazard` 停顿，下一拍从 EX/MEM 前递。
- 不改变异步复位；不改变流水线 flush/异常重定向的架构边界，只增加
  hazard bubble。
- 没有使用 SDC false_path 或 max_delay 掩盖同域 setup。

## 延迟影响

- 普通 GPR RAW、pre/post 基址、SP 依赖、decode 期 NZCV 依赖在背靠背
  时各增加 1 拍 bubble（与 T-032 已引入的普通 GPR ALU 依赖一致）。
- 指令功能 latency、FP/NEON transaction 固定延迟、乘除迭代周期不变。
- 架构可观察行为（提交序列与状态）不变，锁步差分不检查周期数。

## 验证

| 项目 | 结果 | 命令 |
| --- | --- | --- |
| compile | PASS | `make VERILATOR_JOBS=1 compile` |
| core smoke | PASS | `make VERILATOR_JOBS=1 sim-sv` |
| backpressure | PASS | `make VERILATOR_JOBS=1 sim-sv-backpressure` |
| F1a FIFO | PASS | `make VERILATOR_JOBS=1 sim-sv-fetch-fifo` |
| decode scalar | PASS | `lcvex_b1_decode_tb`（手工 Verilator） |
| atomic/barrier decode | PASS | `lcvex_b3_atomic_barrier_tb`（手工 Verilator） |
| P2 RTL difftest | PASS 33/33 | `make VERILATOR_JOBS=1 difftest-rtl` |
| hazard difftest | PASS 34/34 | `make VERILATOR_JOBS=1 difftest-hazard` |
| git diff check | PASS | `git diff --check` |

## 边界/风险

- 未运行 Quartus/A10 full-FP 综合、布局布线和 signoff STA；需由下一轮
  FP-P5 rerun（同一 source/QSF/SDC）确认 `sys_clk_50` 新 top 是否离开
  `idex_d.operand_b -> next_pc/atomic_cmp2`，以及是否转入
  `operand_b -> exmem_nzcv/exmem_sp_wdata` 或其它核心段。
- 性能代价：SP/NZCV/pre-post 依赖多 1 拍 bubble；这是时序优先的预期取舍。
- `uses_sp` 对 LDR literal 等无基址形式可能由编码低 5 位巧合误报，仅造成
  可能的额外 bubble，不影响架构正确性。
- 保留 FP/NEON 的 `fpv`/`fp_rsp` 已寄存前递；未进一步切 FP 内部路径。

## 修改文件

- `rtl/lcvex_core.sv`
- `rtl/lcvex_decode.sv`
- `rtl/lcvex_pkg.sv`
- `docs/handoffs/T-20260902-036-core-nextpc-atomic-cut.md`
- `docs/tasks/evidence/T-20260902-036.json`

## 下一步

1. 集成者在合并 SHA 上按同 source/QSF/SDC 重跑 full-FP synthesis →
   fitter → signoff STA，确认 T-035 top 是否移出 `sys_clk_50` setup top-N。
2. 若新 top 为 `idex_d.operand_b -> exmem_sp_wdata/exmem_nzcv` 或
   EX/MEM→ID 的已寄存前递与 decode 聚合，继续评估下一级寄存器切级。
3. 保持 T-032/T-034 与 EMIF 闭合成果；不要用 SDC false_path 掩盖同域 setup。
