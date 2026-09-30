# 097 PSTATE.DIT 实现（2026-08-25）

前置：handoff 096（PSCI 复位/关机协议终止）
分支：`feature/p6-system-reg-shim`

## 触发现场

Lite 线从 `lite-rdinit-post8m` 链恢复后，在相对 seq=9,286,745
（绝对约 17.28M）失败：内核 IRQ 入口 `MRS x23, SPSR_EL1` 读到
DUT=0xa0000005、QEMU=0xa1000005，差 1 bit（PSTATE.DIT，SPSR bit24）。

根因：Linux 6.6 `cpu_enable_dit` 执行 `set_pstate_dit(1)`（`MSR DIT,#1`），
异常入口保存 SPSR 时应带上 PSTATE.DIT=1；旧 RTL 把 DIT 当 RAZ/WI
（MSR 忽略、MRS 恒 0），因此 IRQ 后读 SPSR_EL1 与 QEMU 差 1 bit。

## QEMU 实测语义（本实现的差分基准）

用 `aarch64-linux-gnu-as` + `-d int,cpu` 验证：

- `msr dit, #0x1` = 0xD503415F（op1=3, CRn=4, CRm=1, op2=2，imm=CRm[0]）；
- `msr dit, #0x0` = 0xD503405F；
- `mrs x0, dit` = 0xD53B42A0（S3_3_C4_C2_5）；
- `mrs x0, dit` 返回 PSTATE.DIT 的**原 bit24 位置**（置位时 0x1000000，
  不是 0/1）——`aa64_dit_read` 返回 `env->pstate & PSTATE_DIT`；
- `msr dit, x0`（寄存器形式）同样取 **bit24**（`aa64_dit_write`），
  与立即数形式取 imm[0] 不对称；
- 异常入口 SPSR = `pstate_read`（含 DIT），handler 的新 PSTATE 由
  `pstate_write(PSTATE_DAIF|new_mode)` 构造 → **DIT/PAN 清零**；
- ERET 从 SPSR bit24 恢复 DIT。

## 实现（rtl/）

- `lcvex_decode.sv`：新增 `dit` 输入；`SREG_DIT` MRS 读回
  `dit ? 64'h0100_0000 : 64'd0`（bit24 位置）。
- `lcvex_core.sv`：
  - MSR 立即数 `SYS_DIT`：`pstate_dit <= d.sys_wdata[0]`；
  - MSR 寄存器 `SREG_DIT`：`pstate_dit <= d.sys_wdata[24]`；
  - 同步异常（sys_exc）与异步 IRQ（sys_irq_taken）入口：
    SPSR 用 `make_spsr(..., pstate_pan, pstate_dit)` 保存旧值，
    同时 `pstate_pan/pstate_dit <= 0` 清 handler 的新 PSTATE；
  - ERET 恢复 `pstate_dit <= spsr_el1[24]`（原有）。

## 测试（sim/difftest/）

`hard_dit`（test_program.py / run_m2_4b.sh，32 条）覆盖：
MSR DIT,#1 → MRS=0x1000000 → SVC 保存 SPSR.DIT=1 → handler MRS DIT=0
（入口已清）→ ERET 恢复 → MSR DIT,#0 → 寄存器形式 `msr dit, x0`
（x0=0x1000000）→ 再次 SVC 验证。

```sh
ONLY=hard_dit bash sim/difftest/run_m2_4b.sh   # base/cache 全绿
```

## 验证

- `hard_dit` base/cache 全绿；
- Lite 从 `lite-rdinit-post8m` 链 `seq=8999999` 恢复，跨过原失败点
  （相对 9,286,745）并续跑 3,000,000 条通过；随后续跑至引导后期
  （PL011 就绪、console 使能、arch_sys_counter 切换、IRQ 正常处理）。

## 约束

- 严格差分：不因 DIT 放宽比较；实现与 QEMU 实测语义逐位对齐
  （读回 bit24 位置、寄存器写 bit24、异常入口清 PAN/DIT）。
- PAN 与 DIT 同走 `pstate_*` shim；后续若实现权限语义需同步 SPSR 位。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,200p' docs/handoffs/097-pstate-dit-implementation-20260825.md
ONLY=hard_dit bash sim/difftest/run_m2_4b.sh
```
