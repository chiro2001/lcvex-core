# T-20260829-074 A0 开源综合工具链能力矩阵与可行性验证（handoff）

- 状态：review（owner 完成，待集成者复核）
- 任务：T-20260829-074
- base SHA：`3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2`
- head SHA：`42622212067c6939f972eda1c8bd40f2d6b51e4c`
- 分支：`feature/T-20260829-074-a0-toolchain-capability`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-074`
- 完成时间：2026-08-29T02:15:53+0800（捕获时间；精确 evidence 见 JSON）

## A0 结论（go/no-go）

- **Verilator（5.050，项目固定 conda 版）可以消费当前 SV 特性与真实模块。**
  已通过：
  - 最小 SystemVerilog 样例；
  - package/packed struct/enum 样例；
  - interface/modport 样例（Verilator 可解析；无硬件接口语义问题）；
  - 真实 `lcvex_axi4_master` 与 `lcvex_l2` lint。
  完整 `lcvex_core` + `rtl/filelist.f` 的 `--lint-only` 在本 worktree 通过
  （exit 0，walltime 551.6s）。`lcvex_catapult_soc_top` 全量 lint 完成
  elaboration 但因 12 个 warning（UNSIGNED/MULTIDRIVEN）退出 1，不是语法不支持。
- **Yosys 直接读当前 RTL 为 NO-GO。** 0.66/0.68 均在以下位置失败：
  - `package/import`：`unexpected TOK_IMPORT`；
  - `interface/modport` 端口：语法错误；
  - `lcvex_core.sv` unpacked array 端口（`logical [63:0] fp_v_lo [0:31]`）：
    unexpected `[`。
  因此 A1 核心/Cache generic synth 不能直接以 `yosys read_verilog -sv rtl/...` 起步。
- **sv2v 本环境不可用。** AUR 源包存在但需要 GHC/Haskell 依赖，配置的 TUNA
  镜像对多个 `haskell-*` 包返回 404，安装失败；oss-cad-suite 中也没有 sv2v 二进制。
- **nextpnr-ecp5（0.11.1-18，oss-cad-suite 20260828）可用**，并在最小计数器上完成
  ECP5 LFE5U-85F pack/place/route smoke。该结果只是 ECP5 代理，不是 Arria 10，
  不替代 Quartus，不解除 T-067。
- **Icarus Verilog** 可处理 package/struct，但不能处理 interface/modport、SVA
  concurrent assertion、`inside` 表达式，不能作为全 RTL 解析器。
- **VTR 包（VPR 9.0.0）已安装**，A0 未运行完整 VTR flow；如需，应在 A1/A2 按
  VTR 架构 XML + 流程另外验证。

## 能力矩阵要点

| 特性 | Verilator 5.050 | Yosys 0.66/0.68 | Icarus 13/14 | sv2v | 备注 |
| --- | --- | --- | --- | --- | --- |
| 基本 SV/parameter/always_ff | PASS | PASS（plain subset） | PASS | N/A | 最小样例 |
| package + import | PASS | FAIL | PASS（pkg_struct） | N/A | Yosys blocker |
| packed struct / enum | PASS | FAIL（被 import 先行阻断） | PASS | N/A | |
| interface + modport | PASS | FAIL | FAIL | N/A | 当前 rtl/ 未用 |
| unpacked array ports | PASS | FAIL | 未单独验证 | N/A | core 有此类端口 |
| SVA concurrent assertion | PASS（lint 环境） | N/A | FAIL | N/A | |
| `inside` 表达式 | PASS（Verilator 广泛支持） | 未到该层 | FAIL | N/A | |

## A1 fallback 建议

1. 首选获得可用的 `sv2v` 二进制（或预编译 package）；然后用 `sv2v` 将
   `lcvex_pkg.sv` + 目标模块转换为普通 Verilog，再进 Yosys。
2. 若获取不到 sv2v，则 A1 应建立“生成式扁平视图”：在 `fpga/opensynth/**`
   内由脚本把 package struct/import 展开、把 unpacked array 端口改为普通
   向量端口/总线；**不得修改 `rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv` 或
   `rtl/filelist.f` 的语义**。
3. nextpnr-ecp5 只在 Yosys 能产出 ECP5 JSON 后用于 ECP5 代理；关键路径/Fmax
   只能标 ECP5，不能标 A10。
4. 厂商 IP 仍按 blackbox/stub 处理；A0 未在 `rtl/*.sv` 中发现 Altera 原语，
   但 SoC 顶层暴露 Avalon/EMIF/JTAG-UART 端口，这些在 A2 需要外部 stub。

## 主要产物

- `fpga/opensynth/toolchain.lock`：工具/版本/来源/SHA256。
- `fpga/opensynth/capability.json`：完整尝试矩阵、失败原因、fallback、输入 SHA。
- `fpga/opensynth/examples/`：`minimal_counter.sv`、`sv_pkg_struct.sv`、`sv_features.sv`。
- `fpga/opensynth/logs/`：Verilator/Yosys/Icarus/nextpnr 实际输出。
- `fpga/opensynth/artifacts/`：最小 ECP5 网表/报告/routed JSON 证据。
- `fpga/opensynth/README.md`、`fpga/opensynth/scripts/run_a0.sh`、
  `fpga/opensynth/scripts/collect_hashes.sh`。
- `docs/tasks/evidence/T-20260829-074.json`：结构化证据。

## 风险 / 限制

- 完整 Verilator `lcvex_core` lint 已通过（walltime 551.6s）；SoC 全量
  lint 因现有 RTL warning 退出 1，未在 A0 修改 RTL。ECP5 结果仅为代理。
- ECP5 nextpnr 数据仅来自最小计数器；不是 LCVEX RTL，不能外推 A10。
- `sv2v` 缺失是当前直接 Yosys 综合路径的最大外部依赖。

## 结构化元数据

```text
task=T-20260829-074 state=review base=3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2 head=42622212067c6939f972eda1c8bd40f2d6b51e4c branch=feature/T-20260829-074-a0-toolchain-capability worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-074 sent_at=2026-08-29T01:47:44+0800 received_at=2026-08-29T01:52:00+0800 reported_at=2026-08-29T02:15:53+0800 files=fpga/opensynth/toolchain.lock,fpga/opensynth/capability.json,fpga/opensynth/README.md,fpga/opensynth/examples/*,fpga/opensynth/scripts/*,fpga/opensynth/logs/*,docs/handoffs/T-20260829-074-a0-toolchain-capability.md,docs/tasks/evidence/T-20260829-074.json tests=verilator-lint(sample+real-module+full-core) PASS;yosys-read(sample synth) PASS on plain SV; yosys-read(real RTL) FAIL; iverilog(sample) PASS; iverilog(real core/l2) FAIL; nextpnr-ecp5 minimal smoke PASS blockers=sv2v unavailable;Yosys cannot parse package/import/interface/unpacked-array;no A10 device model next=A1 needs sv2v or generated flatten view; then core/cache generic synth; ECP5-only proxy
```
