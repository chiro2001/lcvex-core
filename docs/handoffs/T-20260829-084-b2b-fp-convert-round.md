# T-20260829-084 B2b FP/向量转换、舍入、异常与 FPCR 访问闭合 handoff

- 状态：review
- 任务 ID：T-20260829-084（B2b）
- base SHA：`76a5b5c6d44b87773f10d9a3e05d4198288adfd7`
- head SHA：见 `docs/tasks/evidence/T-20260829-084.json`
- 分支：`feature/T-20260829-084-b2b-fp-convert-round`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-084`
- sent_at：2026-08-29T03:54:00+0800
- received_at：2026-08-29T04:10:00+0800（约）
- reported_at：2026-08-29T04:30:00+0800（约）

## 结论摘要

B2b 的目标是闭合 V82-SELECTED-EXT 中已经由 P7-4/P7-5（以及 B2a）实现的
FP/向量转换、舍入、FPSR/FPCR 访问与异常边界，而不是新增大块未批准的
FP 异常 enable trap。审计后确认：

- `EXT-FP-008/009/010`：标量整数/定点 <-> FP、FP <-> 整数/定点、FCVT
  S<->D/H<->S/H<->D 已实现，且 raw-bit 参考来自 QEMU/A76。
- `EXT-NEON-FP-003/004`：向量整数/定点转换、向量 sqrt/min/max/rint 已实现；
  向量 S/D FCVTN/FCVTL 中的 2D->2S、2S->2D、4H->4S 属于未在现有
  manifest 行承诺的扩展，本任务不宣称实现；4S->4H 窄化保持 UDEF。
- `FPCR/FPSR` 访问矩阵、FPEN 四态 trap、RAZ/WI、checkpoint restore 已由
  `lcvex_fp_state_tb.sv` 与 `sim/cocotb/test_fp_state.py`、
  `sim/cocotb/test_p7_wiring.py` 覆盖。
- 完整 FP exception enable/trap（FPCR.IOE/DZE/OFE/UFE/IXE/IDE 作为 trap
  源）仍按 POST-V82-DEFERRED 明确不实现；这些位继续 RAZ/WI，与 QEMU 11.1
  A76 的 mask 行为一致。

本任务因此不修改 RTL；本次交付为 B2b 证据闭合与 oracle 差异记录。

## Oracle 差异（QEMU 11.1.0 Cortex-A76 vs ARM ARM）

| 项 | QEMU / ARM ARM 口径 | 本实现处置 |
| --- | --- | --- |
| 四种 FPCR.RMode | RN/RP/RM/RZ 在 FCVT、FRINTX/I、算术舍入均按 raw-bit 精确 | 标量与向量共用 `round_increment`/`round_pack`，原始位参考 |
| NaN | SNaN quiet + IOC，DN=1 default NaN；DN=0 按 QEMU 的 per-op allowed-set 传播 | 与 QEMU 一致；不把多 NaN 合法差异用 epsilon 掩盖 |
| Inf/0/NaN | Inf-Inf、0*Inf 产生 default NaN + IOC；Inf/0 不置 DZC | 与 QEMU 一致 |
| subnormal | S/D 用 FPCR.FZ（IDC），FP16 用 FZ16（不置 IDC），输出 flush 置 UFC | 与 QEMU FPST_A64/F16 mask 一致 |
| FPSR sticky | IXC/IOC/OFC/UFC/DZC/IDC/QC 在 COMMIT 与 V 同沿 OR | 已由 fp_state/commit 路径实现 |
| FP exception enable | FPCR 的 IOE/DZE/OFE/UFE/IXE/IDE 为 RAZ/WI，QEMU 不 trap | 以下延迟：完整 FP exception enable/trap |
| checkpoint restore | QEMU FP sidecar 与 DUT restore 同一时钟边界，FPCR/FPSR 先 mask，V raw 128bit | 已由 fp_state restore 覆盖 |
| vector FCVTN/FCVTL | QEMU 支持；本 profile 未列入 V82-SELECTED-EXT 行 | 不在本轮闭合范围；4S->4H 等保持 UDEF |

## 已验证

```text
# 既有标量转换/四 RMode/FMA raw-unit（预编译镜像直接复跑）
./obj_dir_fp_p7_4b2/lcvex_fp_scalar_p7_4_tb
# PASS: P7-4 FP scalar FMA/conversion raw-bit vectors；exit 0

# FPCR/FPSR/FPEN/checkpoint restore 独立模块 lint
verilator --lint-only --timing -j 2 --top-module lcvex_fp_state_tb \
  rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv tb/sv/lcvex_fp_state_tb.sv
# PASS: lint exit 0

git diff --check
python3 -m py_compile sim/cocotb/test_p7_4_fma_convert.py \
  sim/cocotb/test_p7_5_fp16_sqrt_minmax_round.py \
  sim/cocotb/test_fp_state.py sim/cocotb/test_p7_wiring.py
```

注：P7-5 scalar H 全 path 的 Verilator 重建在本 owner 环境因 local
Verilator/C++ 工具链（缺少 conda `ar`）与 H-path 编译耗时未能完成一次完整
L1 新建；不把未运行的 H path 重编译作为闭合依据。

## 边界 / 阻断

- 未修改 `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv`、`rtl/filelist.f`、
  Makefile、QEMU。
- 完整 FP exception enable/trap、SVE/SME、Crypto/MTE/PAuth/MOPS 不在范围。
- 向量 FCVTN/FCVTL 未加入当前 V82-SELECTED-EXT 承诺；若后续批准新增，需
  在独立任务中实现 4S->4H 专用 S->H 路径并补 QEMU 锁步。
- 未跑 L2 strict lockstep 和 L3 Gate D；该部分由集成者在合并后资源窗口执行。

## 下一步

1. 集成者复跑 `make sim-sv-p7-4-fma-convert`、`make sim-cocotb-p7-4-fma-convert`
   与 P7-5 相关回归。
2. 若决定把向量 FCVTN/FCVTL 纳入 profile，另开实现任务，并把 4S->4H 一并
   纳入；本任务不伪称支持。
3. 由集成者更新 manifest 相应行状态与 evidence 定稿。
