# P7-0 FP state/FPEN RTL 边界

状态：`T-20260827-051` 已完成 P7-0 独立状态模块及本次 wiring continuation
的 core/SoC/锁步接线；不代表 P7-1～P7-3、完整 FP/NEON ISA 或 Gate-F 已完成。

本实现以 [P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md) 为架构契约，
RTL 位于 [rtl/lcvex_fp_state.sv](../rtl/lcvex_fp_state.sv)。本次接线把模块加入
`rtl/filelist.f`（package 后、依赖它的 core 前），并接入 scalar core 的
ID/WB/COMMIT/checkpoint 边界。现有 `lcvex_pkg::commit_packet_t` 只在 scalar
字段末尾追加 RTL-only FP effect 字段；scalar/trap 提交仍输出零 effect，
FPCR/FPSR 的 MSR 只在对应 ID commit edge 输出 accepted effect。

## 架构状态和权限

| 状态/接口 | reset | 规则 |
| --- | --- | --- |
| `V0`～`V31` | 32 个 raw `128'h0` | 只由同一 `commit_valid` 的 effect 或 `difftest_restore_fp_valid` 更新 |
| `FPCR` | `32'h0` | 写入/读取应用 `FPCR_P7_WRMASK=32'h07c80000`，其它位 RAZ/WI |
| `FPSR` | `32'h0` | 写入/读取应用 `FPSR_P7_WRMASK=32'hf800009f`，其它位 RAZ/WI |
| `CPACR_EL1` | `64'h0` | 只有 EL1 的 system commit 可写；完整 64 位保存，P7 只消费 `[21:20]` |

`CPACR_EL1.FPEN` 的允许矩阵如下：

| current EL | `FPEN=00` | `FPEN=01` | `FPEN=10` | `FPEN=11` |
| --- | --- | --- | --- | --- |
| EL0 | trap | trap | trap | allow |
| EL1 | trap | allow | trap | allow |

`fp_access_valid=1` 且权限不允许时，模块输出：

- `fp_trap_valid=1`；
- `fp_trap_code=32'h0000_0007`（ESR.EC=0x07）；
- `fp_trap_esr=32'h1fe0_0000`（AArch64 `IL=1`、`FP_ISS.CV=1`、
  `FP_ISS.COND=0xe`，与 QEMU `syn_a64_fp_access_trap(1, 0xe)` 一致）。

trap 不会写入 V、FPCR、FPSR 或 CPACR；年轻流水线指令的冲刷由上游 scalar
commit/异常控制器负责。FPCR/FPSR system commit 必须同时带有效 FP access，
CPACR system commit 则只接受 EL1。

## 提交和恢复边界

`commit_valid` 在本模块中代表已经通过 scalar valid/ready 的实际 commit_fire。
同一提交最多携带 4 个不同的 V destination，并可同时携带 FPCR/FPSR post-state：

- `vec_write_count` 为 0～4；超过 4 或 destination 重复时整条 effect 拒绝，
  不静默截断；
- 带 V/FPCR/FPSR effect 的提交必须显式带 `fp_access_valid` 且 FPEN 放行；
- 没有 FP effect 的 scalar commit 不受 FPEN 影响；
- effect 字段仅供 RTL L1 SVA/定向检查，不是 QEMU FP_COMMIT 的同值写 oracle；
  QEMU 侧继续只比较 raw state delta。

`difftest_restore_fp_valid` 在一个时钟沿同时恢复 FPCR、FPSR 和全部 32 个 V
寄存器；FPCR/FPSR 仍应用同一 mask，V 保留全部 128 bit。既有
`difftest_restore_sys_valid` 在本模块只恢复完整 CPACR。任一 restore valid 有效
时，restore 优先于同拍 commit，并抑制该拍 effect；这对应 checkpoint 与 scalar
state 的同 edge 边界，不提供逐条回灌或层级窥探路径。

## Core/SoC wiring

- decoder 识别 `FPCR=S3_3_C4_C4_0`、`FPSR=S3_3_C4_C4_1` 的 MRS/MSR；MRS
  读 `fpcr_read_data/fpsr_read_data`，MSR 作为 ID system commit 进入状态模块。
- core 将 `CPACR_EL1` 的完整 64 位 raw state 交给 `lcvex_fp_state` 唯一拥有，
  其它核心逻辑只读该视图；FPEN[21:20] 仍按 EL0/EL1 矩阵判断访问权限。
- denied FPCR/FPSR access 在 ID commit packet 中报告
  `exc_code=0x00000007`、`exc_esr=0x1fe00000`，不产生 GPR/FP effect。
- SoC 的验证专用端口固定为 `difftest_restore_fp_valid`、masked
  `difftest_restore_fpcr/fpsr`、32 组 V low/high halves；raw observation
  暴露 `fpcr_state/fpsr_state/fp_cpacr_el1_state/fp_v_{lo,hi}`，commit effect
  暴露 FPCR/FPSR 和四个预留 V slot。普通 SV/Cocotb 顶层将 restore 输入置零。
- coordinator 仅在 checkpoint restore 边界同时驱动 system/FP restore valid；
  每个 FP_COMMIT 先应用 QEMU raw delta，再采样 DUT raw state，并同时检查
  DUT effect 与 raw state 一致。普通 PRE/COMMIT 不把 QEMU FP state 回灌 DUT。

## 独立验证

SV 定向测试直接编译 package、FP state 模块和
[tb/sv/lcvex_fp_state_tb.sv](../tb/sv/lcvex_fp_state_tb.sv)，不依赖 filelist 或
SoC：

```sh
conda run --no-capture-output -n lcvex \
  verilator --binary --timing --assert -Wall \
  --top-module lcvex_fp_state_tb \
  -Mdir build/agents/T-20260827-051/sv/obj_dir \
  -o lcvex_fp_state_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv tb/sv/lcvex_fp_state_tb.sv
build/agents/T-20260827-051/sv/obj_dir/lcvex_fp_state_tb
```

Cocotb 使用独立入口 [sim/cocotb/Makefile.fp_state](../sim/cocotb/Makefile.fp_state)：

```sh
conda run --no-capture-output -n lcvex \
  make -C sim/cocotb -f Makefile.fp_state
```

独立 state 的两套测试均覆盖 reset、FPEN 四态/EL0+EL1、mask、CPACR EL1-only
与非 FPEN 保留、EC=0x07 syndrome、trap 无副作用、1V/4V effect、超限/重复
拒绝、纯 scalar 兼容和 restore 同沿优先级。本次 wiring 另外覆盖 SoC 上
FPCR/FPSR MRS/MSR、commit effect、raw state 采样、FPEN=00 trap 及 restore
同沿；真实 FP/NEON 算术仍未实现。

## 明确不在本切片范围

本切片不实现 FP/NEON 运算、FP/NEON 访存、P7-1～P7-3、P8 SVE，也不修改
QEMU fork、AXI/Cache/FPGA 或项目阶段 metadata。协议、trace、checkpoint
repository slice 已由前序切片提供；本次只接通其 DUT restore/effect/raw-state
边界，并用 A76 required 状态程序验证锁步。
