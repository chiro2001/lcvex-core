# Handoff T-20260902-052：FP response-ready 与 ADD/SUB pre-round setup 切级

```text
task=T-20260902-052 state=review base=3446a6507f024c0b79fff5fea0107837e1de8447 head=65b63f45974bc2b6ba4ce1bbfff2f088c6030bbd branch=fix/T-20260902-052-fp-rsp-preround-cut worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-052 sent_at=2026-09-04T15:49:29+08:00 received_at=2026-09-04T15:49:31+08:00 reported_at=2026-09-04T16:26:32+08:00 files=rtl/lcvex_neon_fp.sv,rtl/lcvex_fp_scalar.sv,tb/sv/lcvex_fp_exec_tb.sv evidence=docs/tasks/evidence/T-20260902-052.json risks=physical STA pending; no Quartus run next=integrator cherry-pick/review then FP-P5 rerun
```

## 结论

- 删除 `TX_DONE` 握手时对完整 `rsp_r` payload 的清零。`rsp_valid` 仍由
  `state == TX_DONE` 产生，握手只退出 TX_DONE 并清理 ownership/accumulator；
  invalid 时旧 payload 保留，下一事务到达 TX_DONE 时覆盖。reset/kill 仍把
  `rsp_r` 清零，因此 `exmem_can_adv -> fp_rsp_ready` 不再驱动
  `rsp_r.gpr_data[*]` 的 payload D 路径。未修改 core。
- 将 FP_ITER ADD/SUB 的 pre-round 从 `IT_ARITH -> pp_pre*` 拆成：
  `ap_pre* -> add_align*`（指数相关 sticky 对齐）和
  `add_align* + ap_pre* -> pp_pre*`（special/effective add/sub），中间经过
  新的 `IT_ALIGN` 状态。切点位于完整对齐结果之后、有效加减/相消生成
  `fp_pre_t` 之前；不使用 false path。
- 连接 FP_ITER 内部 `it_divider.kill/pause` 到 `iter_kill/iter_pause`，避免
  kill 只清 scalar FSM 而底层 divider 继续运行。FDIV/FSQRT 协议与原有周期
  保持不变；新增 S/D/H FDIV 与 NEON FSQRT mid-iteration kill/reissue 覆盖。

## 新增状态与时序边界

`fp_add_align_t add_align/add_align_lo/add_align_hi` 的 reset/kill 值为全零，
只在 `IT_ARITH`、ADD/SUB 分支写入，在下一拍 `IT_ALIGN` 读取；它们只携带
当前 slot 的 pre-round 中间值，不直接提交架构状态。`IT_ALIGN` reset/kill
后回 `IT_IDLE`，无 valid 时也回 `IT_IDLE`。响应 payload `rsp_r` 的 reset/kill
值为全零；正常握手后保持旧值但由 `rsp_valid=0` 标记无效。

ADD/SUB 延迟变化为每个 scalar slot +1：scalar FADD.S=6、NEON FADD.2S=11；
MUL/FMA、SCVTF/UCVTF、FCVT、CMP/minmax/FRINT/FP->int 不变。迭代周期保持：
FDIV.S=261、FSQRT.S=69、FSQRT.D=69、FSQRT.H=70、FDIV.H=518、NEON
FSQRT.2S=137。

## 语义保持

- FP/NEON raw bits、NaN payload/quieting、FPCR snapshot、FZ/DN/RMode、FPSR
  sticky OR、FCMP NZCV、conversion GPR result、NEON lane packing 与顺序提交
  均保持；`binary_pre_from_align` 的 special/zero/sign/flags 分支逐项复用
  原 `binary_pre_parts` 规则。
- `rsp_valid` 期间 `rsp_r` 无写入，backpressure 下全 payload 稳定；消费一次后
  只退出 TX_DONE，旧 payload 不再具有架构意义；reset/kill 优先级和清零保持。
- 不修改 `rtl/lcvex_core.sv`、QEMU、QSF/SDC；不增加 SDC exception、猜测执行
  或新 DSP。

## 验证结论

- `make compile`（Verilator lint-only）通过。
- FP exec 定向 TB 通过：响应 held payload/一次消费/kill-reset payload、FADD
  与 NEON FADD 延迟、FDIV/FSQRT 原周期，以及 FDIV.S/D/H 和 NEON FSQRT
  mid-iteration kill/reissue 全通过。
- SV raw：P7-1 scalar、P7-3 NEON、P7-4 scalar/NEON FMA-convert、P7-5
  scalar/NEON FP16/sqrt/minmax/frint 全通过。
- Cocotb：P7-1 5/5、P7-3 4/4、P7-4 6/6、P7-5 8/8，均 0 fail/skip。
- L2 step lockstep：P7-1 28 条、P7-3 48 条、P7-4 sequence 142 条、P7-5
  sequence 66 条，均与 QEMU 完全一致。

精确命令、source SHA、seed、退出结果与资源限制见
`docs/tasks/evidence/T-20260902-052.json`。未运行 Quartus full-FP
synthesis/fitter/STA、assembler/SOF、FPGA programming/JTAG；需集成者在合入
SHA 上按 FP-P5 重跑确认物理 setup 改善。
