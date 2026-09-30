# Handoff T-20260902-015: FP-P1 Transaction Wrapper / Single-Owner Core Handshake

```text
task=T-20260902-015
state=review
base=fb53b80bfd42a9b52bce46e61bf5b4cd753b0e79
head=cfa5938
branch=feature/T-20260902-015-fp-p1-transaction-wrapper
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-015
sent_at=2026-09-03T01:14:30+08:00
received_at=2026-09-03T01:43:00+08:00
reported_at=2026-09-03T02:40:00+08:00
```

## 摘要

FP-P1 已实现：在 package 冻结 `fp_exec_req_t/fp_exec_rsp_t`，在
`lcvex_neon_fp.sv` 增加单在途 `lcvex_fp_exec` clocked transaction wrapper，
并把 core 的 FP/NEON 算术/比较/转换从直接组合采样改为一次
request/一次 held response。现有 raw IEEE 算术单元没有改动，scalar FDIV
仍由原 256-bit-serial divider 完成，只是完成语义通过 wrapper 持有到
EX/MEM 接收。

- 单在途：wrapper 在自身清空前 `req_ready=0`；core 同时以
  `fp_tx_candidate/fp_tx_issued/fp_rsp_valid` 泛化 `ex_busy`，年轻指令不能
  越过未完成 FP transaction。
- 锁存输入：request accept 时锁存三个 raw operand、FPCR snapshot、H/S/D、
  NEON arrangement/quad、op、目的写使能、FNZCV/FPSR/ownership tag。
- held response：`rsp_valid` 在 `rsp_ready=0` 时保持稳定；仅
  `rsp_valid && rsp_ready` 释放。response 被 EX/MEM 接收时 ID/EX 插入一个
  气泡，避免同拍 IF/ID->ID/EX 转移造成 PC/token 同驻。
- kill/reset：wrapper 内部状态在 kill/reset 清空；core 在
  `fetch_merge_wb/wb_exc_commit/IRQ/restore` 等边界取消未提交 FP
  transaction；普通 taken-branch `flush_id` 不取消更老 FP。
- FPEN trap 继续在 ID 级提交，不会发起 transaction。
- FP load/store 不进入 transaction，继续走既有数据内存路径。

## 接口设计摘要

`fp_exec_req_t` 字段：kind（scalar/NEON）、scalar/neon op、is_double、
is_half、fcvt_dst_half、rint_mode、quad、cmp_zero、signal_all_nans、
v_we/gpr_we/nzcv_we/fpsr_we、v_rd/gpr_rd、conv_*、operand_a/b/c[127:0]、
fpcr[31:0]、pc/insn/tag。

`fp_exec_rsp_t` 字段：v_we/v_rd/v_data[127:0]、gpr_we/gpr_rd/gpr_data、
nzcv_we/nzcv、fpsr_we/fpsr_flags、tag。

`lcvex_fp_exec` 状态机：IDLE -> RUN -> DONE，内部仍例化现有
`lcvex_fp_scalar` 与 `lcvex_neon_fp`；FDIV 等待原 divider `div_done`；
被 kill 的 FDIV 在 divider 排空前拒绝新 request，避免旧 quotient 被误用。

## 验证

- `make compile` PASS。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- `make VERILATOR_JOBS=1 sim-sv`（core scalar + FPCR/FPSR smoke）PASS。
- 新增 `tb/sv/lcvex_fp_exec_tb.sv` 定向握手测试 PASS（单次 issue、
  标量/NEON raw、FDIV、FCMP NZCV、response hold、kill、reset）。
- Cocotb P7-1 scalar FP 5/5 PASS（直接运行已链接 Vtop；make 包装因
  stdout/磁盘噪声返回 2，但二进制和测试结果均为 PASS）。
- 未运行 cocotb-p7-3/4/5 与 L2 lockstep（重型/时间限制）。

## 边界/风险

- 本阶段保留 1 scalar + 4-lane NEON 复制，不涉及 FP-P2 结构共享；资源不
  变化。
- 简单 FP 现在以 transaction 方式多一个握手/气泡状态，延迟比原组合路径
  增加，但 FP-P1 允许资源/性能暂时无改善；提交顺序与 raw-bit 不变。
- 未运行 fit/STA/Quartus。

## 下一步

集成者复跑 P7-1/3/4/5 Cocotb/L2；确认后登记 FP-P2 单 lane/slot 共享。
