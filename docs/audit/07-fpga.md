# 07 FPGA / Catapult A10 上板使能

> 状态：**平台包、AXI4/EMIF/L2WB/L1 一致性和一次历史真实 full flow/STA 已有；
> FPGA-F2 在模块级拆分和 bottom-up 流程上有突破，但 FPGA-F3/F4 在真实
> A10/SoC 顶层仍 blocked；T-067 未解除，DDR/板级/Linux 板测未完成。**
> 依据：`fpga/catapult_a10/`、`docs/FPGA_PLAN.md`、
> `docs/P7_FPGA_PARALLEL_PLAN.md`、T-063/T-064/T-065/T-067/T-101/T-102、
> T-20260830-001~008/016/020。

## 1. 平台与工程可重生成

- 平台：Microsoft Catapult v3 / Mg Catapult，Arria 10
  `10AX115N4F40E3SG`，Quartus Prime Pro 21.4 Build 67。
- 仓库输入：`fpga/catapult_a10/` 包含 QSF/QPF/SDC、Qsys、SFL/EPCQ、
  JTAG-UART、platform manifest、SHA256SUMS、skeleton manifest、
  `regenerate_qsys.sh` 等。
- `platform_manifest.json` 记录来源项目/commit、文件 hash、时钟、DDR、Flash、
  控制台、初始 128 MiB 窗口、再生成状态。
- `SHA256SUMS` 是仓库内平台 payload 的当前哈希；离线检查脚本
  `check_platform.py`、`check_skeleton.py`、`lint_platform.sh` 可跑。
- T-063 已在远端 Quartus 工程从零创建工程并验证 `qsys-generate` /
  `quartus_ipgenerate` 和 smoke full compile；T-064 用真实顶层完成
  `quartus_sh --flow compile catapult_a10` 并通过 STA。
- **未完成**：当前 B5 SoC 在完整 Quartus full flow 的 Synthesis 阶段 OOM；
  因此最新 B5 工程的 fit/STA/SOF 尚未取得。

## 2. T-064 历史 full flow/STA（方向参考）

T-20260828-064 在旧 B5/late B4 兼容版本上跑通过：
- `quartus_sh --flow compile catapult_a10` exit 0，0 errors / 68 warnings。
- Fit：4,468 ALMs / 8,641 registers / 141 pins / 27 RAM blocks / 0 DSP / 3 PLLs。
- STA：worst setup +0.220 ns（EMIF core user clock，Slow 900mV 100C）；
  worst hold +0.017 ns（sys_clk_50，Fast 900mV 0C）；recovery +0.53 ns；
  removal +0.112 ns；min pulse +0.12 ns。
- 记录 Fmax：sys_clk_50 213.49 MHz、clk_y3 499.25 MHz、EMIF core user
  283.29 MHz、EMIF core cal master 266.88 MHz。
- 该结果不是当前 B5 SoC 最新代码的重复 full flow，也不能替代 Gate F-BOARD。

## 3. T-067 OOM 定位

- T-067 是远端 B5 SoC full flow/STA 重跑，目前 blocked：Synthesis 阶段约
  75–77GB 私有内存，被内部 OOM 中止。
- T-101：
  - `soc_only`（去掉 EMIF/SFL/JTAG/platform IP）仍约 70GB 停滞 → 热点在
    Core/Cache/AXI/SoC 内部。
  - `soc_nofp`（`A64_FP_SIMD=0`）同样约 70GB → 参数没有真正移除 FP/NEON 实例。
  - `decode` 可完成；`core_only` 因 `fp_scalar` >64-bit `lpm_divide` 快速失败。
- T-102：
  - `l1_d_wb` 独立 synthesis 完成：182,885 LC / 3.64GB / 4m24s。
  - `l2_wb` >37min 未完成，qdb 已产生约 190MB netlist，强烈指向主要 OOM
    贡献者。
  - `l1_i` 49,526 LC、`decode` 14,667 LC、`mmu` 1,762 LC。
  - fp_scalar 组合 256-bit restoring 除法不实用。
