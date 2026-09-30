# A4 OpenSynth 趋势/差分回归与阈值守卫

- 任务：`T-20260829-087` (A4)
- 状态：review（owner 完成，待集成者复核）
- base SHA：`7c847561d3de3edeee0f7f8937fd3929fc101ba6`
- head SHA：`3a1c66e7786391d8f3cde287c72c7e986115e384`
- 分支：`feature/T-20260829-087-a4-trend-regression`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-087`

> **重要边界**：本报告不是 Arria 10 signoff，不替代 Quartus，不解除 T-067。
> A4 只处理已存在的 A1/A2/A3 产物；未运行 Yosys/nextpnr/Verilator/Quartus/P&R。

## 1. 结论摘要

- 阈值守卫总体结果：**pass**。
- A1 三个模块的两跑一致性和 A2 boundary-stub 的两跑一致性均通过；统计与网表 SHA 无漂移。
- A1/A2 当前数值与 A3 记录一致；A3 记录的关键输入文件 SHA 未变化。
- **时间序列趋势为 N/A**：本工作树没有更早的 A4 快照，不能编造趋势；当前输出作为首个 A4 基线保存。
- 代理内 run-to-run 重复性不是性能趋势；不衍生任何 A10 资源/Fmax 百分比。

## 2. 工具版本（来自既有 artifact，未调用工具）

| 来源 | 工具 | 版本 |
| --- | --- | --- |
| A1 | a1_yosys | Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg] |
| A1 | a1_abc | UC Berkeley, ABC 1.01 (compiled Jun 19 2026 19:18:10) |
| A1 | a1_python | Python 3.12.10 |
| A2 | a2_yosys | Yosys 0.68+136 (git sha1 c30457480-dirty, Release, Clang /usr/bin/clang++ 21.1.8) |
| A2 | a2_yosys_oss | Yosys 0.68+136 (git sha1 c30457480-dirty, Release, Clang /usr/bin/clang++ 21.1.8) |
| A2 | a2_verilator | Verilator 5.050 2026-07-01 rev conda-forge build 0 |
| A2 | a2_nextpnr_ecp5 | "nextpnr-ecp5" -- Next Generation Place and Route (Version nextpnr-0.11.1-18-gdec04b3b) |
| A3 | a3_python | Python 3.12.10 |
| A3 | a3_a10_quartus | Quartus Prime Shell/Pro 21.4.0 Build 67 12/06/2021 |

## 3. 输入与 SHA

| 输入 | 当前 SHA-256 |
| --- | --- |
| `fpga/opensynth/a1_generic_synth_stats.json` | `a5c27ff87bc78a55a940326abf91155762538d645e4529b7e155cb25ad4da300` |
| `fpga/opensynth/a2_soc_stub_stats.json` | `d8c66aac65b0fbdeba99e4c22a3922b59a5b0aaa042a920ca0a670e4c059db6f` |
| `fpga/opensynth/a3_correlation_data.json` | `6c5b052ea941641bc65bd1f1e723f572e244ce3063f0416b8b68dced213bd152` |
| `fpga/opensynth/a2_soc_stub_manifest.md` | `d9cb3daa6ba9fb830ffe3e2b0411f3ee2ed4d02647be2f821b64a850735e1072` |

A3 记录哈希守卫结果：

| 校验项 | 状态 |
| --- | --- |
| `fpga/opensynth/a1_generic_synth_stats.json` vs A3 | pass |
| `fpga/opensynth/a2_soc_stub_stats.json` vs A3 | pass |
| `fpga/opensynth/a2_soc_stub_manifest.md` vs A3 | pass |

## 4. A1 运行间差分（两跑重复性）

### `lcvex_axi4_master`

- run_count：2
- metrics_equal：True
- netlist_sha_equal：True
- status：**pass**

| 字段 | run1 | run2 | delta | same |
| --- | ---: | ---: | ---: | --- |
| abc_report_lut | 1870 | 1870 | 0 | True |
| area | N/A | N/A | N/A | True |
| dff | 2406 | 2406 | 0 | True |
| dsp | N/A | N/A | N/A | True |
| lut4 | 1870 | 1870 | 0 | True |
| num_cells | 4276 | 4276 | 0 | True |
| num_memories | 0 | 0 | 0 | True |
| num_memory_bits | 0 | 0 | 0 | True |
| num_port_bits | 3010 | 3010 | 0 | True |
| num_ports | 56 | 56 | 0 | True |
| num_wire_bits | 7000 | 7000 | 0 | True |
| num_wires | 1646 | 1646 | 0 | True |
| ram_bits | 0 | 0 | 0 | True |

### `lcvex_mem_arb`

- run_count：2
- metrics_equal：True
- netlist_sha_equal：True
- status：**pass**

| 字段 | run1 | run2 | delta | same |
| --- | ---: | ---: | ---: | --- |
| abc_report_lut | 20 | 20 | 0 | True |
| area | N/A | N/A | N/A | True |
| dff | 3 | 3 | 0 | True |
| dsp | N/A | N/A | N/A | True |
| lut4 | 20 | 20 | 0 | True |
| num_cells | 23 | 23 | 0 | True |
| num_memories | 0 | 0 | 0 | True |
| num_memory_bits | 0 | 0 | 0 | True |
| num_port_bits | 432 | 432 | 0 | True |
| num_ports | 14 | 14 | 0 | True |
| num_wire_bits | 449 | 449 | 0 | True |
| num_wires | 26 | 26 | 0 | True |
| ram_bits | 0 | 0 | 0 | True |

### `lcvex_mem_delay`

- run_count：2
- metrics_equal：True
- netlist_sha_equal：True
- status：**pass**

| 字段 | run1 | run2 | delta | same |
| --- | ---: | ---: | ---: | --- |
| abc_report_lut | 63 | 63 | 0 | True |
| area | N/A | N/A | N/A | True |
| dff | 241 | 241 | 0 | True |
| dsp | N/A | N/A | N/A | True |
| lut4 | 63 | 63 | 0 | True |
| num_cells | 304 | 304 | 0 | True |
| num_memories | 0 | 0 | 0 | True |
| num_memory_bits | 0 | 0 | 0 | True |
| num_port_bits | 424 | 424 | 0 | True |
| num_ports | 14 | 14 | 0 | True |
| num_wire_bits | 725 | 725 | 0 | True |
| num_wires | 48 | 48 | 0 | True |
| ram_bits | 0 | 0 | 0 | True |

## 5. A2 运行间差分（两跑重复性）

- module：`lcvex_catapult_soc_stub_top`
- run_count：2
- metrics_equal：True
- netlist_sha_equal：True
- status：**pass**

| 字段 | run1 | run2 | delta | same |
| --- | ---: | ---: | ---: | --- |
| num_cells | 0 | 0 | 0 | True |
| num_memories | 0 | 0 | 0 | True |
| num_memory_bits | 0 | 0 | 0 | True |
| num_port_bits | 2627 | 2627 | 0 | True |
| num_ports | 109 | 109 | 0 | True |
| num_processes | 0 | 0 | 0 | True |
| num_pub_wire_bits | 2627 | 2627 | 0 | True |
| num_pub_wires | 109 | 109 | 0 | True |
| num_submodules | 0 | 0 | 0 | True |
| num_wire_bits | 2627 | 2627 | 0 | True |
| num_wires | 109 | 109 | 0 | True |

- A2 Verilator 只有单次记录，无法做运行间差分：N/A。
- A2 ECP5 nextpnr 只有单次失败记录，无法做运行间差分；Fmax 仍为 N/A。

## 6. 阈值守卫明细

| ID | 描述 | 状态 |
| --- | --- | --- |
| `a1-two-run-determinism` | Each A1 module must produce identical metrics and netlist SHA256 across its two recorded runs. | **pass** |
| `a2-two-run-determinism` | A2 boundary-stub generic synthesis must produce identical metrics and netlist SHA256 across its two recorded runs. | **pass** |
| `a1-vs-a3-consistency` | A1 statistics must still match the values recorded in the A3 correlation report. | **pass** |
| `a2-vs-a3-consistency` | A2 boundary-stub statistics must still match the values recorded in the A3 correlation report. | **pass** |
| `a3-input-hash-stability` | Current A1/A2/A2-manifest file hashes must equal the hashes recorded in A3. | **pass** |
| `no-a10-resource-or-fmax-threshold` | No A10 ALM/register/RAM/Fmax threshold is defined or enforced. A-line thresholds are proxy-internal only. | **pass** |
| `temporal-trend-baseline` | A true trend requires at least two A4 snapshots (a prior baseline plus this run). | **N/A** |

## 7. 趋势

- 状态：**N/A**
- 原因：No previous A4 snapshot was supplied; this is the first baseline and no temporal trend can be claimed.
- 当前输出已可作为后续 A4 趋势回归的 baseline；当前无第二个时间点，不输出 delta/百分比。

## 8. 限制

- A1 did not synthesize lcvex_core or lcvex_l2; there is no complete core/cache/SoC open-source proxy.
- A2 is a 0-cell boundary stub; it is not a real SoC area proxy.
- No prior A4 snapshot exists in this worktree, so temporal trend is N/A.
- Run-to-run repeatability is determinism, not a time-series improvement or regression trend.
- Generic 4-LUT/FF counts are not Arria 10 or ECP5 vendor resource counts.
- A2 ECP5 nextpnr failed at IO packing; no Fmax is claimed.
- This report is not Arria 10 signoff, does not replace Quartus, and does not unblock T-067.

## 9. 审计说明

- 结构化数据见 `fpga/opensynth/a4_trend_thresholds.json`。
- 可复跑命令：`python3 scripts/opensynth/trend_diff.py --base-sha 7c847561d3de3edeee0f7f8937fd3929fc101ba6 --head-sha 3a1c66e7786391d8f3cde287c72c7e986115e384`。

- 本报告只读分析既有 A1/A2/A3 artifact，未运行任何合成/布局布线/Quartus。
