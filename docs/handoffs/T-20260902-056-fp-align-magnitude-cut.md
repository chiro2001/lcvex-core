# Handoff T-20260902-056：FP ADD/SUB effective magnitude timing cut

```text
task=T-20260902-056 state=review base=32c77ae334d1f61b081a7919359d5e40f645b984 head=12a610f609a1e14a46ccdee680c990ee9bea69ff branch=fix/T-20260902-056-fp-align-magnitude-cut worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-056 sent_at=2026-09-04T21:20:36+08:00 received_at=2026-09-04T21:20:36+08:00 reported_at=2026-09-04T22:14:53+08:00 files=rtl/lcvex_fp_scalar.sv,tb/sv/lcvex_fp_exec_tb.sv evidence=docs/tasks/evidence/T-20260902-056.json risks=physical FP-P5 rerun pending next=集成者在合并 SHA 重跑 FP-P5，setup 全非负后再开 assembler/SOF
```

## 结论

- 在 T-052 已有 `add_align{,_lo,_hi}` 对齐寄存器之后新增独立
  `fp_add_mid_t add_mid{,_lo,_hi}` 和 `IT_ADD` 状态。
- 新路径为 `IT_ARITH -> IT_ALIGN -> IT_ADD -> IT_PREP`：
  `IT_ARITH` 只写 256-bit sticky 对齐值；`IT_ALIGN` 只从已对齐值完成有效
  ADD/SUB compare/add/sub、相消和结果符号，并把 signed exponent/common
  exponent、DN、原 operand/classification、format/FZ/RMode/flags 一并寄存；
  `IT_ADD` 再执行 NaN→Inf→双零→有限相消的 special/zero 解析，并把已寄存
  magnitude/sign/exp2 组装到既有 `pp_pre`，`IT_PREP` 保持原 round/pack。
- `IT_ADD` 和 `add_mid*` 均为内部非架构状态：reset/kill 全零并回
  `IT_IDLE`，没有读写权限，也不提前提交架构状态；valid drop 会停止状态机，
  wrapper kill/reset 仍优先清除在途事务。
- 仅 ADD/SUB 延迟增加一个 scalar slot 周期：FADD.S **7**；两 slot
  NEON FADD.2S **13**。MUL/FMA、SCVTF/UCVTF、CMP/minmax/FRINT/FP->int、
  FDIV/FSQRT 迭代周期和 divider kill/pause 未改动。

## 语义覆盖

- `binary_add_mid_from_align` 只做对齐值上的有效 compare/add/sub，禁止
  `magnitude==0`/zero pack/special mux；`binary_pre_from_add_mid` 在寄存边界
  后逐项复用 T-052 `binary_pre_from_align` 的 NaN propagation/quieting、Inf
  invalid、双零和异号相消 zero sign 规则，避免把 alignment compare/add/sub
  逻辑重新带回 `add_mid -> pp_pre` 路径。
- directed FP_ITER 覆盖 qNaN payload、sNaN/IOC、DN、Inf-Inf/IOC、
  round-toward-minus 相消负零、FZ 输入/IDC、valid drop/reissue；既有测试
  继续覆盖 H 双 lane、NEON slot/flags、held response、FDIV/FSQRT latency
  及 kill/reissue/reset。

## 验证结论

- `make compile`（Verilator lint-only）通过。
- `lcvex_fp_exec_tb` 在 `MemoryMax=16G, MemorySwapMax=0,
  VERILATOR_JOBS=1` 下通过；新增和既有 directed 检查全部通过，精确命令、
  时间和结果见 `docs/tasks/evidence/T-20260902-056.json`。
- 已完成 P7-1/P7-3/P7-4/P7-5 的 SV 与 Cocotb L1，以及基础/edge/rounding/
  sequence strict lockstep L2：SV 全部通过，Cocotb 为 5/5、4/4、6/6、8/8；
  L2 分别为 P7-1 28/38/18/388、P7-3 48、P7-4 94/54/27/142、P7-5
  102/59/40/66。全部结果、seed、命令和时间见 evidence JSON。
- P7-1 首次 lockstep 仅因 worktree 缺少 `build/` 无法创建 Verilator 输出而失败；
  创建本 worktree `build/` 后原命令重跑通过，未修改 RTL/QEMU 源。
- Quartus synthesis/fitter/signoff STA 与 assembler/SOF 尚未运行；T-053
  `add_align_hi -> pp_pre_hi` setup 改善需集成者在同一 QSF/SDC 上确认。