- **后续已推进（T-20260830-001~008）**：
  - T-001/FPGA-A 补齐多数模块 standalone 测量；fp_scalar/neon_fp 当时仍受
    `lpm_divide`/超时影响，soc_coh 超时。
  - T-002/FPGA-B 将 L2/L1 参数化降规模（`L2_SETS=64`、`L2_WAYS=1` 等），
    L2 data array 大幅缩小；Verilator 回归 PASS。
  - T-003/FPGA-C 将 fp_scalar 大位宽除法改为多周期 256-bit restoring
    divider，避免 `lpm_divide >64`；本地 make compile/sim-sv/fp-scalar PASS。
  - T-004/FPGA-D 实现真正 `A64_FP_SIMD=0` generate-gate，可移除
    fp_scalar/neon_fp/neon_int 实例；默认值不变。
  - T-005/FPGA-E 评估 partition/incremental 并交付模板/分阶段计划。
  - T-008/FPGA-F2 隔离副本中所有重型模块 standalone 峰值 <16GB（最大
    soc_coh 8.44GB），并验证 blackbox synth → `quartus_cdb --import_partition`
    → fitter-only 可避免子分区重综合。
- **仍 blocked（T-20260830-016/020）**：真实 A10 顶层 blackbox 工程卡在
  Qsys/`alt_sld_fab_0` 生成长时间占用；SoC-only 黑盒顶层 85s 达 31.3GB 被
  30GB 保护中止；复制原 DB 后 fitter-only 报 “Cannot load synthesized
  database”。因此未进入 fit/STA/assembler，**T-067 未解除**。

## 4. L2 writeback / L1D 热点

- `lcvex_l2_wb.sv` 是 64B line、2-way、单 outstanding 的 write-back L2，模块
  级验证存在，综合规模和 OOM 风险高；T-002 已通过 `L2_SETS=64`/`L2_WAYS=1`
  等参数化降规模。
- `lcvex_l1_d_wb.sv` 是 write-back D-L1，单独综合已是近 183k LC 的重模块；
  FPGA-F2 已把 `L1D/L2/soc_coh/core` 等独立生成 QDB，并验证小工程
  blackbox→import→fitter-only 流程。
- 剩余：把该流程落到真实 A10/SoC 顶层仍受 Qsys/debug-fabric 和顶层 glue
  elaboration 内存限制；需要更高内存/修复生成问题。

## 5. fp_scalar / 可综合问题

- 见 `03-rtl-quality.md`：`lcvex_fp_scalar.sv` 的 FDIV 曾使用超 64-bit `/`/`%`，
  Quartus `lpm_divide` 报错；T-20260830-003 已改为多周期 256-bit restoring
  divider，本地仿真/编译 PASS，避免 `lpm_divide >64`。
- 仍不宣称默认 FP 完整 A10 顶层 Quartus 综合通过；B5 full flow 仍 blocked。

## 6. partition / incremental 评估

- T-102 只给出方向；T-20260830-005/FPGA-E 已交付 partition 模板与分阶段计划，
  但未启动完整 B5 full flow。
- T-20260830-008/FPGA-F2 在小型实验中验证了 blackbox synth → QDB import →
  fitter-only 可跳过子分区重综合；真实 B5 顶层尚未成功（FPGA-F3/F4）。

## 7. 板级未完成项

| 项目 | 状态 |
| --- | --- |
| DDR March / 地址/数据线/byte-enable 测试 | 未完成 |
| EMIF calibration 后稳定性和板级冒烟 | 未完成 |
| 裸机 Cache/MMU 板测 | 未完成 |
| Linux `/init` 板测 | 未完成 |
| SignalTap/日志/产物归档 | 未完成/板测后 |
| 完整 2GiB 地址、ECC/RAS、量产签核 | 明确后置 |
| 多核 MESI/MOESI、ACE/CHI、coherent DMA | 明确后置/不在 F 单核 |
| P8 SVE、P9 JTAG/GDB/PMU | 后置 |
| 多板型、功耗/可靠性量产 | 后置 |

## 8. 声明与审计注意

- T-064 真实 full flow 通过只说明当时平台/RTL 子集可综合并满足 STA，不代表
  B5 SoC 当前可重跑，也不代表板级验收。
- 未读取/复制 license 内容；远程操作只限定在用户指定工程/实验目录。
- 开源 Yosys/ABC/ECP5 结果只是宏观代理，不能替代 A10 资源或 Fmax。
