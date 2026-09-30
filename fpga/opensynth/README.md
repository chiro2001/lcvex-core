# LCVEX OpenSynth 目录

本目录存放开源综合/PPA 代理线的 A0 能力矩阵、A1 通用综合代理产物和 A2
SoC stub/tie-off 顶层开源 elaboration 代理。
**所有结果都不是 Arria 10 签核，不替代 Quartus / T-067 / Gate F-BOARD。**

## A0：开源综合工具链能力矩阵（T-20260829-074）

- `toolchain.lock`：工具版本、来源、SHA256、路径、可用性。
- `capability.json`：完整能力矩阵、命令、结果、失败原因、fallback。
- `examples/`：最小 SV 与特性样例。
- `logs/`：各工具实际输出。
- `artifacts/`：最小 ECP5 网表/报告/routed JSON（ECP5 smoke 证据）。
- `scripts/run_a0.sh`：可复跑的核心命令（轻量部分）。
- `scripts/collect_hashes.sh`：输入 SHA 收集。

### A0 关键结论

- Verilator 5.050（项目 conda 固定版）可消费 SystemVerilog package / packed struct /
  interface / modport，并已通过真实模块 `lcvex_axi4_master`、`lcvex_l2` 的 lint。
  完整 `lcvex_core` + `rtl/filelist.f` 的 `--lint-only` 在本 worktree 也通过
  （exit 0，walltime 551.6 s）。
  `lcvex_catapult_soc_top` 全量 lint 能完成 elaboration，但以 12 个 warning
  （UNSIGNED、MULTIDRIVEN）退出 1，不是 SV 语法失败。
- Yosys（0.66 系统包 / 0.68+136 oss-cad-suite）不能直接读取当前 RTL：
  - `package/import` 报 `unexpected TOK_IMPORT`；
  - `interface/modport` 端口报语法错误；
  - `lcvex_core.sv` 的 unpacked array 端口 `logic [63:0] fp_v_lo [0:31]` 报
    unexpected `[`。
- Icarus Verilog 可以处理简单 package/struct（`sv_pkg_struct`），但不能处理
  interface/modport、SVA concurrent assertion、`inside` 表达式，因此不能作为
  LCVEX 全 RTL 的通用解析器。
- sv2v 在本环境不可用；AUR 源包因镜像缺少 Haskell 包文件失败。
- nextpnr-ecp5 0.11.1-18（oss-cad-suite 20260828）在最小计数器上完成 ECP5
  smoke（LFE5U-85F）：pack + place + route 成功，报告仅作 ECP5 代理，
  不是 Arria 10。

## A2：SoC Stub/Tie-off 与顶层开源 Elaboration（T-20260829-081）

- `rtl/lcvex_catapult_soc_tieoff.sv`：包住真实
  `rtl/lcvex_catapult_soc_top.sv` 的 Verilator 级 tie-off wrapper；把
  EMIF/calibration、Avalon、JTAG-UART、EPCQ/SFL、程序/调试和 checkpoint
  外部输入全部接为常量，只保留 `clk`/`rst_n` 作为 harness 输入。
- `rtl/lcvex_catapult_soc_stub_top.v`：普通 Verilog 的边界 stub，镜像真实
  SoC 顶层端口（109 ports / 2627 port bits），所有输出接 inactive 常量，
  供 Yosys generic synth / ECP5 可行性尝试使用。
- `filelist_soc_tieoff.f`、`filelist_soc_stub.f`。
- `lcvex_catapult_soc_stub.ys`：generic 4-LUT synth 脚本。
- `a2_soc_stub_manifest.md`：未支持 IP/stub 边界清单。
- `a2_soc_stub_stats.json`：输入 SHA、工具版本、Verilator、Yosys 和 ECP5 记录。
- `scripts/opensynth/run_opensynth_a2.py`：A2 可复跑入口。

### A2 结论

- Verilator 通过 tie-off wrapper 对真实 SoC 顶层完成 elaboration（lint 以
  `-Wno-fatal` 退出 0，保留原有 UNSIGNED/MULTIDRIVEN 类 warning 作为已知项）。
- Yosys generic 4-LUT synth 只对普通 Verilog 边界 stub 通过（0 logic cells；
  stub 仅常量化输出）。真实 SoC 因 A0 已记录的 package/import/unpacked-array
  解析限制不能直接给 Yosys；本任务不修改 RTL。
- `nextpnr-ecp5` 可用，但边界 stub 的 2627 port bits 超出 ECP5
  LFE5U-85F 的 365 I/O，pack 阶段无法放置全部 `TRELLIS_IO`；因此
  **Fmax = N/A**，不伪造 ECP5/A10 结果。
