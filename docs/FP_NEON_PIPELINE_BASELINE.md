# FP/NEON Pipeline Baseline (FP-P0)

> 任务：T-20260902-013（FP-P0-BASELINE-RESOURCE）
> 工作区：`/home/chiro/projects/mycpu/lcvex-wt-T-20260902-013`
> 冻结 SHA：`8aa10fe4c5aa37e23b9d75a695e137e018a9d473`
> 分支：`verify/T-20260902-013-fp-p0-baseline`
> 日期：2026-09-03

本文件记录 FP-P0 的当前 SHA 功能基线、A10 资源分解、FP workload cycle 与 FP issue/busy/response-wait 观测。目标是给 FP-P1 以后的重构提供可复核的基线，不进行 fitter/STA 或性能结论签核。

## 0. 结论摘要

- **No-FP 全 top 综合**：ALM 81,552，comb ALUT 90,956，registers 78,917，DSP 21，block memory 247,276 bits。
- **Scalar FP standalone**：ALM 93,216，comb ALUT 138,582，registers 782，DSP 33。
- **4-lane NEON FP（full-top hierarchy）**：`soc|core|...neon_fp` 合计 comb ALUT 470,056，内含 4 个标量 lane，各约 114K–118K ALUT；合计 DSP 132。独立 Quartus 工程在远端 `T-20260902-013-probe` 中运行中/未取得最终报告，本节使用 T-010 full-top hierarchy 作为可复核分解。
- **Full-FP 全 top 综合**：ALM 482,334，comb ALUT 720,722，registers 80,925，DSP 186；**超出 10AX115N4F40E3SG 的 427,200 ALM（112.91%）**。
- **FP 复制是面积主因**：full-FP `soc|core` comb ALUT 664,210；其中 `fp_scalar` 135,071、`neon_fp` 470,056。NEON 内 4 个 `lcvex_fp_scalar` lane 合计约 464,779 ALUT，加上 core 的 1 个 scalar 单元，共 5 份完整 scalar 单元复制；这与计划 §0 结论一致。
- **P7 功能基线**：当前 SHA 的 SV raw-bit/P7 定向测试全绿；唯一已知红项仍是 T-004/T-008/T-010 已记录的 P7-2 Cocotb `test_p7_2_unsupported_udef` SQADD 被 B2c DUP decode 分支截获，独立修复指向 T-20260902-014。
- **Workload cycle**：`fp_scalar` 173,026，`fp_fp16` 180,441，`neon_vect` 175,737；新增无访存 `neon_fp_chain` 98,801、`scalar_fp16_chain` 94,334。
- **FP busy/wait**：当前 RTL 没有独立 `fp_issue/fp_rsp` 端口；本基线用提交指令编码分类和现有 `fp_div_busy` 推导。只有标量 FDIV 产生多周期等待：`fp_scalar` 中 64 次 FDIV，busy/rsp_wait=16,384 cycles ≈ 256 cycles/FDIV。其它 FP/NEON FP 在当前组合路径下 busy=0。

## 1. 命令与参数

### 1.1 本地功能/性能命令

```sh
# P7 SV raw-bit / 定向（VERILATOR_JOBS=1）
make VERILATOR_JOBS=1 sim-sv-fp-scalar
make VERILATOR_JOBS=1 sim-sv-p7-2-neon
make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp
make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert
make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round

# 现有 perf 镜像 + 自定义 FP 观测 runner
bash scripts/build-microbench.sh build/microbench/perf_fp_scalar.bin   # PERF_ONLY=fp_scalar
bash scripts/build-microbench.sh build/microbench/perf_fp_fp16.bin    # PERF_ONLY=fp_fp16
bash scripts/build-microbench.sh build/microbench/perf_neon_vect.bin  # PERF_ONLY=neon_vect
# 自定义纯计算链在 build/agents/T-20260902-013 下用 aarch64-linux-gnu-gcc 直接构建，
# 并通过 build/microbench_runner/microbench_runner_fp 运行（源码见 evidence）。
```

参数：Verilator 5.050、aarch64-linux-gnu-gcc 16.1.0、`A64_FP_SIMD=1` 默认，`FETCH_FIFO_ENABLE=1`，cache off（`GI_L1_ENABLE=0, GD_L1_ENABLE=0, GL2_ENABLE=0`，`MEM_DELAY_MODE=0`），`PERF_MAX_CYCLES=5,000,000`。

### 1.2 远端 Quartus

