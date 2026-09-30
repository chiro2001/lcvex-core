# T-20260829-090 Verilator 卡顿诊断结论

## 一句话结论

Verilator 5.050 默认优化（`-O1`）在展开/优化 `rtl/lcvex_fp_scalar.sv` 的
256-bit 定点浮点组合逻辑时耗时爆炸；每个 `lcvex_core` 都含一个该模块，所以
双核 `lcvex_c2_dualcore_tb` 在 elaboration/Verilation 阶段长时间 99% CPU、
不产 `Vtop.mk`。该问题**不是**双核/coherence/assert/timing 本身引起。

使用 `-O0` 可把 Verilator 前端从原来的 >10 分钟（未完成）降到约 8 秒，
完整双核 binary 的 C++ 编译再加约 2 分钟即可产出可执行文件。

## 环境

- 日期：2026-08-29（Asia/Shanghai）
- Worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090`
- 分支：`feature/T-20260829-090-verilator-stuck-diagnose`
- HEAD：`6fb1d5f0d19b543e26f6ce2d86a490c4e000b67f`
- Verilator：`5.050 2026-07-01 rev conda-forge build 0`
- CPU：12 线程；内存 29Gi（诊断时约 11Gi available）
- 观察中的外部进程：
  - T-086 完整双核默认构建 `verilator_bin` 已 >1 小时仍 99% CPU，无 `Vtop.mk`。
  - T-085 Cocotb SoC 构建也在 99% CPU 长时间未完成（现象同因：SoC 含真实 core + fp_scalar）。

## 复现/度量

所有实验使用工作区内 `tmp_build` 作为 `TMPDIR`，每个实验带 `timeout`。
命令和日志在 `diag/verilator_stuck/logs/`。

### 单模块计时（`--lint-only --no-assert --no-timing`）

| 模块 | 结果 | 耗时 | 说明 |
|---|---|---|---|
| `lcvex_decode` | pass | 0.312s | 很快 |
| `lcvex_neon_int` | pass | 0.387s | 很快 |
| `lcvex_alu` | pass | 0.118s | 很快 |
| `lcvex_muldiv` | pass | 0.092s | 很快 |
| `lcvex_mmu` | pass | 0.099s | 很快 |
| `lcvex_fp_state` | pass | 0.108s | 很快 |
| **`lcvex_fp_scalar`** | **timeout 300s** | **>300s** | **唯一重模块** |

### 单完整 core 计时（`--lint-only --no-assert --no-timing`）

| 变体 | 耗时 | 结果 |
|---|---|---|
| 真实 `lcvex_fp_scalar.sv` + 默认优化 | >8min 未完成（手工终止） | 慢 |
| 真实 `lcvex_fp_scalar.sv` + **`-O0`** | **2.889s** | 通过 |
| 用诊断 stub 替换 `lcvex_fp_scalar` + 默认优化 | **1.167s** | 通过 |

### 分层（去掉 fp_scalar 后）

用相同接口的诊断 stub 替换 `lcvex_fp_scalar` 后：

| 顶层 | 耗时 |
|---|---|
| `lcvex_cluster_top` CORE_COUNT=1 | 1.262s |
| `lcvex_cluster_top` CORE_COUNT=2 | 1.975s |
| `lcvex_cluster_top` CORE_COUNT=2 + COHERENCE_ENABLE=1 | 2.715s |

说明双核壳层、共享 L2/MSI、L1 coherence 本身对 Verilator 都不构成瓶颈。

### 完整双核 `lcvex_c2_dualcore_tb`

| 构建 | 结果 |
|---|---|
| 默认优化（无 `-O0`） | 300.003s timeout 未产任何文件（`tmp_build/dual_default` 文件数为 0）（关联 T-086 已 1h+ 无产物） |
| `-O0 -Wno-fatal -Wno-UNOPTFLAT` | Verilator 前端约 7.8s 生成全部 C++；C++ 编译约 118s；改用 `make AR=ar` 完成链接，产出 `lcvex_c2_dualcore_tb`（14MB） |
| 运行上述 O0 binary | 2ms 模拟结束，但 directed test 报 3 个 FAIL（core 未观察到 flag / 无 progress） |

## 根因定位

- 关键文件：`rtl/lcvex_fp_scalar.sv`
- 关键构造：
  - `localparam integer FP_W = 256;`（第 53 行）
  - `round_pack`、`binary_op`、`fma_op`、`sqrt_op`、`div_op`、`half_lane_calc`、
    `fcvt_op2` 等多个 combinational function 使用 `logic [255:0]` 中间量。
  - 多个 `for (i = 0; i < FP_W; i++)` / `for (i = FP_W-1; i >= 0; i--)` 在
    always_comb 或函数内展开（第 105、121、255、349、1054、1241、1439 行等）。
- Verilator 默认优化会把这些宽位函数内联、展开、做常量/时序优化，导致 CPU
  长时间 99%、内存逐步增长，但始终不进入 C++ 编译阶段。
- 该模块位于每个 `lcvex_core` 内，所以双核等于两份重逻辑叠加；`lcvex_cluster_top`
  和 coherence 不是主因。

## 建议

1. **立即规避**：在本机/CI 跑含真实 core 的 Verilator 构建时加 `-O0`，并经
   `make AR=ar` 修复 C1 已记录的缺 `x86_64-conda-linux-gnu-ar` 问题。
   实测单 core lint 从 >8min 降到 2.9s，双核 binary 约 2 分钟可产出。
2. **长期**：重构 `lcvex_fp_scalar.sv`，降低组合展开规模：
   - 将 FP_W 从 256 降到精确 IEEE 双精度所需的 128/160 位左右，并避免在
     function 中展开 256 次循环；
   - 或把 FP 执行拆成多周期状态机/流水线，使 Verilator 不需要一次性展开巨型组合逻辑；
   - 或将纯 RTL 验证与 FP 单元解耦：核级/多核验证可在非 FP 构建中 stub FP 单元
     （当前参数 `A64_FP_SIMD` 并未真正省略 `lcvex_fp_scalar` 实例，需增加条件实例化）。
3. **注意副作用**：`-O0` 会禁用 gate optimization，当前 C2 coherence 的
    `lcvex_l1_coherence.sv`/`lcvex_cluster_top.sv` 会出现 `UNOPTFLAT` 警告，
   路径为 `cl_req_valid -> probe_req_source_id -> l1coh -> cl_req_valid` 的
   单块 always_comb 敏感性环。构建可加 `-Wno-UNOPTFLAT`，但定向测试当前
   O0 binary 未通过，说明该组合环/测试时序仍需单独修查，不能把 O0 binary
   当作功能通过证据。
4. **不要删除 `--assert`/`--timing` 作为主要优化**：本诊断显示 `--assert/--timing`
   不是卡顿原因；`lcvex_fp_scalar` 的默认优化才是。

## 关键文件

- `rtl/lcvex_fp_scalar.sv`
- `rtl/lcvex_cluster_top.sv`
- `rtl/lcvex_l1_coherence.sv`
- `rtl/lcvex_core_wrap.sv`
- `tb/sv/lcvex_c2_dualcore_tb.sv`
- 本目录：`repro.sh`、`stubs/lcvex_fp_scalar_stub.sv`、`logs/`
