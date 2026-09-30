# A10 Resource Gate Reevaluation (T-20260902-001)

> 本页由 T-20260902-001 交付，替代仅凭历史 35 GB 先验值的一票否决。所有实验均在远端隔离 probe 中完成，未修改 candidate 原工程。

## 结论

1. 阶段 A（decode-only）PASS：56.8 s，峰值 PM 717.5 MB，0 errors / 96 warnings。
2. 阶段 B（L1D/L2 M20K wrapper standalone）PASS：
   - L1D `SETS=64`：25.2 s，PM 750.8 MB，ALM 9,665，BRAM 32,768 bits。
   - L2 reduced `64x1`：36.3 s，PM 817.5 MB，ALM 9,720，BRAM 32,768 bits。
   - L2 candidate default `256x2`：107.6 s，PM 1,367.2 MB，ALM 39,158，BRAM 262,144 bits。
3. 阶段 C（真实 SoC synthesis）：
   - **candidate 原样执行失败**：`lcvex_fp_scalar` 非定常 loop limit、NEON out-of-range，1m12s 内 elaboration 失败，未到资源阶段；不是 OOM。
   - **隔离 no-FP probe（A64_FP_SIMD=0）PASS**：362 s，PM 2,570.8 MB，ALM 81,552，BRAM 247,276 bits，DSP 21。
   - **隔离 full-FP patch probe 中断**：经兼容补丁后 elaboration 通过并运行 synthesis；54.2 min 后手工停止，峰值 PM 13,238.3 MB，未产出最终资源报告；停止原因是任务收尾，不是安全门限。
4. 重新评估的门限模型：当前 host 安全提交窗口约 36 GB；实测 SoC synthesis 峰值（no-FP 2.6 GB、full-FP 观察 13.2 GB）均低于该窗口。fit/STA/SOF 不再被历史 35 GB 先验阻止，但仍须单作业、逐阶段采样。

## 阶段资源表

| 阶段/工程 | 结果 | wall_s | Peak PM MB | Peak WS MB | Peak VM MB | exit | errors/warnings | 关键资源 |
|---|---:|---:|---:|---:|---:|---:|---|
| A decode_only | PASS | 56.8 | 717.5 | 791.6 | 5786.5 | 0 | 0/96 | ALM 13554, ALUT 16833, reg 0, DSP 3 |
| B l1d_actual | PASS | 25.2 | 750.8 | 799.4 | 5699.0 | 0 | 0/8 | ALM 9665, ALUT 10932, reg 5368, BRAM 32768 |
| B l2_reduced | PASS | 36.3 | 817.5 | 864.3 | 5885.9 | 0 | 0/87 | ALM 9720, ALUT 10701, reg 5962, BRAM 32768 |
| B l2_default | PASS | 107.6 | 1367.2 | 1348.8 | 6382.4 | 0 | 0/87 | ALM 39158, ALUT 38762, reg 29390, BRAM 262144 |
| C real_a10 (default) | FAIL | 71.9 | 2053.1 | 2052.6 | 6816.8 | 3 | elaboration errors | 未到资源阶段 |
| C real_a10_nofp | PASS | 362.0 | 2570.8 | 2562.9 | 7575.6 | 0 | 0/37 | ALM 81552, ALUT 90956, reg 78917, BRAM 247276, DSP 21, PLL 1 |
| C real_a10_patched | INTERRUPTED | 3254.7 | 13238.3 | 12285.4 | 18735.3 | -1 | manual stop | 无最终资源报告 |

## no-FP SoC M20K 摘要

- `soc|bram|u_impl|u_ram`: M20K True Dual Port, 8192x64, 524,288 bits。
- `soc|coh|d_l1|u_data_ram|u_ram`: M20K Single Port, 64x512, 32,768 bits。
- `soc|coh|l2|u_data_ram|u_ram`: M20K Single Port, 64x512, 32,768 bits（L2 默认 256x2 时数据 RAM 为 8 个这样的 M20K 实例）。
- 总 Block Memory Bits 247,276；MLAB 0。

## 门限模型

- **当前安全提交窗口**：`(physical_free + pagefile_available) * 0.8`。
  - 本次快照约 `(31–34 GB + 12.2–12.6 GB) * 0.8 ≈ 34.6–37.3 GB`，取 36 GB。
- **综合峰值**：
  - 最小子模块：<1 GB。
  - 真实 SoC no-FP：2.57 GB。
  - 真实 SoC full-FP（未完成但实测峰值）：13.24 GB。
- **可外推 fit/STA/asm 窗口**：
  - G4 历史 fitter 单进程峰值 15.43 GB、工作集 15.18 GB，低于当前窗口。
  - fit/STA/asm 均需在独立任务中单作业实测；不能从 synthesis 峰值直接线性外推。
- **当前可安全执行边界**：
  - Synthesis（含 full-FP 峰值 13.2 GB）在本 host 可安全启动。
  - Fitter 有窗口余量，但需独立任务，建议 15 s 采样，不并行。
  - STA/ASM 在 fitter 成功后单独运行。
- **仍需外部资源介入的明确条件**：
  1. 实测 full-FP 或 fitter 峰值超过 ~36 GB。
  2. 磁盘空闲低于实际工程/报告需求（当前 D 盘 88 GB，未触发）。
  3. 出现 Quartus elaboration/时序关闭问题（已发现 RTL 兼容 errors，需先修 RTL）。

## 需要外部/集成者处理的 RTL 兼容问题

- `lcvex_fp_scalar.sv` 非定常 loop limit 250 超限（约 line 353）。
- `lcvex_neon_int.sv` / `lcvex_neon_fp.sv` 存在静态 out-of-range lane part-select。
- 在隔离 probe 中已用简单兼容补丁绕过并进入 synthesis，但这些补丁尚未合入主 RTL；建议下个任务正式修复并跑 Verilator/lint。

## 边界

- 未运行 fit/STA/assembler/SOF/JIC/编程。
- 未修改 candidate 原工程；所有实验在 `D:\Projects\fpga-altra\lcvex\build\T-20260902-001-probe\**`。
- 未读取 license 内容；未停止非 EDA 进程。
- 未删除任何文件。