装置：10AX115N4F40E3SG，Quartus Prime Pro 21.4.0 Build 67；只运行 synthesis，不运行 fit/STA/assembler/SOF，未读 license，未停止非 EDA 进程，未删除文件。

- Full-FP：`quartus_sh --flow compile real_a10_full_fp -c real_a10_full_fp -start ipgenerate -end synthesis`（T-010 报告）
- No-FP：`quartus_sh --flow compile real_a10_nofp -c real_a10_nofp -start ipgenerate -end synthesis`（T-001 报告）
- Scalar standalone：`quartus_syn --read_settings_files=on --write_settings_files=off fp_scalar -c fp_scalar`（T-008 后续完成报告）
- 4-lane NEON standalone：`quartus_syn ... neon_fp -c neon_fp`（T-013 远端 probe 运行中；当前无最终 summary）

## 2. 资源分解

### 2.1 四组综合资源

| 组 | 来源/源 SHA | ALM | Comb ALUT | Registers | DSP | Block mem bits | Max fanout | Total fanout | Wall | Peak |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| No-FP full top | T-001 probe | 81,552 | 90,956 | 78,917 | 21 | 247,276 | 71,283 | 794,659 | 362.0 s | PM 2,570.8 / WS 2,562.9 / VM 7,575.6 MB |
| Scalar FP standalone | T-008 flow report | 93,216 | 138,582 | 782 | 33 | 0 | 1,464 | 637,124 | 875 s（14:35） | VM 2,368 MB（T-008 观察 PM 约 1,420 MB） |
| 4-lane NEON FP | T-010 full-top hierarchy | n/a（无 standalone ALM） | 470,056 | 0 | 132 | 0 | n/a | n/a | n/a | n/a |
| Full-FP full top | T-010 | 482,334 | 720,722 | 80,925 | 186 | 247,276 | 73,291 | 3,513,505 | 7,374.84 s | PM 12,533.1 / WS 12,152.4 / VM 17,537.0 MB |

> 注：No-FP 与 Full-FP 的 block memory bits 均为 247,276（T-001/T-010 summary）。Full-FP synthesis 的 hierarchy 表中 `soc|core|neon_fp` 的 `Block Memory Bits` 为 0，block memory 主要来自 BRAM/缓存/EMIF。
> 注：No-FP、Scalar standalone、Full-FP 的远端报告 SHA 分别见 evidence JSON。T-010 的 FP/NEON RTL 与当前 SHA 逐文件 SHA-256 相同；当前 `rtl/lcvex_core.sv` 比 T-010 多 T-009 F1a 锁步修复（约 41 行差异），因此 full-top 资源数字是历史锚点而非严格当前 SHA 重跑。

### 2.2 Full-FP hierarchy（T-010 syn.rpt root_partition）

| Hierarchy | ALUT (total/own) | Registers (total/own) | DSP |
|---|---:|---:|---:|
| `soc` | 716,279 / 0 | 71,920 / 0 | 186 |
| `soc|core` | 664,210 / 25,516 | 20,168 / 8,520 | 177 |
| `soc|core|alu` | 5,131 / 5,131 | 0 | 0 |
| `soc|core|decode` | 14,830 / 14,830 | 0 | 3 |
| `soc|core|muldiv` | 1,269 / 1,269 | 717 | 9 |
| `soc|core|mmu` | 3,740 / 3,740 | 5,972 | 0 |
| `soc|core|fp_state` | 68 / 68 | 4,177 / 4,177 | 0 |
| `soc|core|g_fp_simd_enabled.fp_scalar` | 135,071 / 134,720 | 782 / 0 | 33 |
| `soc|core|g_fp_simd_enabled.neon_fp` | 470,056 / 5,277 | 0 | 132 |
| `soc|core|...neon_fp|g_scalar_lane[0].scalar_lane` | 117,646 / 117,646 | 0 | 33 |
| `soc|core|...neon_fp|g_scalar_lane[1].scalar_lane` | 118,230 / 118,230 | 0 | 33 |
| `soc|core|...neon_fp|g_scalar_lane[2].scalar_lane` | 114,366 / 114,366 | 0 | 33 |
| `soc|core|...neon_fp|g_scalar_lane[3].scalar_lane` | 114,537 / 114,537 | 0 | 33 |
| `soc|core|g_fp_simd_enabled.neon_int` | 8,529 / 8,529 | 0 | 0 |

