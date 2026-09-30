# 03 RTL 质量与可综合性

> 状态：**RTL 可仿真/可 lint，单核 F 候选已有本地 Gate D 证据；FP/NEON
> generate-gate、fp_scalar 多周期除法、L2/L1D 降规模和模块级 standalone
> 综合已有专门任务推进并形成数据；完整 A10 顶层 fit/STA/SOF 仍阻塞。**
> 依据：`rtl/`、`Makefile`、T-090/T-091/T-099/T-101/T-102、
> T-20260830-001~005/008 evidence/handoff。

## 1. 结构与命名

RTL 共约 21k 行 SystemVerilog，`rtl/filelist.f` 固定编译顺序。

| 层次 | 主要模块 | 说明 |
| --- | --- | --- |
| Core | `lcvex_core.sv`（3675 行）、`lcvex_decode.sv`（3063 行）、`lcvex_pkg.sv`（720 行） | 5 级顺序单发射；系统寄存器/异常/提交包 |
| 整数/FP 执行 | `lcvex_alu.sv`、`lcvex_muldiv.sv`、`lcvex_fp_scalar.sv`、`lcvex_neon_int.sv`、`lcvex_neon_fp.sv`、`lcvex_fp_state.sv` | 标量 + 选定 FP/NEON |
| 存储 | `lcvex_l1_i.sv`、`lcvex_l1_d.sv`、`lcvex_l2.sv`、`lcvex_mmu.sv`、`lcvex_l1_d_wb.sv`、`lcvex_l2_wb.sv`、`lcvex_l1_coherence.sv`、`lcvex_l2_cluster.sv` | 原单核缓存 + FPGA 线写回/一致性 |
| 总线/SoC | `lcvex_axi4_*.sv`、`lcvex_axi4_avalon_adapter.sv`、`lcvex_async_fifo.sv`、`lcvex_catapult_soc_*.sv` | AXI4、EMIF 适配、可综合 SoC |
| 外设 | `lcvex_pl011.sv`、`lcvex_pl061.sv`、`lcvex_gic.sv`、`lcvex_mmio_fabric.sv` | P6 平台外设 |
| 集群 | `lcvex_cluster_pkg.sv`、`lcvex_cluster_top.sv`、`lcvex_core_wrap.sv` | C1/C2 多核壳层 |

命名风格：模块/信号多为小写 snake_case，中文注释说明架构语义；`lcvex_pkg.sv`
集中类型、异常编码、ID 寄存器和应用参数。文件较长且热点模块集中在
`core/decode/pkg`，当前按项目规划不机械拆分。

## 2. Verilator lint 现状

- `make compile` 使用 `verilator --lint-only -Wall -Wno-UNUSEDPARAM --top-module lcvex_core -f rtl/filelist.f`。
- 多个测试/构建目标使用 `-Wno-fatal -Wno-UNUSEDPARAM`，因此存在被抑制的
  warning 类，不代表零 warning。
- 最近记录：T-099 Gate D 的 `make test` 通过；T-097 分支 `make compile` PASS
  （Verilator Walltime 26.626s）；T-098 分支 `make compile` PASS。
- 部分模块有局部 `/* verilator lint_off ... */`（如 UNUSEDSIGNAL、
  SYNCASYNCNET），并在行尾部恢复。
- **未做/风险**：没有全仓库零 warning 门禁；没有对所有 `lint_off` 的正式
  理由台账；可考虑外部审计时运行 `make compile` 并审阅 warning 分类。

## 3. 参数化现状

- 单核参数：`RESET_PC`、`SRAM_BASE/TOP`、MMIO 窗口、`A64_FP_SIMD` 等。
- 存储/Cache 参数：`LINE_BYTES`、`L1_SETS`、`L2_SETS`、`L2_WAYS`、
  `SOURCE_ID_W`、`TRANSACTION_ID_W`、`CORE_COUNT`、`COHERENCE_ENABLE` 等。
- AXI4 参数：`DATA_WIDTH=128`、`ID_WIDTH=4`、burst/line 等。
- 多数模块是参数化的；C2 目录模块原有的隐式 2 核硬编码已由 C3 four-core
  实现移除（T-20260829-095），C4 测量扩展验证 8/16/32 参数化；32 核仍暴露
  `CORE_ID_W`/sysctrl 状态位宽限制。

## 4. FP/NEON generate-gate（已实现）

- T-20260830-004/FPGA-D 已实现真正的 `A64_FP_SIMD=0` generate-gate：可移除
  `lcvex_fp_scalar`、`lcvex_neon_fp`、`lcvex_neon_int` 实例；默认 `=1` 不变。
- 该能力使 no-FP 综合路径能实际减少资源；FPGA-F2 已用 `A64_FP_SIMD=0`
  隔离副本测量 `core_nofp` 等模块 standalone 通过。
