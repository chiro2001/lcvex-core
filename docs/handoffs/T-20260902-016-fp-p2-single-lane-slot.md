# Handoff T-20260902-016: FP-P2 Single 64-bit Lane Engine + NEON Slot Sequencer

```text
task=T-20260902-016
state=done
base=cc3362684313cea207fd2e52df9104d58af8d02b
head=efc4ae9
branch=feature/T-20260902-016-fp-p2-single-lane-slot
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-016
sent_at=2026-09-03T02:48:00+08:00
received_at=2026-09-03T03:00:00+08:00
reported_at=2026-09-03T03:30:00+08:00
```

## 摘要

FP-P2 在 FP-P1 的 `fp_exec_req_t/fp_exec_rsp_t` 单在途接口内完成了单 lane
共享与 NEON slot 分时：

- `lcvex_fp_exec` 不再例化 4-lane `lcvex_neon_fp`，只保留一个
  `lcvex_fp_scalar` 作为共享 64-bit lane engine。
- scalar H/S/D 使用 1 个 slot；NEON 2S=2、4S=4、2D=2、4H=2×32-bit H slot、
  8H=4×32-bit H slot。每个 slot 的结果写入 128-bit accumulator，FPSR flags
  逐 slot OR；最后一个 slot 完成后才产生一次 held response。
- 保留 2S/4H 高位清零、FMA operand C、SCVTF 符号扩展、FCVTZS/FCVTZU 整数
  raw 写回、FCMEQ 全 1/全 0 mask、FPSR OR、scalar FCMP NZCV、FP→GPR 写回。
- `lcvex_neon_fp` 4-lane 组合模块保留为 standalone P7-3/4/5 raw-bit SV
  参考 formatter，不再进入发布配置 hierarchy；核心只例化 `lcvex_fp_exec`。

## 结构共享设计

```text
ID/EX
  │  fp_exec_req_t
  ▼
lcvex_fp_exec (single owner / slot sequencer)
  ├─ slot_count: scalar=1; NEON by arrangement
  ├─ slot_mux:  32-bit lane / 64-bit lane / 32-bit H pair
  ├─ one lcvex_fp_scalar (shared 64-bit lane engine)
  ├─ 128-bit acc + 32-bit flags OR
  └─ held fp_exec_rsp_t
```

核心侧同时修复了一个 FP transaction 等待期内的相邻级同驻问题：当 ID/EX 的
FP 等待 response、而 EX/MEM 已有更老指令且可前进到 MEM/WB 时，EX/MEM 现在清成
气泡而不是保持原指令，避免同一条指令同时驻留 EX/MEM 与 MEM/WB（SVA
`!(exmem_valid && memwb_valid && exmem_pc == memwb_pc)`）。P7-4 Cocotb 首次
运行即触发该断言，修复后 scalar/vector FMA/convert 管线全绿。

## 验证

- `make compile` PASS。
- `tb/sv/lcvex_fp_exec_tb.sv` 扩展 PASS：标量 FADD/FMUL/FCMP/FDIV、NEON
  2S/4S/2D/4H/8H、FMA operand C、SCVTF 符号扩展、FCVTZS 写回、FCMEQ mask、
  flags OR、高位清零、response hold/backpressure、kill/reset。
- `make VERILATOR_JOBS=1 sim-sv-fp-scalar` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-3-neon-fp` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-4-fma-convert` PASS。
- `make VERILATOR_JOBS=1 sim-sv-p7-5-fp16-sqrt-minmax-round` PASS。
- `make VERILATOR_JOBS=1 sim-sv` PASS（core scalar + FPCR/FPSR smoke）。
- Cocotb 全绿：
  - `sim-cocotb-fp-scalar` 5/5 PASS。
  - `sim-cocotb-p7-3-neon-fp` 4/4 PASS。
  - `sim-cocotb-p7-4-fma-convert` 5/5 PASS。
  - `sim-cocotb-p7-5-fp16-sqrt-minmax-round` 8/8 PASS。

## 面积/资源变化

未运行远端 Quartus full-top/standalone synthesis（任务允许记录未跑项）。
预期发布 hierarchy 中不再出现 4 个 `lcvex_fp_scalar` lane 与 core scalar
复制；`lcvex_fp_exec` 内只有一个共享 lane engine + slot mux/accumulator。
实际 ALM/ALUT 差值待 FP-P4/P5 或独立 synthesis 任务量化。

## 边界/风险

- `lcvex_neon_fp` 的 4-lane 组合参考模块仍保留在源码供 standalone SV 测试；
  发布配置（`lcvex_core`）不例化它，若后续希望彻底删除需同步改造
  P7-3/4/5 raw-bit TB 到 clocked slot 测试。
- 未跑 L2 lockstep、Quartus fit/STA/SOF。Cocotb L0/L1 已覆盖本任务涉及的
  scalar/vector pipeline、FPEN、backpressure、unsupported UDEF。
- FP latency 将随 slot 数线性增加（标量 1 slot、4S/8H 4 slots）；这是单
  lane 首选方案的预期代价，待 FP-P4 workload 分析。