No-FP 同层级 `soc|core`：ALUT 32,177 / 11,222，registers 18,160 / 7,294，DSP 12。

### 2.3 占比

以 Full-FP 总 comb ALUT 720,722 为分母，或以器件 ALM 容量 427,200 为分母：

| 项 | 占比 |
|---|---|
| Full-FP ALM / 器件 ALM | 482,334 / 427,200 = **112.91%** |
| No-FP ALM / 器件 ALM | 81,552 / 427,200 = **19.09%** |
| Full-FP core ALUT / total ALUT | 664,210 / 720,722 = **92.16%** |
| Full-FP NEON FP ALUT / total ALUT | 470,056 / 720,722 = **65.22%** |
| Full-FP 4 个 NEON scalar lane ALUT / total ALUT | 464,779 / 720,722 = **64.49%** |
| Full-FP core scalar FP ALUT / total ALUT | 135,071 / 720,722 = **18.74%** |
| Scalar standalone ALUT / full total ALUT | 138,582 / 720,722 = **19.23%** |

> 5 份 scalar 单元（core scalar + NEON 4 lane）合计 ALUT 约 599,850，占 full-FP 总 ALUT 的 83.2%；这是当前 full-FP 面积超容量的主要原因。计划中“未经验证 83%”现在有 hierarchy 可复核支撑（约 599.9K / 720.7K）。

## 3. P7 基线复核

### 3.1 本地 SV directed/raw-bit

| 命令 | 结果 |
|---|---|
| `sim-sv-fp-scalar` | PASS |
| `sim-sv-p7-2-neon` | PASS |
| `sim-sv-p7-3-neon-fp` | PASS |
| `sim-sv-p7-4-fma-convert` | PASS（scalar + NEON） |
| `sim-sv-p7-5-fp16-sqrt-minmax-round` | PASS（scalar + NEON） |

### 3.2 P7-2 Cocotb 已知红项

历史 T-004/T-008/T-010 已记录：`sim-cocotb-p7-2-neon` 的 10 个测试中 9 个 PASS，`test_p7_2_unsupported_udef` 的 SQADD 编码 `0x4E220C20` 被 B2c DUP scalar decode 分支截获。本任务尝试在当前 SHA 重跑该 Cocotb 目标，但 Verilator/Cocotb 构建在并发重型任务下被 SIGTERM（exit 143）终止，没有拿到新的测试结果；因此本 FP-P0 不新增“当前通过”结论，仍沿用历史证据指向独立任务 T-20260902-014。本 worktree 存在同名分支指针 `fix/T-20260902-014-p72-dup-sqadd-decode`（当前指向基线 SHA），但未发现 `docs/tasks/active/T-20260902-014.json`，需集成者确认并登记/推进。

## 4. Workload cycle 与 FP 观测

### 4.1 Cycle / retirement / IPC

| Workload | cycles | retired | IPC | commit_digest | memory_digest | 说明 |
|---|---:|---:|---:|---|---|---|
| `fp_scalar` | 173,026 | 65,963 | 0.381232 | b0efde5ed79308a1 | 4078dabba91c60f0 | 标量 FP32/64 依赖 + 8 路独立 + FDIV |
| `fp_fp16` | 180,441 | 82,013 | 0.454514 | 34d6e3bf9d8ba016 | a8dddf1e0170212e | 标量 FP16 H 独立链 |
| `neon_vect` | 175,737 | 66,721 | 0.379664 | 5c1d4f0a0f31cfe7 | 3ba6dea5f6c76128 | 向量吞吐 + 向量访存 |
| `neon_fp_chain`（新增纯计算） | 98,801 | 40,062 | 0.405482 | 5430ce7e72a5abbe | 512ed6e8e438217c | 4S/2D/8H FADD/FMLA 依赖/独立，无访存 |
| `scalar_fp16_chain`（新增纯计算） | 94,334 | 36,911 | 0.391280 | 462f53b72db0d747 | 4ec3f784806ef1ba | 标量 H add/sub/mul/fma 依赖 + add 独立 |

### 4.2 FP issue / busy / rsp_wait

