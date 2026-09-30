# T-20260827-051 wiring repair handoff

task=T-20260827-051-wiring-repair state=repair_ready

base=90efd1555246ee3887ab095890dced0181a76c3d
source=94a823a
branch=feature/T-20260827-051-p7-wiring-repair
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260827-051-wiring-repair

## 修复摘要

- `rtl/lcvex_core.sv` 将 ID-level `sys_commit` 与 `commit_ready` 绑定；背压时
  MSR、FPCR/FPSR access trap 和其它 system commit 都不更新架构状态，也不产生
  未消费的 commit packet。SV/Cocotb 背压测试覆盖 CPACR MSR 与 FPCR MSR。
- `sim/microbench/microbench_runner.cc` 在 reset-release 前显式清零
  `difftest_restore_fp_valid`、FPCR/FPSR 和 32 组 V low/high 输入。
- `sim/difftest/lockstep_coordinator.cc` 在 FP_INIT/FP_COMMIT 协议或 raw-state
  mismatch 时先保留 `fail.txt` 的首个 raw mismatch，再写相邻的
  `fail-fp.json`。JSON 展开 FP pre/post 与 DUT 对照的 FPCR/FPSR、32×V，另含
  CPU profile、capability、指令编码/可复现 `.inst` 文本、seq、scalar stores、
  最近最多 32 条记录和 checkpoint provenance。
- `sim/difftest/run_lockstep_step.sh` 将实际 `QEMU_CPU` 传给 coordinator，避免
  失败包使用默认 profile 掩盖调用方配置。
- 新增 `sim/difftest/fail_fp_smoke.py` 与 `make fail-fp-smoke`：本地最小
  `SOCK_SEQPACKET` peer 分别复现 FP_INIT mismatch，以及有效 FP_INIT 后的
  FP_COMMIT mismatch；不启动 QEMU、不回灌 DUT。

## 验证

以下命令均在本 worktree、conda 环境 `lcvex` 中运行并通过：

- `make compile`
- `make lockstep-build`
- `make sim-sv`
- `make sim-sv-backpressure`（包含 system-commit 背压场景）
- `make microbench`（`mb_all`，2698 cycles）
- `make fail-fp-smoke`
- `conda run --no-capture-output -n lcvex make -C sim/cocotb SIM=verilator TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_commit_backpressure SIM_BUILD=sim_build_bp`（2/2）
- `conda run --no-capture-output -n lcvex make -C sim/cocotb SIM=verilator TOPLEVEL=lcvex_soc_tb COCOTB_TEST_MODULES=test_p7_wiring SIM_BUILD=sim_build_p7_wiring`（1/1，640 ns）
- `git diff --check`

`fail-fp-smoke` 最后一次 artifact 根目录为
`build/tmp/fail-fp-smoke-ae6ua65n`；其中两案均有 `fail.txt` 和可解析
`fail-fp.json`，hash、命令和字段检查见
[`T-20260827-051-wiring-repair.json`](../tasks/evidence/T-20260827-051-wiring-repair.json)。

## 失败记录与边界

- 首次 `make lockstep-build` 在 Verilator 生成阶段报
  `Can't write file: build/verilator_lockstep/Vlcvex_soc_tb__Syms__Slow.cpp`；
  当时 worktree 没有 `build/`，未产生持久 log。显式创建该 worktree-local
  构建目录后重跑通过；不是 RTL/C++ 编译错误。该环境性失败在 evidence 的
  `resolved_failures` 中记录，console capture 无独立 log path。
- 真实 QEMU/A76 required lockstep、QEMU fork/patch replay、FP arithmetic/memory、
  AXI/Cache/FPGA、P7-1～P7-3、Linux 长跑和 Gate D 未执行；dispatch 明确禁止
  操作外部 QEMU，故不能把本地 A76 profile 字段测试宣称为真实 A76 smoke。

## 下一步

集成者在本 repair commit 上重新执行串行集成复审，并在允许的 QEMU 串行窗口
运行短 `cortex-a76,has_el3=false,has_el2=false` required smoke；随后复跑 Gate D
受影响子集。不要修改 active task JSON、TASKS、PROJECT_STATUS 或 ROADMAP。
