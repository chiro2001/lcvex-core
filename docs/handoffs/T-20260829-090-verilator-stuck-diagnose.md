# T-20260829-090 Verilator stuck 诊断（owner handoff）

状态：**owner review candidate**

```text
task=T-20260829-090 state=review base=86186e2649e9af9420fb216d36c7bf3d44781457 head=6fb1d5f0d19b543e26f6ce2d86a490c4e000b67f branch=feature/T-20260829-090-verilator-stuck-diagnose worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090 sent_at=2026-08-29T09:11:00+0800 received_at=2026-08-29T08:53:00+0800 reported_at=2026-08-29T09:11:00+0800 files=diag/verilator_stuck/findings.md,diag/verilator_stuck/repro.sh,diag/verilator_stuck/run_*.sh,diag/verilator_stuck/stubs/lcvex_fp_scalar_stub.sv,diag/verilator_stuck/logs/*,docs/handoffs/T-20260829-090-verilator-stuck-diagnose.md,docs/tasks/evidence/T-20260829-090.json tests=Verilator-5.050-lint-elab,bounded-dualcore-O0-build,dualcore-default-timeout blockers=none next=integrator-review
```

## 目标与结论

- 找到 LCVEX Verilator 卡住/极慢的根因。
- **结论：默认 Verilator 优化在 `rtl/lcvex_fp_scalar.sv` 的 256-bit 宽位组合
  FP 单元上爆炸，导致每个含真实 `lcvex_core` 的构建长时间停留在 elaboration。
  双核只是叠加两份；共享 L2/MSI/L1 coherence、`--assert`、`--timing` 均不是主因。**
- 可行规避：Verilator 加 `-O0` + `-Wno-fatal -Wno-UNOPTFLAT`，并给生成 Makefile
  使用 `make AR=ar`。实测单核 lint 从 >8min 降到 2.9s，双核 binary 约 2 分钟产出。

## 验证摘要

- `verilator --lint-only --no-assert --no-timing ... --top-module lcvex_fp_scalar`
  （真实模块）：`timeout 300s` 后 rc=124，未完成。
- `verilator --lint-only ... -O0 --top-module lcvex_fp_scalar`：0.523s 完成。
- `verilator --lint-only ... -O0 --top-module lcvex_core`：2.889s 完成。
- 用诊断 stub 替换 `lcvex_fp_scalar` 后：
  - 单 core：1.167s；
  - cluster CORE_COUNT=2：1.975s；
  - cluster CORE_COUNT=2 + COHERENCE_ENABLE=1：2.715s。
- 完整双核默认构建：090 内 `timeout 300s` 无 `Vtop.mk`；外部 T-086 同命令 >1h 仍
  99% CPU 无产物。
- 完整双核 `-O0 -Wno-fatal -Wno-UNOPTFLAT`：Verilator 前端约 7.8s，C++ 编译约
  118s；因环境缺 `x86_64-conda-linux-gnu-ar`，用 `make AR=ar` 完成链接，
  共约 2 分钟产出 14MB `lcvex_c2_dualcore_tb`。
- O0 binary 运行 20s 模拟结束，但 `LCVEX_C2_DUALCORE_TB FAIL: 3`
 （core0/core1 未观察到 flag，无 progress）。这暴露 `-O0` 下 C2 coherence
  的 `UNOPTFLAT` 组合环/测试时序问题，不是本诊断的通过证据。

## 已知限制 / 提醒

1. **未修改 RTL**。所有实验性 stub 只放在 `diag/verilator_stuck/stubs/`。
2. `-O0` 禁用了 Verilator gate optimizer，`lcvex_l1_coherence.sv`/cluster_top
   的同一个 `always_comb` 因读取 `probe_req_source_id` 被报告为
   `cl_req_valid -> probe_req_source_id -> l1coh -> cl_req_valid` 的
   UNOPTFLAT 环。虽然可 `-Wno-UNOPTFLAT` 构建，但这不是把功能当作已通过的理由。
3. T-086 工作区仍在跑默认双核构建；本诊断没有 kill/进入/修改它。
4. `A64_FP_SIMD` 参数目前只改变 ID 寄存器值，不会省略 `lcvex_fp_scalar`
   的实例化，因此不能用它快速关闭 FP 重逻辑。

## 下一步

1. 集成者 review；建议把 `-O0`/`AR=ar` 作为本机构建脚本的可选规避，并单独立项
   处理 `lcvex_fp_scalar.sv` 的宽位组合展开。
2. 修复/重构 FP 单元（降低 FP_W、拆流水线、条件实例化）后，重新跑默认优化
   双核构建和 directed TB。
3. 若保留当前 RTL，至少应记录：默认优化 builds 只用于小规模 FP 单模块，
   含真实 core 的多核/SoC 构建需 `-O0`。
