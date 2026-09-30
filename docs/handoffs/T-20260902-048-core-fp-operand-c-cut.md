# Handoff T-20260902-048：核心 FP/NEON operand_c 前递切级

```text
task=T-20260902-048
state=review
base=b928c7779116fb6103773f6fa0fcff0de104ff00
head=d219d17
branch=fix/T-20260902-048-core-fp-operand-c-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-048
sent_at=2026-09-04T13:07:00+08:00
received_at=2026-09-04T13:07:10+08:00
reported_at=2026-09-04T13:31:21+08:00
```

## 结论

针对 T-047 full-FP signoff 的 setup top-1
`soc|core|exmem_valid -> soc|core|idex_d.neon_fp_operand_c[17]`
（27 逻辑级、22.660 ns、slack -2.759 ns），在 `rtl/lcvex_core.sv` 做了受控
V 寄存器前递切级：

1. 删除 `fpv` 中 ID/EX response/执行结果和 EX/MEM FP/NEON 结果到 ID 的组合
   前递，只保留架构 `fp_v_state` 与 MEM/WB 已寄存结果。
2. 增加 `v_id_reads()`，合并 scalar FP 的 `fp_id_reads()` 和 Advanced SIMD 的
   `neon_id_reads()`。其中 `neon_fp_ra_en && d.neon_rd` 保留 FMLA/FMLS 的
   Vd 第三源检测；没有排除 V31。
3. 增加 `ex_id_v_hazard` 与 `exmem_v_hazard`：覆盖 scalar FP、NEON FP、
   NEON 整数写回以及 FP/NEON load 的 V 目的寄存器。依赖方分别等待 ID/EX、
   EX/MEM 离开后从 MEM/WB 或架构状态读取。
4. 两个 hazard 同时接入 `stall_id`（因此也接入 `stall_if`）、`flush_id` 和
   F1a `fetch_fifo_pop`，保持 FIFO on/off 下 IF/ID 的 PC/token 不被错误消费。
5. 保留既有 `fp_load_use`、`fp_tx_candidate/fp_rsp` 握手和 `fp_tx_kill`；
   `fp_rsp_ready` 没有反向依赖新 hazard，避免 response 永久等待。

该方案只引入相关 V RAW 的气泡，切断 `exmem_valid -> fpv -> decode ->
idex_d.neon_fp_operand_c` 数据前递链，不使用 SDC exception，也不改变提交
包或架构状态更新边界。

## 语义与边界

- V/FPSR 仍由 `lcvex_fp_state` 在 `commit_fire` 更新；ID/EX、EX/MEM 仅保存
  流水线结果，不提前改变架构状态。
- scalar FP 的 `Rn/Rm/Ra`、NEON 的 `Rn/Rm`、FMLA/FMLS 的 `Vd` addend、
  FP/NEON store 源均由同一 `v_id_reads()` 检测；V31 是普通 V 寄存器并参与
  匹配。
- `fp_load_use` 未修改，S/D/Q/LD1R load-use 仍在 ID/EX 或 EX/MEM 结果不可用
  时停顿；已有跨 scalar/NEON load-use 定向用例保持通过。
- `fp_tx_candidate`、`fp_rsp_valid/ready`、response capture、commit
  backpressure 和 kill 条件未改变；普通 taken branch 仍不是 FP kill。
- 未新增状态寄存器，reset 值、读写权限和提交时机不变。

## 定向覆盖

`sim/cocotb/test_p7_4_fma_convert.py` 新增
`test_p7_4_operand_c_back_to_back_raw`：连续 scalar FMA 与连续 NEON FMLA
均使用同一目的寄存器作为下一条的 `operand_c`，分别检查 22.0 的 raw result。
该用例同时验证了 FP response 到 MEM/WB 后再被消费者读取的路径。

## 验证结论

所有重型 Verilator 命令均使用
`systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0`，并设置
`VERILATOR_JOBS=1`；精确命令、退出码和计数见
`docs/tasks/evidence/T-20260902-048.json`。

- core compile、core smoke、commit backpressure、F1a FIFO SV：通过。
- P7-1 scalar FP Cocotb：5/5 通过；P7-2 NEON Cocotb：10/10 通过。
- P7-3 NEON FP Cocotb：FIFO on、FIFO off、MEM_DELAY_MODE=2 均 4/4 通过。
- P7-4 FMA/convert Cocotb：6/6 通过，包含新增 operand_c RAW 用例。
- P7-1 sequence：388/388；P7-3 NEON FP：48/48；P7-4：94/94；P7-4
  sequence：142/142；P7-5 sequence：66/66，均锁步通过。
- P7-3/P7-4 raw SV 单元、registry consistency 和 `git diff --check`：通过。

第一次在 fresh worktree 直接运行 `p7-1-fp-scalar-sequence` 时，因顶层
`lockstep-build` 未自动创建被忽略的 `build/verilator_lockstep` 目录而报
`Can't write file`（exit 2）；只创建该生成目录后同一命令成功，未改动构建
入口或源文件。

## 未执行与已知限制

- 未运行 Quartus synthesis/fitter/STA、assembler、SOF、编程或上板；物理
  setup 改善必须由集成者在合并 SHA 上重跑同一 FP-P5 flow 确认。
- 未修改 QEMU fork；未关闭断言、跳过差分或加入 false path。
- 该任务没有扩展既有 `irq_taken` 年轻 ID/EX/EXMEM 清空风险；该风险由后续
  独立 regression task 处理，本任务不声称已覆盖或修复。
- V RAW 依赖现在可能增加等待到 MEM/WB 的气泡，这是时序切级的预期性能
  代价；提交顺序和可观察架构结果不变。

## 下一步

1. 集成者 cherry-pick `d219d17` 及本 handoff/evidence 提交，在合并 SHA
   复跑任务要求的 L0--L2 子集。
2. 派发独立 FP-P5 rerun round13，确认 T-047 top-1 离开
   `exmem_valid -> idex_d.neon_fp_operand_c`，并复核 hold/recovery/removal/
   min-pulse/DDR 全部保持绿色。
3. 在 full-FP signoff setup 全绿前不运行 assembler/SOF。
