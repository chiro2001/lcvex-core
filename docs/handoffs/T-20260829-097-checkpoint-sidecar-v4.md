# T-20260829-097 CONTEXTIDR_EL1 checkpoint sidecar v4 handoff

- 任务 ID：T-20260829-097（Checkpoint sidecar v4 / 恢复）
- 状态：review（owner 交付；等待集成者复核）
- 分支：`feature/T-20260829-097-checkpoint-sidecar-v4`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-088`
- base SHA：`f34f471c20de6ddca60b4925308257b780f3798b`
- sent_at：2026-08-29T14:00:00+0800（约）
- received_at：2026-08-29T14:05:00+0800（约）
- reported_at：2026-08-29T14:15:00+0800

## 实现内容

### 1. QEMU fork sidecar v4
- `qemu/include/exec/lcvex-difftest.h`：
  - `LCVEX_SYS_STATE_VERSION` 3 -> 4
  - `magic` 注释/实际串改为 `LCVXSYS4`
  - `struct lcvex_sys_state` 末尾新增 `uint64_t contextidr_el1`
  - 新 sidecar 大小 v3 540 -> v4 548
- `qemu/target/arm/tcg/lcvex-difftest.c`：
  - `lcvex_save_sys_state()` 保存 `env->cp15.contextidr_el[1]`
- 顺手修复 QEMU fork 中已有的重复声明/重复函数定义：
  - `qemu/include/plugins/qemu-plugin.h` 删除头文件保护后的重复 FP state 块
  - `target/arm/tcg/lcvex-difftest.c` 删除 `#endif` 后重复的
    `qemu_lcvex_difftest_read_fp_state()` 定义
  - 该修复是让 QEMU 能重新编译的必要前置，已声明在本任务 QEMU 写集内。

### 2. LCVEX sidecar/协调器 v4
- `sim/difftest/checkpoint.py`：
  - 新增 `SYS_STATE_V4`
  - `read_sys_state()` 支持 v4，并向后读取 v1/v2/v3
  - 返回 `contextidr_el1`
- `sim/difftest/lockstep_coordinator.cc`：
  - `DutSysState` 新增 `contextidr_el1`，`static_assert` 540->548
  - `read_sys_state_file()` 支持 v4；旧 v1/v2/v3 继续按各自尺寸读取
  - `restore_sys_state()` 写入
    `top_->difftest_restore_contextidr_el1`
  - `clear_restore_sys_inputs()` 清 0

### 3. RTL 恢复路径
- `rtl/lcvex_core.sv`：
  - 新增 `difftest_restore_contextidr_el1` 输入
  - checkpoint restore 时将 `contextidr_el1 <= ...`
- `tb/sv/lcvex_soc_tb.sv`、`rtl/lcvex_core_wrap.sv`、
  `rtl/lcvex_catapult_soc_top.sv`、Core TB / NEON / B2c / 所有 Cocotb
  restore-port 清零点补接该信号。
- `sim/microbench/microbench_runner.cc` 同步置 0。

### 4. 测试/工具
- `sim/difftest/a64.py`：新增 `contextidr_el1` 系统寄存器编码。
- `sim/difftest/test_program.py`：新增
  `build_hard_checkpoint_sys_v4_program()`：写 CONTEXTIDR -> checkpoint 点
  -> MRS 读回。
- `sim/difftest/checkpoint_v4_struct_smoke.py`：v4 struct roundtrip + v3 旧尺寸验证。

## 兼容性策略
- 旧链 v1/v2/v3 sidecar 仍可读；v4 缺失的 `contextidr_el1` 在旧链中回退为 0。
- 新链 magic `LCVXSYS4`、version 4、size 548。
- 未修改 checkpoint manifest 列/协议 frame magic；只升级系统 sidecar 内部版本。
- 未修改 QEMU plugin 协议 frame；只修改 QEMU fork 内部 sidecar 写入口。

## 验证结果

```text
# RTL lint
make compile
# PASS（Verilator Walltime 26.626s）

# QEMU fork rebuild
make -C ../qemu/build -j2 qemu-system-aarch64
# PASS：已重新链接 qemu-system-aarch64
# binary sha256 = bfc67ee45b0cf41bffa8b166517ed6dc6f6b41b636682dfe7d58b3700bc3587e

# v4 struct smoke
python3 sim/difftest/checkpoint_v4_struct_smoke.py
# PASS

# manifest smoke（兼容）
make checkpoint-manifest-smoke
# PASS

make checkpoint-resume-manifest-smoke
# PASS

# v4 测试程序生成
python3 - <<'PY' ... build_hard_checkpoint_sys_v4_program ...
# built build/difftest/hard_checkpoint_sys_v4.bin

# py_compile
python3 -m py_compile sim/difftest/checkpoint.py sim/difftest/checkpoint_v4_struct_smoke.py \
  sim/difftest/a64.py sim/difftest/test_program.py
```

### 未执行
- 未运行 `checkpoint_sys_v4` 完整 QEMU/DUT 联合恢复 smoke：
  当前 worktree 没有 `build/verilator_lockstep/lockstep_coordinator`，
  也未构建该 Verilator 协调器；完整恢复需在资源窗口
  `make lockstep-build` 后执行。
- 未运行 Gate D / Linux / P7 checkpoint 完整侧。

## QEMU/diff 文件
- QEMU fork 修改文件：
  - `include/exec/lcvex-difftest.h`
  - `target/arm/tcg/lcvex-difftest.c`
  - `include/plugins/qemu-plugin.h`（重复定义修复）
- 新 QEMU sidecar 文件 hash：
  - `lcvex-difftest.h`：
    `3ab9d8b9f3b362d4e6ffa0d27cc926000d28354ace713813f4e76320f2c78af5`
  - `lcvex-difftest.c`：
    `5e9fce5d243550bb50a30b025ad21f1ae743d0dd6a71d627032d66594e250277`
  - `qemu-plugin.h`：
    `8c5b3a6decf6e53f7760c13f79572f47f6a8cef598ee4ed093fdcc345596c321`

## 剩余风险
- 需集成者在有 Verilator 协调器的环境跑完整 `CONTEXTIDR` checkpoint/restore 锁步。
- 旧 QEMU binary 已被重建，需确认 lockstep 工具仍以新 binary 运行。
- 本次未验证 QEMU `-incoming` 是否从设备 VMState 保留 CONTEXTIDR；该字段只写
  sidecar 供 DUT 恢复，QEMU 自身状态仍由 QEMU VMState 负责。