- 残余边界：完整 A10 顶层 no-FP/full flow 仍被 Qsys/顶层 glue 阻塞，尚未
  取得 fit/STA/SOF。

## 5. fp_scalar 除法可综合性（已修复方案，待完整顶层验证）

- 原先 `rtl/lcvex_fp_scalar.sv` FDIV 路径使用超过 64-bit 的 `/`/`%`，
  Quartus `lpm_divide` 限制宽度 <= 64，导致 standalone synthesis 失败。
- T-20260830-003/FPGA-C 已改为多周期 256-bit restoring divider，避免
  `lpm_divide >64`；本地 `make compile`、`make sim-sv`、
  `sim-sv-fp-scalar` 在 cgroup 下 PASS。
- 状态：**方案已落地，但默认 FP 完整 A10 顶层综合仍未验证**；不宣称
  已通过完整 Quartus full flow。

## 6. L2 / L1D 资源热点

T-101/T-102 的模块级 standalone Quartus synthesis 数据：

| 模块 | 结果 | Logic Cells | 峰值 VM | 耗时 |
| --- | --- | --- | --- | --- |
| `lcvex_l1_d_wb` | 完成 | 182,885 | 3.64 GB | 4m24s |
| `lcvex_l1_i` | 完成 | 49,526 | 1.26 GB | 33s |
| `lcvex_decode` | 完成 | 14,667 | 682 MB | 33s |
| `lcvex_mmu` | 完成 | 1,762 | 597 MB | 4.1s |
| `lcvex_l2_wb` | 未完成（>37min） | 未出最终 LC | qdb 约 190MB netlist | 停止 |

- L2 writeback 是强烈怀疑的 OOM 主要贡献者；L1D writeback 本身也是重大模块。
- 完整 B5 SoC synthesis 在约 70–77GB 私有内存停滞，去掉平台 IP/EMIF 和关闭
  FP 参数均不能解决，热点在 Core/Cache/AXI/SoC 内部 RTL。
- T-20260830-002/FPGA-B 将 L2/L1 降规模参数化（`L2_SETS=64`、`L2_WAYS=1`
  等），Verilator 回归 PASS；T-20260830-008/FPGA-F2 在隔离副本中完成
  `l1_d_wb`（3.77GB/254s）、`l2_wb_reduced`（4.31GB/305s）、
  `soc_coh_reduced`（8.44GB/975s）、`core_nofp`（2.43GB/146s）等
  heavy module standalone，峰值均 <16GB。
- 仍无真实 B5 顶层 fit/STA/SOF：FPGA-F3/F4 blocked（见 `07-fpga.md`）。

## 7. CDC / 复位风险

- B2 EMIF 使用 `lcvex_async_fifo`（Gray 指针异步 FIFO）在 CPU 与 EMIF 时钟域
  之间传递请求/响应；适配器 `lcvex_axi4_avalon_adapter.sv` 有 `cpu_clk`、
  `emif_clk`、`cpu_rst_n`、`emif_rst_n` 和公共链路复位。
- 异步 FIFO：内存不复位，复位只清指针；同步器分别在各自接收域复位；公共复位
  作为 epoch 边界，避免跨域残留被当作新事务。
- **T-20260830-026 静态修复**：`lcvex_async_fifo` 改为独立的 `wr_rst_n` /
  `rd_rst_n`；适配器将公共复位请求
  `link_rst_n_req = cpu_rst_n & emif_rst_n & !cal_fail` 在 CPU/EMIF 两个域
  内分别做两拍 async-assert / sync-deassert 复位同步，再驱动 request/response
  FIFO 的写/读域。SDC 已补充异步时钟组、Gray 指针 source->first-sync
  false_path/max_delay，以及复位同步首级寄存器的 guarded false_path。
- 状态：**静态 RTL/SDC 已补，B2 SV 回归 PASS；仍未做 TimeQuest/Report CDC 和
  板级复位压力，故 EXT-03-001 保持 open**。
- 复位策略：Cache/data RAM 一般不复位，通过 valid/tag 边界屏蔽；异步 active-low
  复位清状态机/事务 id/metadata；上电复位树和多时钟复位序列仍需板级/时序验证。
- 外部审计建议重点关注：Gray 指针满/空边界、复位释放时序、公共复位对
  in-flight 事务的排空、EMIF calibration 完成前阻塞、以及所有异步 FIFO 实例
  的 CDC 寄存器和约束。后三项仍需 post-fit TimeQuest/Report CDC 与板级压力。

## 8. 已知质量限制

- 大模块集中度高，语法/语义清晰但可维护性依赖 `pkg` 和 docs。
- 未做正式的 lint waiver 审批清单；warning 以 `-Wno-fatal` 通过。
- 未做 FPGA 厂商时序签核（仅 T-064 一次真实 full flow/STA 通过，B5 后 OOM）。
- 未做多核 cache 协议形式化/完整 litmus。
