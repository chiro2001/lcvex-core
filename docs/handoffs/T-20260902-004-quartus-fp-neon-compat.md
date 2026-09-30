# Handoff T-20260902-004：Quartus FP/NEON Compatibility Fixes

```text
task=T-20260902-004
state=review
base=732aa5691134b2aaef64b50c570da2b7ad001497
head=325d2da85f8cd351b6a3975d29440e9dc6d0ee9f
branch=fix/T-20260902-004-quartus-fp-neon-compat
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-004
sent_at=2026-09-02T08:18:53+08:00
received_at=2026-09-02T08:19:00+08:00
reported_at=2026-09-02T08:56:53+08:00
```

## 摘要

修复 T-20260902-001 暴露的 Quartus Prime Pro 21.4 RTL elaboration 兼容错误，保持 FP/NEON 功能语义不变。

### 三处修复

1. `rtl/lcvex_fp_scalar.sv`
   - 原 `for (i = frac_bits + 1; i < FP_W; ...)` 使用运行时 `frac_bits` 作为循环起点，触发 `non-constant loop count limit 250 exceeded`。
   - 改为固定 256 次循环：`for (i = 0; i < FP_W; i++)` 并用 `if (i > frac_bits && q[i])` 保持“检查 frac_bits 以上任一有效位”的原语义。
   - 不舍入/标志位语义变化。

2. `rtl/lcvex_neon_int.sv`
   - `set_lane` 默认 64-bit 分支增加 `if (index < 2)` 保护，避免 `index*64 +:64` 对 index>=2 的静态越界；非法 index 保持 `set_lane = value` 不变。
   - 同步给 `lane_unsigned` 的 64-bit 读切片增加同类保护，避免同类的 Quartus 静态越界风险；合法调用（index 0/1）语义不变，非法调用返回 0 作为 don't-care。

3. `rtl/lcvex_neon_fp.sv`
   - 输入侧 `is_double` 分支对 `i<2` 才做 `operand_a/b/c/conv_int[i*64 +:64]`；`i>=2` 赋 0（这些 lane 的 `scalar_valid` 本就为 false）。
   - 输出侧 `FCVTZS/FCVTZU` 与常规 double 写回也增加 `i<2` 保护，避免结果合并部分的 `i*64` 静态越界；`scalar_valid` 的 2D 语义未变。

## 本地验证

- `make compile`：**已运行**，但当前仓库存在与本任务无关的既有 `lcvex_core.sv:436 UNUSEDSIGNAL` 警告，`-Wall` 将该警告按 error 退出（base 同样失败，已用 `git stash` 验证）。
- 等价 RTL lint：`verilator --lint-only -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL --top-module lcvex_core -f rtl/filelist.f` 通过。
- SV 定向测试全部通过：
  - `make VERILATOR_JOBS=1 sim-sv-fp-scalar`
  - `make VERILATOR_JOBS=1 sim-sv-p7-2-neon`
  - `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp`
  - `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert`
  - `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round`
- Cocotb 定向测试：
  - `make VERILATOR_JOBS=1 sim-cocotb-fp-scalar`：5/5 PASS
  - `make VERILATOR_JOBS=1 sim-cocotb-p7-2-neon`：9/10 PASS，`test_p7_2_unsupported_udef` 的 SQADD 用例失败（详见边界）
  - `make VERILATOR_JOBS=1 sim-cocotb-p7-3-neon-fp`：4/4 PASS
  - `make VERILATOR_JOBS=1 sim-cocotb-p7-4-fma-convert`：5/5 PASS
  - `make VERILATOR_JOBS=1 sim-cocotb-p7-5-fp16-sqrt-minmax-round`：8/8 PASS
- `git diff --check`：通过。
- Quartus 兼容性静态自查：非定常循环已移除；所有 `i*64` / `index*64` 切片均在 `i<2` / `index<2` 保护内。

## 边界与已知问题

- 本任务未运行远端 Quartus full synthesis；只做 RTL 修复与本地 Verilator 验证。
- `test_p7_2_unsupported_udef` 的 SQADD 失败看起来是 B2c DUP decode 的已有重叠：`0x4E220C20` 被现有 DUP scalar 分支捕获，而不是本任务改动的 `lcvex_neon_int.sv`/`lcvex_neon_fp.sv` 造成。本任务按写集范围不修改 decode。
- 标准 `make compile` 的 `UNUSEDSIGNAL` 是既有的非本任务问题，未在本任务修改 `rtl/lcvex_core.sv`。

## 下一步

1. 集成者合并后建议在干净 merge SHA 复跑 L0/L1。
2. 由集成者或后续任务用本修复重跑远端真实 full-FP synthesis，确认 Quartus elaboration 不再报这三类错误。
3. 若需全绿 `sim-cocotb-p7-2-neon`，另开 decode B2c DUP/SQADD 编码重叠修复任务，不属于 T-20260902-004 写集。

## 证据

- `docs/tasks/evidence/T-20260902-004.json`
