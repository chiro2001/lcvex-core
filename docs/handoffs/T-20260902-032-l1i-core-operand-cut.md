# Handoff T-20260902-032: L1I core operand cut

```text
task=T-20260902-032
state=review
base=5523201b025b45a16afb477de113b71bccad85c8
head=729805eda0c7dc897b516fa0535c9bdacd132b78
branch=fix/T-20260902-032-l1i-core-operand-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-032
sent_at=2026-09-03T20:41:00+08:00
received_at=2026-09-03T20:41:30+08:00
reported_at=2026-09-03T20:55:30+08:00
```

## 结论

- 目标路径已从 RTL 组合锥中打断：
  `soc|core|idex_d.operand_a[13]` → ALU → `ex_wdata` →
  ID/EX→ID GPR 前递 `gprv` → decode 地址/异常 → `sys_commit_ready` →
  `fetch_req_valid` → `fetch_imem_req_valid` → `soc|coh|i_l1|rsp_data_r` ENA。
- 修改方式：**删除 ID/EX 普通 GPR ALU 写回向 ID 的组合前递分支**，对依赖
  该 ID/EX 结果的 IF/ID 指令增加一拍 hazard 停顿；下一拍 ALU 结果进入
  EX/MEM 寄存器后，由 EX/MEM→ID 已寄存前递继续提供正确操作数。
- 同时把新 hazard 纳入 `fetch_fifo_pop` 门控，避免 F1a FIFO 在 IF/ID 被
  stall 时仍弹出头部导致指令丢失。
- 未加 SDC false_path；未改 I-L1/coherence/内存语义；未改异步复位；
  未引入猜测执行（仍由既有控制流 fence/flush 保证分支正确性）。

## 切级依据（T-031 实际 STA 路径）

T-20260902-031 的 `t031_setup_top.txt` 显示 top-1 数据路径为：

1. `idex_d.operand_a[13]`（ID/EX 寄存器 Q）
2. `soc|core|alu|*` 组合 ALU 结果
3. `ex_wdata[*]`、`gprv[24][5]`
4. `soc|core|decode|*`（`d.mem_addr`、`d.exc_code`、`LessThan` 等）
5. `sys_commit_ready`、`fetch_req_valid`、`fetch_imem_req_valid`
6. `soc|coh|i_l1|i1012` / `Mux_183`
7. `soc|coh|i_l1|rsp_data_r[18]|ena`（寄存器 enable，不是 cache RAM 数据）

关键点是路径并非 I-L1 SRAM 读数据本身，而是“是否加载 `rsp_data_r`”
的时钟使能由 core 的 ALU→前递→译码→取指控制组合决定。单纯在 I-L1 内
把 `rsp_data_r` 再打一拍只能移动 enable，无法消除 core 内 49 级组合锥。
因此本任务在 core 侧打断 ID/EX→ID 的普通 GPR 结果前递。

## 实现摘要

在 `rtl/lcvex_core.sv`：

1. 删除 `gprv` 前递 mux 中：
   ```systemverilog
   else if (idex_valid && !ex_busy && idex_d.wb_we &&
            !idex_d.is_load && !idex_d.is_stxr &&
            idex_d.wb_rd == i[4:0])
     gprv[i] = ex_wdata;
   ```
   保留 EX/MEM、MEM/WB 以及 `wb3_extra`/FP response 等已寄存前递。

2. 新增 hazard：
   ```systemverilog
   logic ex_id_gpr_hazard;
   assign ex_id_gpr_hazard =
       idex_valid && idex_d.wb_we &&
       !idex_d.is_load && !idex_d.is_stxr &&
       idex_d.wb_rd != 5'd31 &&
       id_reads(idex_d.wb_rd);
   ```
   加入 `stall_id`，并在 `flush_id` 中抑制，使分支/系统指令等控制流决策
   也等待正确的 EX/MEM 已寄存结果，而不是用旧值误拍。

3. F1a FIFO 一致性：
   ```systemverilog
   !ex_id_gpr_hazard
   ```
   加入 `fetch_fifo_pop` 条件，保证 IF/ID 被 hazard stall 时不丢 FIFO 头。

## 语义保持

- 架构状态、提交顺序、commit packet、内存副作用、异常/PC、缓存/coherence
  语义不变。
- 普通 GPR RAW 依赖（含 MOVK 读旧值、ALU→ALU、ALU→访存地址/分支）由
  “ID/EX 组合前递”改为“停顿一拍 + EX/MEM 已寄存前递”，结果仍与 QEMU 一致。
- load-use、STXR、FP load-use 原有 hazard 不变。
- `fetch_fifo_pop` 与 `stall_id`/`stall_if` 对齐，避免 FIFO 头丢失；
  `sim-sv-fetch-fifo` 与 hazard 差分均通过。
- 不修改异步复位、不新增寄存器写使能/复位语义。

## 验证

| 项目 | 结果 | 命令 |
| --- | --- | --- |
| compile | PASS | `make VERILATOR_JOBS=1 compile` |
| core SV smoke | PASS | `make VERILATOR_JOBS=1 sim-sv` |
| I-L1 SV | PASS | `make VERILATOR_JOBS=1 sim-sv-l1i` |
| F1a fetch FIFO | PASS | `make VERILATOR_JOBS=1 sim-sv-fetch-fifo` |
| P2 difftest RTL | PASS 33/33 | `make VERILATOR_JOBS=1 difftest-rtl` |
| hazard difftest | PASS 34/34 | `make VERILATOR_JOBS=1 difftest-hazard` |
| git diff check | PASS | `git diff --check` |

直接 `make sim-cocotb-core` 缺少 `QEMU_TRACE` 会按测试契约失败；已用
`difftest-rtl`/`difftest-hazard` 覆盖同一 Cocotb core 入口。

## 边界/风险

- 未运行 Quartus full-FP synthesis/fitter/STA；需由下一轮 FP-P5 rerun
  确认 `sys_clk_50` 新 top-1 是否仍落在：
  - ID/EX ALU → EX/MEM 寄存器（本轮切后自然保留的 EX 到 EX/MEM 路径），
  - 或 SP/NZCV 的 ID/EX 组合前递（本轮未一并去掉），
  - 或其它 decode/取指控制寄存器。
- 性能代价：背靠背普通 GPR RAW 依赖增加一拍 bubble；FP/load-use 等原有
  hazard 不变。后续性能任务如需可评估。
- 只改了 `rtl/lcvex_core.sv`，未改 L1/coherence；若 STA 重新显示
  I-L1 输入寄存器 enable 仍为关键，则需在 core 做更早的取指控制/前递切级。

## 下一步

1. 集成者复跑 FP-P5（同一 source/QSF/SDC），确认 top 是否从
   `idex_d.operand_a -> i_l1.rsp_data_r` 移出。
2. 若新 top 为 SP/NZCV ID/EX 组合前递，继续按同样方式做定向寄存器切级。
3. 若新 top 为 `idex_d.operand_a -> exmem_wdata` 或 `fetch_imem_req_valid`
   相关控制寄存器，再评估 EX 级结果寄存器或取指控制流水化。
