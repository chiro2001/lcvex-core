# Handoff T-20260902-024: A10 RTL CDC hardening for EMIF adapter

```text
task=T-20260902-024
state=review
base=91c9232452664c0c28d9933a2742e76f693e270f
head=5cc81509c19f2d792eabe7fb687a31964eddf5c0
branch=fix/T-20260902-024-a10-rtl-cdc-harden
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-024
sent_at=2026-09-03T08:53:00+08:00
received_at=2026-09-03T08:55:00+08:00
reported_at=2026-09-03T09:02:00+08:00
```

## 结论

将 EMIF adapter 中未同步的 `cal_fail` 使用点改为已同步的
`cal_failed_cpu`/`cal_abort_cpu`，并把 CPU 复位直接进入 EMIF 侧 FSM 的路径
改为标准 per-domain async-assert / sync-deassert 复位释放链。功能语义保持不变：
- 校准失败后仍允许 CPU 侧新事务走本地 `DECERR`，不发 Avalon；
- CPU/EMIF 复位仍异步清空 FSM/FIFO，释放时按各域时钟同步退出；
- FIFO 的校准失败 epoch 复位使用同步后的 CPU 域失败锁存（CPU FIFO）和
  源域 `cal_fail`（EMIF FIFO），未把 raw `cal_fail` 引入 CPU 时序/组合控制。

## 改动摘要

1. `rtl/lcvex_axi4_avalon_adapter.sv`
   - 将公共复位请求拆成两套 per-domain reset release：
     - `cpu_fsm_rst_n` / `emif_fsm_rst_n`：仅跟随真实 CPU/EMIF 复位，
       不因 `cal_fail` 复位 FSM，保留 post-failure 本地 DECERR 路径；
     - `cpu_fifo_rst_n` / `emif_fifo_rst_n`：在 FSM 复位基础上叠加
       校准失败 epoch，继续用于两个异步 FIFO 的写/读域清空。
   - CPU 侧 FSM 的异步复位由 raw `cpu_domain_rst_n` 改为 `cpu_fsm_rst_n`；
     EMIF 侧 FSM 由同时异步触发 `emif_rst_n`/`cpu_rst_n` 改为
     `emif_fsm_rst_n`，消除 CPU 复位直接驱动 EMIF 侧状态机的路径。
   - CPU 域组合/时序控制不再使用 raw `cal_fail`：
     - `cal_local` 只使用同步后的 `cal_failed_cpu`；
     - `req_fifo_wr_en` 去掉 raw `!cal_fail`，以 `cal_ready_cpu`/FIFO reset 门控；
     - `resp_fifo_rd_en` 改为 `!cal_failed_cpu`；
     - CPU 正常事务 abort 只使用 `cal_abort_cpu`。
   - EMIF 侧的 Avalon 门控仍使用源域 `cal_fail`/`cal_success`（同域），
     不构成跨域未同步路径。

2. `rtl/lcvex_calibration_gate.sv`
   - 端口从 raw `cpu_rst_n`/`emif_rst_n` 改为接收 adapter 提供的逐域
     同步复位 `cpu_rst_n_sync`/`emif_rst_n_sync`；
   - 源域 sticky `fail_emif_latched_q` 使用 EMIF 域同步复位，
     CPU 域 status 同步链使用 CPU 域同步复位；
   - 保持原有 2-flop `cal_success`/`cal_fail` 同步和 sticky fail 语义。

## 验证

- `make compile`：PASS（Verilator 5.050 lint-only）
- `fpga/catapult_a10/tools/lint_soc.sh`：PASS
- `fpga/catapult_a10/tools/lint_platform.sh`：PASS
  （验证输出末尾 `LCVEX_CATAPULT_A10_SKELETON_LINT_PASS`）
- B2 AXI4/Avalon SV 回归：
  - 构建：`verilator --binary --timing --assert ... --top-module lcvex_axi4_avalon_tb`
  - 运行：`PASS: B2 AXI4/Avalon SV regression`
- `git diff --check`：PASS
- 未运行：完整 Quartus/Qsys synthesis/fitter/signoff STA、TimeQuest Report CDC、
  assembler/SOF、板上复位/校准压力测试；本任务不修改 SDC/Qsys 生成物。
- 未新增 TB 文件：`tb/**` 属于只读写集，本次沿用现有 B2 回归覆盖 CDC/reset/
  cal_fail 行为；定向 CDC 测试建议由集成者在后续授权写 tb 时补充。

## 文件

- `rtl/lcvex_axi4_avalon_adapter.sv`
- `rtl/lcvex_calibration_gate.sv`
- `docs/handoffs/T-20260902-024-a10-rtl-cdc-harden.md`
- `docs/tasks/evidence/T-20260902-024.json`

## 已知限制 / 下一步

1. 仍需在真实 Quartus post-fit 环境跑 TimeQuest/Report CDC，
   确认新增/保留的复位同步器层级和 recovery/removal。
2. 本任务只做 RTL 加固；T-021 SDC 中的复位同步器命名通配符仍兼容
   `cpu_rst_sync0_n*`/`emif_rst_sync0_n*`，但正式 STA 应以新设计的
   FSM/FIFO 两套 reset release 复核。
3. 下一步应由集成者合并后重跑 FP-P4 功能与 FP-P5 synthesis→fitter→STA；
   只有 setup/hold/recovery/removal/min-pulse 全非负且 DDR 通过才允许
   assembler/SOF。
