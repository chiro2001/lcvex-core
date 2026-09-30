# FP/NEON Pipeline PPA (FP-P4)

> 任务：T-20260902-018（FP-P4-FUNC-PERF-PPA）
> 工作区：`/home/chiro/projects/mycpu/lcvex-wt-T-20260902-018`
> 分支：`verify/T-20260902-018-fp-p4-func-perf-ppa`
> 基线 SHA：`1d57fa9dadc92d9c85ad755ce0debd0c6fc0acb7`
> 日期：2026-09-03

本文件记录 FP-P1/P2/P3 合入后的全量功能/性能验证，以及一 lane vs 二 lane 的
受控 PPA 探索。只做 synthesis 面积/wall/峰值，不做 fitter/STA/SOF。

## 0. 结论摘要

- **功能**：`make compile` PASS；P7 SV raw-bit（fp-scalar/p7-2/p7-3/p7-4/p7-5）
  全绿；P7 Cocotb fp-scalar 5/5、p7-3 4/4、p7-4 5/5、p7-5 8/8 全绿。
- **性能代理**：与 FP-P0 组合路径相比，共享单 lane 事务化使所有 FP workload
  周期显著上升：fp_scalar 173,026→255,382、fp_fp16 180,441→311,633、
  neon_vect 175,737→310,977；新增纯计算链 neon_fp_chain 35,409、
  scalar_fp16_chain 38,999。
- **FP busy/rsp_wait**：现在可由 RTL 事务接口直接计数。fp_busy_cycles 不再是
  只有 FDIV；一 lane 单在途使几乎所有 FP/NEON FP 都有执行/响应等待。
- **PPA**：一 lane `lcvex_fp_exec` standalone：93,564 ALM / 133,689 ALUT /
  1,733 regs / 24 DSP / 24:40；二 lane 面积探针：187,024 ALM / 267,283 ALUT /
  3,466 regs / 48 DSP / 28:26。增量约为一 lane 的 2.0 倍。默认保持 **keep-1**；
  二 lane 无功能 scheduler/性能/STA 证据，不进入发布配置。

## 1. 功能验证

### 1.1 SV raw-bit / 定向

| 目标 | 命令 | 结果 |
| --- | --- | --- |
| compile | `make VERILATOR_JOBS=1 compile` | PASS |
| P7-1 FP scalar | `make VERILATOR_JOBS=1 sim-sv-fp-scalar` | PASS |
| P7-2 NEON int | `make VERILATOR_JOBS=1 sim-sv-p7-2-neon` | PASS |
| P7-3 NEON FP | `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp` | PASS |
| P7-4 FMA/convert | `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert` | PASS |
| P7-5 FP16/sqrt/minmax/rint | `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round` | PASS |

### 1.2 Cocotb（真实 SoC 流水线）

| 目标 | 结果 | 说明 |
| --- | --- | --- |
| `sim-cocotb-fp-scalar` | 5/5 PASS | pipeline/FPEN/fault/backpressure/UDEF |
| `sim-cocotb-p7-3-neon-fp` | 4/4 PASS | pipeline/FPEN/backpressure/UDEF |
| `sim-cocotb-p7-4-fma-convert` | 5/5 PASS | scalar+vector FMA/convert/FPEN/backpressure/UDEF |
| `sim-cocotb-p7-5-fp16-sqrt-minmax-round` | 8/8 PASS | scalar H / sqrt / frint / fcvt / 4H-8H / FPEN / backpressure / UDEF |

### 1.3 L2 lockstep（A76 required 主镜像）



| 目标 | 结果 |
| --- | --- |
| `p7-1-fp-scalar` | 28 条 PASS |
| `p7-3-neon-fp` | 48 条 PASS |
| `p7-4-fma-convert` | 94 条 PASS |
| `p7-5-fp16-sqrt-minmax-round` | 102 条 PASS |

## 2. 性能验证

