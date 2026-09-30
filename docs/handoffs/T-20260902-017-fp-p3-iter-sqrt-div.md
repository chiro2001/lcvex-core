# Handoff T-20260902-017: FP-P3 Iterative FSQRT/FDIV + Shared Lane Round/Pack

```text
task=T-20260902-017
state=review
base=f2a31a9e32883ae8a697c1039fa95dec11f6b337
head=f54b87a53abf87d1def7aed64b1b080901c26984
branch=feature/T-20260902-017-fp-p3-iter-sqrt-div
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-017
sent_at=2026-09-03T03:18:30+08:00
received_at=2026-09-03T03:20:00+08:00
reported_at=2026-09-03T04:13:00+08:00
```

## 摘要

FP-P3 已把发布路径中的 FSQRT/FDIV 改为可暂停、可 kill、可 reset 的迭代状态机，
并继续保持在一个共享 64-bit lane engine 内执行：

- `lcvex_fp_scalar` 增加 `FP_ITER` 参数。发布配置（`lcvex_fp_exec` 内的 scalar）
  使用 `FP_ITER=1`，例化 **1 个** `lcvex_fp_divider` 和 **1 个** 新增
  `lcvex_fp_iter_sqrt`；旧的 FP16 双 divider 并行复制仅保留在 `FP_ITER=0`
  standalone/reference 分支，不进入 release hierarchy。
- FDIV：保留 256 次 bit-serial restoring divider；FP16 双 16-bit lane 改为
  同一 divider 顺序处理（标量 H 低/高 lane），移除了 parallel dual divider。
- FSQRT：新增 64 次 restoring 整数平方根 FSM，替换原组合展开的 `isqrt64`
  在共享 lane 中的宽带实现；特殊值、NaN quiet、DN/FZ/FZ16、RMode、FPSR sticky
  仍走原有 `unpack_fp` / `div_finish` / `round_pack` 公共函数。
- `lcvex_fp_exec` 的 slot 完成改为统一使用 `scalar_iter_done`；`req_ready/busy`
  使用 `scalar_iter_busy`。迭代器在 `kill` 时立即清空，不再需要排空等待。
- 支持 `iter_pause`（当前 wrapper 接 0，供后续切级/调试使用）、`iter_kill`
  （接 wrapper kill）、异步 `rst_n`。
- 保持 FP-P1/P2 的单在途、held response、FPCR snapshot、FPEN trap 语义；
  `lcvex_core.sv` 无需改动。

## Latency 表（request accept → first rsp_valid，cycles，固定公式）

| 操作/格式 | 实测 cycles | 说明 |
| --- | ---: | --- |
| scalar ADD/SUB/MUL/CMP/MOV/FMA/FCVT/FRINT etc. | 2 | 1 个组合 slot + wrapper 1 cycle |
| NEON 2S/2D non-iter | 3 | 2 slots 组合 + wrapper |
| NEON 4S/4D/8H non-iter | 5? | 4 slots 组合 + wrapper（测试中未单独锁定） |
| scalar FDIV.S/D finite | 258 | 256 divider + 2 wrapper |
| scalar FDIV.H (two lanes sequential) | 515 | 2×256 divider + 3 wrapper |
| scalar FSQRT.S/D | 66 | 64 sqrt + 2 wrapper |
| scalar FSQRT.H | 67 | 64 sqrt + second H special slot + wrapper |
| NEON FSQRT.2S | 131 | 2×64 sqrt + 3 wrapper |
| special DIV/SQRT (NaN/Inf/zero/negative etc.) | 2 | 无迭代，组合 special+round path |

Latency 在 `tb/sv/lcvex_fp_exec_tb.sv` 中以 `issue_scalar_lat` / `issue_neon_lat`
固定检查以下代表项：FDIV.S=258、FSQRT.S=66、FSQRT.D=66、FSQRT.H=67、
FDIV.H=515、NEON FSQRT.2S=131、FADD.S=2、NEON FADD.2S=3。

## 验证

- `make compile` PASS（Verilator lint，4 warnings 已清理）。
- `lcvex_fp_exec_tb` 定向 PASS：
  - 原有 scalar/NEON raw、held response、kill、reset；
  - 新增 FDIV/SQRT 有限值、H 双 lane、NEON SQRT.2S；
  - FDIV 1/0、0/0、FSQRT -1 special；
  - 迭代中 kill、迭代中 reset、后续 FADD 正常；
  - latency table fatal assertions。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- Cocotb 全绿：
  - `sim-cocotb-fp-scalar` 5/5 PASS。
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS。
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS。
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS。

## 结构/公共路径

- 发布 hierarchy：`lcvex_core → lcvex_fp_exec → lcvex_fp_scalar#(FP_ITER=1)`
  → 1× `lcvex_fp_divider` + 1× `lcvex_fp_iter_sqrt`。
- `unpack_fp`、`div_finish`、`sqrt_finish_iter`、`round_pack`、NaN/zero/Inf 处理
  都集中在同一个 scalar 模块内，FDIV/FSQRT 与其它 op 共用分类和 round/pack，
  没有按 op 复制整套宽舍入逻辑。
- 未跑 Quartus synthesis；hierarchy 结论来自 RTL generate 与 Verilator 编译，
  远端综合资源差值待后续 synthesis 任务量化。

## 边界/风险

- 4-lane 组合 `lcvex_neon_fp` 仍保留为 standalone raw-bit 参考，不进入发布配置。
- `lcvex_fp_scalar` 新增可选的 `iter_*` 端口；未连接的旧实例会产生
  PINMISSING 警告但功能不变（standalone TB 已连接或仍可运行）。
- 没有运行 Quartus fit/STA/SOF；未做 L2 lockstep。
- 延迟按当前实现固定，FP-P4 可在同 SHA workload 测量后再决定是否调拍数。

## 下一步

集成者复跑后登记 FP-P4；若后续 fit/STA 出现切级需求，再登记 FP-P3T。