| Workload | fp_issue | fp_busy_cycles | fp_rsp_wait_cycles | 主要 op 计数 |
|---|---:|---:|---:|---|
| `fp_scalar` | 41,102 | 16,384 | 16,384 | scalar add 10,296 / sub 10,240 / mul 10,240 / fma 10,240 / div 64 / mov 22；S 20,551，D 20,551 |
| `fp_fp16` | 65,568 | 0 | 0 | H add 16,412 / sub 16,384 / mul 16,384 / fma 16,384 / mov 4 |
| `neon_vect` | 36,891 | 0 | 0 | vector add 12,315 / mul 12,288 / fma 12,288；S 24,594，D 12,297 |
| `neon_fp_chain` | 21,516 | 0 | 0 | vector add 11,276 / fma 10,240；H 1,024，S 10,246，D 10,246 |
| `scalar_fp16_chain` | 16,392 | 0 | 0 | H add 10,243 / sub 2,048 / mul 2,048 / fma 2,048 / mov 5 |

观测定义：

- `fp_issue`：当前 RTL 无 `fp_issue` 端口，使用单发射顺序核的提交指令编码分类作为 issue 代理（等于通过 decode 支持的 scalar/NEON FP 指令退休数）。
- `fp_busy_cycles` / `fp_rsp_wait_cycles`：直接读 `core.fp_div_busy`；当前只有标量 FDIV 进入多周期 divider。记录值都是 16,384，对应 64 次 FDIV（FP32 32 次 + FP64 32 次）平均约 256 cycles/FDIV。
- 其他 FP/NEON FP 当前为 EX 组合路径，无 busy/rsp_wait；不能用 `muldiv_stall` 猜测 FP 延迟。`muldiv_stall` 在这些 workload 中为 0。

### 4.3 op/format 说明

计数来自提交的 AArch64 指令编码，按现有 decode 掩码分类为 scalar/vector add/sub/mul/fma/div/cmp/convert/sqrt-rint/minmax 以及 H/S/D 格式。FMA/vector FMLA 在 `fp_scalar` 中计数为 scalar fma；`neon_vect`/`neon_fp_chain` 中计数为 vector fma。详细 JSON 在 `build/agents/T-20260902-013/perf_custom/`（本地构建产物，不入 Git）。

## 5. Artifact / 证据

- 本文件：`docs/FP_NEON_PIPELINE_BASELINE.md`
- Handoff：`docs/handoffs/T-20260902-013-fp-p0-baseline.md`
- Evidence：`docs/tasks/evidence/T-20260902-013.json`
- 本地构建产物（不入 Git，由 evidence 指向路径）：
  - `build/agents/T-20260902-013/syn/full_fp.syn.rpt`（SHA-256 `d38f1236627a96873c5ad03a52701008ccf0cc764d9ddb113b3a899e6ee1d97e`）
  - `build/agents/T-20260902-013/syn/nofp.syn.rpt`
  - `build/agents/T-20260902-013/syn/fp_scalar.syn.rpt`
  - `build/agents/T-20260902-013/perf_custom/*.json`
  - 自定义 microbench：`build/agents/T-20260902-013/neon_fp_chain.c`、`scalar_fp16_chain.c`、`mb/neon_fp_chain.bin`（SHA-256 `b0cc5b7a...`）、`mb/scalar_fp16_chain.bin`（SHA-256 `3895c9f0...`）

## 6. 未跑项 / 已知限制

1. **当前 SHA 精确 full-FP/no-FP 全 top synthesis 未重跑**：使用 T-010/T-001 历史远端报告，FP 相关 RTL SHA 与当前一致，但 `rtl/lcvex_core.sv` 有 T-009 锁步差异；若后续需要严格同 SHA 全 top 面积，应重跑。本次时间/资源未执行第二个 2h Quartus 作业。
2. **4-lane NEON FP standalone 的独立 QSF 报告仍在远端 `T-20260902-013-probe\neon_fp` 运行**，未能提供最终 ALM/wall/peak；当前以 T-010 full-top hierarchy 的 neon_fp 子树作为基准分解。远端运行若完成，应补录 evidence。
3. **没有运行 fitter/STA/SOF**。
4. **P7-2 DUP/SQADD decode red 项未在本任务修复**，按任务边界指向 T-014；未见 T-014 的 active JSON，等集成者确认。
5. **没有运行完整 L2 lockstep / Gate D / long Linux**，不属于 FP-P0 范围。

## 7. 下一步

- 集成者确认/登记 T-20260902-014，闭合 P7-2 唯一基线红项。
- FP-P1 以本文件资源/cycle/busy 数据为输入，登记 transaction 接口与单在途 core 握手。
- 后续若做同 SHA 严格全 top synthesis，先串行运行 no-FP/full-FP 两个远端作业；4-lane NEON standalone 完成后回填 evidence。