运行参数：Verilator 5.050，`A64_FP_SIMD=1`，`FETCH_FIFO_ENABLE=1`，
`I_L1/D_L1/L2=0`，`MEM_DELAY_MODE=0`，`PERF_MAX_CYCLES=5,000,000`。
自定义 runner 由同 SHA 的 SoC Verilator 模型链接，直接读取
`core.fp_tx_busy`、`fp_req_valid/ready`、`fp_rsp_valid` 和
`fp_exec.slot_done` 作为 FP 观测。

### 2.1 cycle / retired / IPC

| Workload | cycles | retired | IPC | commit_digest | memory_digest | P0 cycles |
|---|---:|---:|---:|---|---|---:|
| `fp_scalar` | 255,382 | 65,963 | 0.258292 | b0efde5ed79308a1 | 4078dabba91c60f0 | 173,026 |
| `fp_fp16` | 311,633 | 82,013 | 0.263172 | 34d6e3bf9d8ba016 | a8dddf1e0170212e | 180,441 |
| `neon_vect` | 310,977 | 66,721 | 0.214553 | 5c1d4f0a0f31cfe7 | 3ba6dea5f6c76128 | 175,737 |
| `neon_fp_chain`（纯计算） | 35,409 | 5,654 | 0.159677 | 3fe4c8f156476675 | 98ad0e170c2a6d90 | 98,801 |
| `scalar_fp16_chain`（纯计算） | 38,999 | 10,266 | 0.263238 | 63693a9b7d625793 | 2aee23a42102b9c7 | 94,334 |

说明：P0 的 `neon_fp_chain`/`scalar_fp16_chain` 为旧自定义源码，本任务重建了
等价纯计算链，因此 retired/op 计数与 P0 不同；cycle 对比仅作为方向性参考。

### 2.2 FP issue / busy / rsp_wait / slot

| Workload | fp_issue | fp_busy_cycles | fp_rsp_wait_cycles | fp_slot_done |
|---|---:|---:|---:|---:|
| `fp_scalar` | 41,176 | 98,736 | 57,560 | 41,176 |
| `fp_fp16` | 65,605 | 131,210 | 65,605 | 65,605 |
| `neon_vect` | 36,891 | 135,267 | 98,376 | 98,376 |
| `neon_fp_chain` | 4,608 | 23,040 | 18,432 | 18,432 |
| `scalar_fp16_chain` | 8,201 | 16,402 | 8,201 | 8,201 |

### 2.3 op/format 计数

| Workload | 主要计数 |
| --- | --- |
| `fp_scalar` | scalar add S/D 5,148 each；sub 5,120 each；mul 5,120 each；fma 5,120 each；div S/D 32 each；mov 48 each |
| `fp_fp16` | scalar H add 16,412 / sub 16,384 / mul 16,384 / fma 16,384 / fcvt 4 / fmov 37 |
| `neon_vect` | vec add S 8,210/D 4,105；mul S 8,192/D 4,096；fmla S 8,192/D 4,096；slots 98,376 |
| `neon_fp_chain` | vec add S 3,072；fmla S 1,536；slots 18,432 |
| `scalar_fp16_chain` | scalar H add 2,048 / sub 2,048 / mul 2,048 / fma 2,048 / fcvt 1 / fmov 8 |

## 3. PPA Sweep

### 3.1 目标与隔离

- 默认一 lane 发布配置：`lcvex_fp_exec`（共享 64-bit lane engine + 迭代
  FDIV/FSQRT）。
- 二 lane 探索：面积探针 `fp_exec_two_top`，在同一 probe 中例化两个
  `lcvex_fp_exec` 并做输出 mux；只用于面积上限估计，不作为功能二 lane
  scheduler，也不进入发布配置。
- 远端 Quartus 21.4 Build 67，器件 10AX115N4F40E3SG，仅 synthesis，不跑
  fit/STA/SOF。隔离目录 `D:\Projects\fpga-altra\lcvex\build\T-20260902-018-probe\**`。
