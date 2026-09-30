# T-20260829-091 FP scalar Verilator 默认优化修复（owner handoff）

状态：**review**

```text
task=T-20260829-091 state=review base=cb59372 head=0288e25af607c7f6abb7d7b7e7f0dead47c6cb26 branch=feature/T-20260829-091-fp-scalar-verilator-opt worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-091 sent_at=2026-08-29T09:28:00+0800 received_at=2026-08-29T09:28:00+0800 reported_at=2026-08-29T09:56:04+0800 files=rtl/lcvex_fp_scalar.sv,docs/handoffs/T-20260829-091-fp-scalar-verilator-opt.md,docs/tasks/evidence/T-20260829-091.json tests=verilator-default-lint-fp-scalar,verilator-default-lint-core,make-compile,sim-sv-fp-scalar,sim-sv-p7-4-fma-convert,sim-sv-p7-5-fp16-sqrt-minmax-round,git-diff-check blockers=no-QEMU-lockstep,no-full-dualcore-build next=integrator-review-and-remerge
```

## 目标与结论

- 目标：让 Verilator 默认优化下 `lcvex_fp_scalar` / `lcvex_core` 的
  lint/elaboration 在可接受时间完成，同时保持现有 FP 标量/NEON raw-bit
  功能与语义不变。
- **结论：已实施一项实质优化，单独 `lcvex_fp_scalar` 默认 lint 从 >120s
  未完成降到约 4.8s；真实 `lcvex_core` 默认 lint 约 55s，`make compile`
  约 37s。现有 P7-1/P7-4/P7-5 SV raw-bit 定向测试全部通过。**
- 不需要 `-O0` 规避，可作为默认优化恢复的候选。

## 改动摘要

`rtl/lcvex_fp_scalar.sv` 中的两处最外层 FP op 分派：

- 原来的两个 `unique case (op)`（半精度/非半精度路径）改为等价的
  `if/else if` 链。
- 改动位置是 `always_comb` 中 FP 单元的操作码 mux；没有修改任何
  算术/舍入/NaN/FPSR/FCVT/sqrt/minmax/frint 算法，也没有修改模块端口、
  接口、packet、core 接线、decode、filelist 或 QEMU。
- 原理：Verilator 默认优化把所有 FP 函数内联进这个大的组合 mux 后，
  V3Case 对巨大 `case(op)` 的优化是 elaboration 卡顿的直接触发点
  （实验确认 `-fno-case` 可让原文件约 1.5s 完成）。用 if/else 链替代
  后，Verilator 无需对这种巨型 case 做同量级合并/展开优化，默认优化
  即回到正常可接受时间。
- 语义等价：op 枚举互斥，default 行为保留；唯一的细微差别是不再使用
  `unique` 断言（该断言只检查 op 重叠/未列情况，不改变可执行语义）。

## 验证摘要

环境：Verilator 5.050，12 线程，conda env `lcvex`。所有命令在
`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-091` 内运行。

| 项目 | 命令/入口 | 结果 | 耗时 |
| --- | --- | --- | --- |
| FP scalar 默认 lint | `verilator --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_fp_scalar rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv` | pass | 4.804s |
| core 默认 lint（诊断源列表） | `verilator --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_core ...` | pass | 55.361s |
| 项目 compile | `make compile` | pass | 37.370s（Verilator Wall 36.288s） |
| P7-1 raw-bit SV | `make sim-sv-fp-scalar` | pass | 8.834s |
| P7-4 raw-bit SV+FMA/conv | `make sim-sv-p7-4-fma-convert` | pass | 20.941s |
| P7-5 raw-bit SV+NEON | `make sim-sv-p7-5-fp16-sqrt-minmax-round` | pass | 构建+运行均完成（P7-5 scalar/NEON PASS） |
| 格式 | `git diff --check` | pass | - |

## 已知限制 / 风险

1. 本改动专注于消除 Verilator case 优化爆炸，没有做 256-bit 宽位
   收窄、流水线化或子模块拆分；`lcvex_fp_scalar` 内部仍是宽位组合 FP
   单元。单独 lint 很快，但完整 core 默认 lint 仍需约 55s，未达到
   “秒级”。
2. 未执行 QEMU A76 strict lockstep（L2）。原因是本机当前有多个并行
   Verilator/QEMU 重型任务占用资源，且本轮未启动锁步环境的完整构建。
3. 未执行完整 C2 双核 / B2c SoC / Gate D 构建。`lcvex_core` lint 已足够
   说明主瓶颈已缓解，但多核默认构建需要集成者在资源充分环境复跑。
4. `unique case` 被替换为 `if/else`，理论上去掉了 FP op 分派上的
   unique 断言；上游 decode 产生非法/重叠 op 时不再在 FP 单元报
   unique violation。没有发现现有路径依赖该断言。
5. 没有修改 QEMU、checkpoint、顶层 filelist、Makefile 核心构建、A64_FP_SIMD
   条件实例化或任何不支持编码的支持声明。

## 下一步

1. 集成者 review 并在合并 SHA 复跑 `make compile` / P7-1/P7-4/P7-5
   SV raw-bit；若有资源再跑 A76 required lockstep。
2. 建议后续任务继续做真正窄化（例如按 H/S/D 最大位宽拆分或减少
   ADD/DIV/FMA extra）、拆分 FP 子模块或改为多周期，以进一步降低
   完整 core/多核 Verilator 耗时和 C++ 编译体积。
3. 若本改动合入，可在默认构建移除 `-O0` 规避（至少对 core lint）；
   完整双核 SoC 需要重新验证后再决定。
