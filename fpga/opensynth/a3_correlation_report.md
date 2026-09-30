# A3 开源代理与 A10 基线相关性报告

- 任务：T-20260829-083（A3）
- 状态：review（owner 完成，待集成者复核）
- 分支：`feature/T-20260829-083-a3-correlation-report`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-083`
- base：`54d1ccf0c2c67e504d5b8528eac37a249bc45221`
- 说明：本报告只做**方向性对比**：A1 通用 Yosys/ABC 模块统计、A2 SoC boundary/stub 清单，与 T-064/A10 真实资源/STA 的相对排序、占比和趋势。**禁止**将 ECP5/Yosys/ABC 数字线性换算成 A10 资源或 Fmax。

## 1. 结论摘要

1. A1 代理集合中，`lcvex_axi4_master` 的 generic 4-LUT/FF 占比最高，其次为 `lcvex_mem_delay`、`lcvex_mem_arb`；排序在同一 Yosys/ABC generic 代理口径内稳定（两次运行 netlist SHA 一致）。
2. A1 已合成的模块整体呈“寄存器重、无 DSP 映射、RAM 未映射”特征；T-064 A10 真实 fit 同样显示 8,641 registers > 4,468 ALMs、0 DSP，但因为 ALM 与 generic 4-LUT 不是同一度量，**只能看趋势，不能换算比例**。
3. A2 stub 是 0-cell 边界清单（109 ports / 2627 port bits），不是逻辑面积代理；A10 fit 的 141 pins 是封装引脚数，二者不可直接比较。A2 的 ECP5/nextpnr 因 2627 port bits 超过 LFE5U-85F 的 365 I/O 而失败，Fmax 为 N/A。
4. A3 不运行 Quartus/Yosys/nextpnr，不新增任何 A10 Fmax 声明；T-064 的 STA/Fmax 仅作为外部方向参考引用。

## 2. 工具版本

| 来源 | 工具 | 版本 |
| --- | --- | --- |
| A1 | Yosys | 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1) |
| A1 | ABC | UC Berkeley ABC 1.01 (compiled Jun 19 2026 19:18:10) |
| A2 | Yosys (OSS) | 0.68+136 (git sha1 c30457480-dirty, Clang 21.1.8) |
| A2 | Verilator | 5.050 2026-07-01 rev conda-forge build 0 |
| A2 | nextpnr-ecp5 | nextpnr-0.11.1-18-gdec04b3b |
| T-064 | Quartus Prime Pro | 21.4.0 Build 67 12/06/2021 |
| 分析 | Python | 3.12.10 |

## 3. 输入与 SHA

| 输入 | SHA-256 |
| --- | --- |
| `fpga/opensynth/capability.json` | `3ff9ce1512f979233307e0b89f4fdc6f6ca42553a72c4e2a680eb5519b0e7195` |
| `fpga/opensynth/a1_generic_synth_stats.json` | `a5c27ff87bc78a55a940326abf91155762538d645e4529b7e155cb25ad4da300` |
| `fpga/opensynth/a2_soc_stub_stats.json` | `d8c66aac65b0fbdeba99e4c22a3922b59a5b0aaa042a920ca0a670e4c059db6f` |
| `fpga/opensynth/a2_soc_stub_manifest.md` | `d9cb3daa6ba9fb830ffe3e2b0411f3ee2ed4d02647be2f821b64a850735e1072` |
| `docs/tasks/archive/T-20260828-064.json` | `a91823adda033edeb3d36a58c0042ba2f92f67d2d410dd66cad03cb868ff9069` |
| `docs/tasks/evidence/T-20260828-064.json` | `29c18485dc2d94941c8a778601abc3380f7f23b346a2bb5aa6a7a7c29259a4e6` |
| `docs/handoffs/T-20260828-064-catapult-fullflow.md` | `eb262d71c97f4d671f6df12fa8332d91da050c1454778b68ed54a9968177fc27` |

## 4. 数据总览

### 4.1 A1：通用 Yosys/ABC 4-LUT 代理

| 模块 | 配置 | LUT(4) | FF | RAM bits | DSP | Area | 两次 netlist hash |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `lcvex_axi4_master` | ADDR=64, DATA=128, ID=4, MAX_BURST_LEN=16 | 1870 | 2406 | 0 | N/A | N/A | `fa60ea1e...b981a` |
| `lcvex_mem_delay` | DELAY_MODE=1, RAND_MAX=4, SEED=8'hA5 | 63 | 241 | 0 | N/A | N/A | `f91a7c94...e365` |
| `lcvex_mem_arb` | PORTS=3 | 20 | 3 | 0 | N/A | N/A | `771400d9...c6ab` |

A1 代理内部占比（仅用于排序/趋势，不换算 A10）：

| 模块 | LUT 占比 | FF 占比 |
| --- | ---: | ---: |
| `lcvex_axi4_master` | 95.75% | 90.79% |
| `lcvex_mem_delay` | 3.23% | 9.09% |
| `lcvex_mem_arb` | 1.02% | 0.11% |

### 4.2 A2：SoC boundary/stub

| 指标 | 值 |
| --- | ---: |
| Generic stub module | `lcvex_catapult_soc_stub_top` |
| Yosys generic synth cells | 0 |
| Ports / port bits | 109 / 2627 |
| 两次 Yosys 稳定性 | 一致（netlist SHA `d0c0ff14...9d33`） |
| Verilator real SoC tie-off elaboration | PASS（exit 0） |
| ECP5 nextpnr | FAIL（exit 125，IO 超限） |
| ECP5/A10 Fmax | N/A |

### 4.3 T-064 A10 真实资源/STA（方向参考）

- 器件：`10AX115N4F40E3SG`
- Full flow：`quartus_sh --flow compile catapult_a10 -c catapult_a10`，exit 0，0 errors / 68 warnings
- Fit：4,468 ALMs / 8,641 registers / 141 pins / 27 RAM blocks / 0 DSP / 3 PLLs
- STA：worst setup +0.220 ns（EMIF core user clock，Slow 900mV 100C）；worst hold +0.017 ns（sys_clk_50，Fast 900mV 0C）；recovery +0.53 ns；removal +0.112 ns；min pulse +0.12 ns
- T-064 记录 Fmax：sys_clk_50 213.49 MHz、clk_y3 499.25 MHz、EMIF core user clock 283.29 MHz、EMIF core cal master clock 266.88 MHz
- 以上为 T-064 真实 Quartus signoff 记录；A3 不新增、不推导、不声称 A10 Fmax。

## 5. 相关性观察

| 编号 | 观察 | 可用于 | 不可用于 |
| --- | --- | --- | --- |
| C1 | A1 代理内排序：AXI4 > mem_delay > mem_arb（LUT 与 FF 均一致） | 识别开源可综合代理内的相对热点 | 推断 A10 模块排序（T-064 无模块级 fit 分解） |
| C2 | A1 代理寄存器占比高；A10 fit 也表现为 registers > ALMs | 定性确认控制/缓冲逻辑可能偏寄存器化 | 计算 A10 寄存器/LUT 换算系数 |
| C3 | A1 DSP N/A；A10 fit 0 DSP | 无矛盾 | 推导 DSP 占比 |
| C4 | A1 RAM 0 bits；A10 27 RAM blocks | 说明 A1 未做器件内存映射 | 比较内存容量/占比 |
| C5 | A2 boundary 2627 port bits vs A10 141 pins | 说明 A2 是内部总线边界清单而非封装引脚清单 | 预测 A10 引脚/面积 |
| C6 | A2 0-cell stub | 验证端口/边界可镜像 | 估算真实 SoC 面积 |
| C7 | Verilator 可 elaboration 真实 SoC top；Yosys 直接解读当前 SV 受阻；ECP5 nextpnr 因 IO 超限失败 | 明确 A 线工具链边界 | 作为 A10 timing/资源预测 |

## 6. 关键路径 / 时序

- A1：`N/A`。未用 ABC delay 作为 Fmax；A1 只交付逻辑统计代理。
- A2：`N/A`。ECP5 nextpnr 未完成布线，无 Fmax。
- A10：引用 T-064 STA（见上）；A3 不声称 A10 Fmax。

## 7. 限制

1. A1 未综合 `lcvex_core`、`lcvex_l2`，因此没有完整 core/cache/SoC 的开源资源代理。
2. Generic 4-LUT/FF 不是 A10/ECP5 厂商资源；ALM 与 LUT 不可直接换算。
3. A2 stub 是边界清单，0 cell；不能代表真实 SoC 面积。
4. A2 ECP5 失败，Fmax N/A。
5. T-064 是远端 Quartus full-flow/STA，只作为方向参考；其 fit 未提供模块级资源分解。
6. 本报告没有运行 Quartus/Yosys/nextpnr；不替代 Quartus、不解除 T-067。

## 8. 建议

- 将 A1/A2 用作**开源可综合子集和外部 IP 边界的审计清单**，不要用作 A10 面积/时序预算。
- 后续若需模块级 A10 资源趋势，应使用 Quartus hierarchical report 或由 T-067/板级验证；开源代理不能替代。
- A4 若启用，阈值应限制在代理内部可重放不变量（Yosys netlist/stat hash、stub 端口清单稳定），不要设置 A10 资源/Fmax 阈值。
- 继续保留 T-067 blocked 状态；本报告不产生任何解除或放行依据。

## 9. 审计说明

- 结构化数据见 `fpga/opensynth/a3_correlation_data.json`。
- 双写 handoff/evidence：`docs/handoffs/T-20260829-083-a3-correlation-report.md`、`docs/tasks/evidence/T-20260829-083.json`。
- 本报告为只读分析；未修改 RTL、Makefile、Quartus 工程。