- RTL 副本做了 Quartus 兼容小补丁：移除输入端口默认值（`iter_kill`、
  `iter_pause`、`kill`、`pause`），不影响 Verilator/功能语义。

### 3.2 一 lane synthesis 结果

工程：`T-20260902-018-probe/fp_exec_one`，top=`lcvex_fp_exec`。

| 指标 | 数值 |
| --- | ---: |
| ALM（estimate） | 93,564 |
| Combinational ALUT | 133,689 |
| Dedicated logic registers | 1,733 |
| DSP blocks | 24 |
| I/O pins | 904 |
| Max fanout | 1,733 |
| Total fanout | 641,560 |
| Wall | 1,487.9 s（24:40） |
| Peak virtual memory | 2,255 MB |

hierarchy：`lcvex_fp_exec` 总 ALUT 133,689；其中 `scalar_unit`（一个
`lcvex_fp_scalar`）132,606 ALUT、848 regs、24 DSP；`it_divider` 235 ALUT、
433 regs；`it_sqrt` 773 ALUT、390 regs。发布配置已确认只有一个 scalar lane。

### 3.3 二 lane area probe

工程：`T-20260902-018-probe/fp_exec_two`，top=`fp_exec_two_top`（两个
`lcvex_fp_exec` 实例 + 输出 mux，面积上界探针）。

| 指标 | 数值 |
| --- | ---: |
| ALM（estimate） | 187,024 |
| Combinational ALUT | 267,283 |
| Dedicated logic registers | 3,466 |
| DSP blocks | 48 |
| I/O pins | 903 |
| Max fanout | 3,466 |
| Total fanout | 1,281,755 |
| Wall | 1,706.1 s（28:26） |
| Peak virtual memory | 4,343 MB |

hierarchy 显示两个 `u0/u1` 各约 133.5K ALUT、1,733 regs、24 DSP；二 lane
相对一 lane 的增加约为 **+93K ALM、+133.6K ALUT、+1,733 regs、+24 DSP**。

### 3.4 PPA 讨论

- 一 lane `lcvex_fp_exec` standalone 已取得 synthesis 报告：约 93.6K ALM、
  133.7K comb ALUT、1.7K regs、24 DSP。
- 二 lane 面积探针完成的资源上界约为一 lane 的 **2.0× ALM / 2.0× ALUT /
  2.0× regs / 2.0× DSP**。对 full-FP 来说这是很大的面积代价；但 standalone
  仍远低于 A10 器件容量，full-top 是否仍满足 FP-O3 需在 FP-P5 实测。
- 二 lane 探针只验证“增加一个完整 lane engine”的面积成本，没有功能二 lane
  scheduler、fit/STA 或性能收益数据。首版发布决策仍以 FP-O4/FP-O6 为准：
  二 lane 必须通过 fitter/STA 且对实际 workload 有稳定收益才能晋级，当前
  没有这些证据。
- 本阶段建议 **keep-1**：共享单 lane 已同时满足功能、事务正确性和面积
  结构目标；二 lane 仅作为受控面积/性能后续候选，不进入默认发布配置。
- 当前性能显示单在途阻塞使 FP 密集 workload 的 busy/rsp_wait 显著；若后续
  fit/STA 证明面积余量充足且 FP busy 是主要瓶颈，再按计划评估二 lane/更小
  initiation interval，不应在本阶段直接切换。

## 4. 已知限制 / 未跑项

- 本任务没有运行 full-top Quartus synthesis，仅 standalone `lcvex_fp_exec`
  一/二 lane 面积探针；不能替代 FP-P5 的 full-FP fit/STA。
- 没有运行 fitter/STA/SOF。
- 二 lane 探针不是功能二 lane 调度器，性能收益未测量；面积只能作为上界。
- L2 lockstep 仅跑 P7-1/3/4/5 main required；未跑 edge/rounding/sequence 全部子集。
- P7-2 Cocotb 虽有历史红项但本任务未跑；本任务要求的 P7 Cocotb 套餐全绿。