- 只有 `fpga/opensynth/**` 与 opensynth 脚本被写入；RTL 语义未变。

## A1：通用 Yosys/ABC Proxy（T-20260829-080）

- `a1_generic_synth_stats.json`：模块统计、双跑 hash、工具版本。
- `generated/`：Yosys 可读的 flat view（不修改 RTL 源语义）。
- `*.ys`：每个模块的 Yosys 脚本。
- `scripts/opensynth/run_opensynth_a1.py`：flat 生成 + 双跑 + 统计的重放入口。

### A1 方法

1. 将相关 SystemVerilog package(s) 展开为文件级声明，移除 `package`/`import`/`::`，
   使 Yosys 可读。
2. 对 Yosys 0.66 做窄范围的语法兼容转换：
   - `lcvex_mem_arb`：替换 priority function 中的 `return`，并把 struct-array
     `always_comb` 改为 default `PORTS=3` 的连续赋值；
   - `lcvex_mem_delay`：使用 `DELAY_MODE=1`（真实非直通内存延迟注入配置）；
   - `lcvex_axi4_master`：仅做 package 展开，不做 RTL 语义转换。
3. 每个模块用 `synth -top <module> -lut 4` 跑两次，记录 LUT/FF/RAM/统计和
   netlist SHA256；两次结果保持一致。

### A1 结果快照

| 模块 | 配置 | LUT(4) | FF | RAM bits | DSP | Area |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| lcvex_axi4_master | ADDR=64 DATA=128 ID=4 MAXBURST=16 | 1870 | 2406 | 0 | N/A | N/A |
| lcvex_mem_delay | DELAY_MODE=1 | 63 | 241 | 0 | N/A | N/A |
| lcvex_mem_arb | PORTS=3 | 20 | 3 | 0 | N/A | N/A |

### A1 已知阻塞

- `lcvex_core`：Yosys 0.66 无法解析 unpacked-array 端口（`fp_v_lo[0:31]`、
  `fp_v_hi[0:31]`），需要更深端口展开。
- `lcvex_l2`：扁平化后可解析，但完整 generic synth 会把 cache tag/data 数组
  映射为寄存器/门电路并超出本地资源预算；未给出 L2 数字。未来可用
  memory-blackbox 或 `$mem` 保留代理。
- RAM/DSP/area：N/A，因为没有做器件 memory/DSP 映射。
- **不得把 ABC delay 当作 Fmax，不得把 LUT/FF 当作 Arria 10 资源。**

## A4：轻量趋势/差分与阈值守卫（T-20260829-087）

- `scripts/opensynth/trend_diff.py`：只读 A1/A2/A3 既有 JSON，输出运行间差分、输入 SHA、工具版本和阈值检查。
- `a4_trend_report.md`：A4 报告。
- `a4_trend_thresholds.json`：结构化阈值/趋势输出，可作为后续 baseline。
- 本任务**不运行 Yosys/nextpnr/Verilator/Quartus/P&R**；不设 A10 资源/Fmax 阈值；
  当前没有更早 A4 快照，时间趋势为 N/A。

## 复跑

A0：

```sh
OSS=/tmp/oss_cad/oss-cad-suite
export OSS_CAD_SUITE=$OSS
bash fpga/opensynth/scripts/run_a0.sh
```

A1：

```sh
python3 scripts/opensynth/run_opensynth_a1.py
```

A2：

```sh
# 默认会重跑完整 SoC Verilator lint（较慢），两次 Yosys generic synth，
# 并尝试 ECP5（预期因边界 IO 超限而记录 N/A）。
python3 scripts/opensynth/run_opensynth_a2.py

# 如果只需复用已有 Verilator 日志并重跑 Yosys/ECP5：
python3 scripts/opensynth/run_opensynth_a2.py --skip-verilator
```

A4：

```sh
# 只读既有 A1/A2/A3 产物，不运行任何重型综合/P&R/Quartus。
python3 scripts/opensynth/trend_diff.py \
  --base-sha 7c847561d3de3edeee0f7f8937fd3929fc101ba6 \
  --head-sha 3a1c66e7786391d8f3cde287c72c7e986115e384 \
  --branch feature/T-20260829-087-a4-trend-regression
```

后续真正趋势可比对上次 `a4_trend_thresholds.json`：

```sh
python3 scripts/opensynth/trend_diff.py --baseline fpga/opensynth/a4_trend_thresholds.json ...
```
