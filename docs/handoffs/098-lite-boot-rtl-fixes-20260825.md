# 098 Lite 启动三处 RTL 修复（IRQ+SP、varshift、LDTR/STTR）（2026-08-25）

前置：handoff 095（lite 标量线）、097（PSTATE.DIT）
分支：`feature/p6-system-reg-shim`

## 1. IRQ 落在访存指令（LDP/STP pre/post）时 SP 写回丢失

### 现场

相对 seq=2,528,678：`LDP x29, x30, [sp], #0x40`（0xa8c47bfd）上同时取到
IRQ（next_pc=IRQ 向量）。DUT 提交包 `sp=0xffffff800082bbc0`（旧 SP），
QEMU `sp=0xffffff800082bc00`（后增后），差一个步长 0x40。

### 根因

`lcvex_core.sv` 普通 WB 提交的 `irq_taken` 块用 `commit_sp_wdata_r <=
sp_el1`，而 LDP 的 SP 写回 `sp_el1 <= memwb_sp_wdata` 在同一时钟沿
（非阻塞）尚未生效——IRQ 合并提交上报了旧 SP。

### 修复

```systemverilog
commit_sp_wdata_r <= memwb_sp_we ? memwb_sp_wdata : sp_el1;
```

顺带修正同类问题：`sys_irq_taken`（ID 级系统指令）块在 `SYS_SPSEL`
时不再覆盖其按新可见 SP 的提交（`if (d.sys_op != SYS_SPSEL)`）；
普通 `irq_taken` 块补上 PAN/DIT 清零（异常入口新 PSTATE，与 DIT 提交
一致）。

## 2. 变量移位 32 位形式移位量未掩码

### 现场

相对 seq=2,783,664：`LSLV W2, W2, W1`（0x1ac12042），W1=0x21。
ARM 语义 32 位变量移位取 Rm[4:0]（1<<1=2）；DUT 用完整 6 位量
（1<<33=0）→ 与 QEMU 差。

### 修复

`lcvex_alu.sv` 32 位分支的 LSL/LSR/ASR 用 `shift_amt[4:0]`（与已有
ROR 一致）。测试 `hard_varshift` 覆盖 W/X 各 op 与 0x21/0x20 边界；
顺带修 `a64.py` 的 `lslv/lsrv/asrv/rorv` 编码器（缺名字烘焙，无法直接
使用）。

## 3. LDTR/STTR（非特权访存）被解码为 UDEF

### 现场

相对 seq=492,054：内核 /init 启动路径 `STTR X3, [X6]`（0xf80008c3，
bits[11:10]=10）被旧 decode 排除（条件只含 00/01/11）→ UDEF
（ESR=0x02000000），QEMU 正常执行。

### 修复

- `lcvex_decode.sv`：该访存块条件加入 `2'b10`；`d.mem_unpriv` 标记；
  LDTR/STTR 无写回（与 unscaled 同）。
- `lcvex_pkg.sv` / `lcvex_core.sv`：`mem_unpriv` 传入 MMU
  `access_el`（非特权访问按 EL0 权限检查，QEMU 语义）。
- `a64.py` 新增 `sttr/ldtr` 编码器；测试 `hard_ldtr_sttr`。

## 验证

```sh
ONLY=hard_dit,hard_varshift,hard_ldtr_sttr,hard_irq,hard_psci \
  bash sim/difftest/run_m2_4b.sh   # base/cache 全绿
```

Lite 标量线续跑逐次跨过三个失败点（各修复后 resume 验证）。

## 压缩后的首条命令

```sh
git log --oneline -6
sed -n '1,200p' docs/handoffs/098-lite-boot-rtl-fixes-20260825.md
```
