# 架构和微架构说明

## 架构范围

- ARMv8.2-A AArch64 only，不实现 AArch32。
- Little Endian。
- 单核。
- EL0 + EL1；EL2、EL3、TrustZone 和虚拟化后置。
- 初期关闭 MMU、Cache 和异步中断。
- 后续使用 4 KiB granule 的 EL1 MMU。

## 微架构

第一版为单发射、顺序执行、顺序提交流水线：

```text
IF → ID/RR → EX → MEM → WB/COMMIT
```

所有可见架构状态在 COMMIT 阶段更新。流水线需要处理：

- ALU forwarding
- Load-use stall
- 分支目标计算和错误路径 flush
- 多周期乘法/除法的占用
- 访存响应等待
- 同步异常导致的流水线清空

不实现寄存器重命名、乱序执行、推测提交或多发射。

## 寄存器和状态

- `X0`～`X30`：64 位通用寄存器。
- `W0`～`W30`：低 32 位视图，写入后高 32 位清零。
- `SP`：独立的栈指针语义，不与 `XZR` 混淆。
- `XZR/WZR`：读为零，写入丢弃。
- `PC`：当前架构指令地址。
- `PSTATE.NZCV`：条件标志。
- `PSTATE.EL/SP`：当前异常等级与栈指针选择（P4b 起，复位 EL1h）。
- `PSTATE.DAIF`：异步中断掩码（P4b 起，复位全置位，与 QEMU 一致）。
- `PSTATE.PAN/DIT/ALLINT`：P6 保存/恢复 Linux 当前使用的状态位；ALLINT
  位于 bit13，只有 `SCTLR_EL1.NMI=1` 时参与普通 IRQ 屏蔽。
- `SP_EL0` / `SP_EL1`：分 EL 的栈指针；当前可见 SP 由 EL/SP 选择。
- `ELR_EL1`：EL1 异常链接寄存器。
- `SPSR_EL1`：EL1 保存的程序状态（bit31:28=NZCV、bit24=DIT、bit22=PAN、
  bit13=ALLINT、bit9:6=DAIF、bit3:0=M，M=(EL<<2)|SP）。
- `VBAR_EL1`：EL1 异常向量基址。
- `SCTLR_EL1`（bit0=M 使能 MMU；PAuth 未实现，EnIA/EnIB/EnDA/EnDB
  bit31/30/27/13 写入忽略并读零）、`TCR_EL1`（T0SZ/T1SZ/TG）、
  `TTBR0_EL1`/`TTBR1_EL1`（页表基址）、`MAIR_EL1`（属性，暂未用于
  无 Cache 的 P5a）。

### 系统状态 reset/权限/提交时机（P4b）

| 状态 | 复位值 | 访问权限 | 提交时机 |
| --- | --- | --- | --- |
| EL / SP（PSTATE） | EL1h（el=1, sp_sel=1） | 异常入口/ERET 修改 | ID 级系统指令提交 |
| DAIF | 全置位（0xF） | 异常入口/ERET 修改 | 同上 |
| ALLINT | 0 | EL1 `MSR/MRS`；异常入口按 `SCTLR.SPINTMASK` 更新；ERET 恢复 | ID 级系统指令提交 |
| NZCV | Z=1（0x4） | 普通指令 / MSR NZCV / 异常 / ERET | WB 提交或 ID 级提交 |
| SP_EL0 / SP_EL1 | 0 | EL 对应的 SP 指令写 | WB 提交（按当前 EL 分 bank） |
| ELR_EL1 | 0 | EL1 可读（MRS）、EL1 可写（MSR）、异常入口保存 | ID 级提交（MSR/异常） |
| SPSR_EL1 | 0 | EL1 可读（MRS）、EL1 可写（MSR）、异常入口保存 | ID 级提交 |
| VBAR_EL1 | 0 | EL1 可写（MSR）、异常入口读取 | ID 级提交 |
| SCTLR_EL1 | 0xC50838（QEMU EL1h 复位，M=0） | EL1 可读写；高 32 位及 PAuth EnIA/EnIB/EnDA/EnDB 为 WI/RAZ | ID 级提交；checkpoint restore 使用相同写掩码 |
| TCR_EL1 / TTBR0_EL1 / TTBR1_EL1 / MAIR_EL1 | 0 | EL1 可读写 | ID 级提交 |

异常/ERET/MSR 系统指令采用 **ID 级提交**：先等更老的指令全部提交
（流水线排空），再在同一周期更新系统状态、生成提交包并重定向取指；
MRS 走普通流水线写回 GPR。同步异常（UDEF/SVC/IABT/DABT）在
ID 级提交，`exc_valid/exc_code` 写入提交包。若系统指令写后解除
`DAIF.I` 且 IRQ 已 pending，IRQ 也属于该系统指令的提交：ELR 保存顺序
下一条、SPSR 保存写后 DAIF、提交包直接转向 IRQ 向量。

### MMU（P5a：数据翻译；P5a-2：取指翻译）

- `SCTLR_EL1.M=1` 时启用 EL1 地址翻译：Load/Store 地址在 ID 级翻译
  （TLB 命中 1 周期，未命中 4 级遍历约 8 周期），翻译期间流水线全冻结；
  翻译/权限 fault 复用 P4b 的 DABT 提交路径（`exc_valid=1`，
  EC=0x24/0x25）。
- 取指在 IF 级翻译（P5a-2）：TLB 命中不冻结、遍历冻结全部级；取指
  翻译 fault 按 QEMU 提交流合并到上一条指令的提交（IABT，`exc_valid=1`、
  ELR=故障取指 VA、保留该指令已执行的 GPR/SP 写回）；ERET/MSR 在 ID
  提交前等待 next_pc 取指翻译判定（fault 则合并为 IABT）。
- 页表：4 KiB 颗粒、25–48 位输入 VA，TTBR0/TTBR1 双区域
  （T0SZ/T1SZ）；起始级别按输入地址宽度选择 L0（40–48 位）、L1
  （31–39 位）或 L2（25–30 位），覆盖 Linux 常用的 39 位配置；
  L0/L1/L2 表描述符 + L3 页描述符；块描述符（2 MB/1 GB）暂不支持；
  AF 必须置位；AP/UXN/PXN 权限检查；TLB 8 项全相联，无 ASID/TLBI。

## 早期内存接口

早期使用同步 1-cycle SRAM；P6 起扩展为 128 MiB RAM
（`0x40000000..0x48000000`，与 QEMU virt 机器布局对齐）：

```text
周期 N：发出地址、读写方向、字节使能和写数据
周期 N+1：读请求返回数据；写请求完成
```

接口必须表达字节写使能，保证 `STRB/STRH/STR` 等不同宽度访问可以正确验证。Cache、MMU 和 AXI4 都通过适配层接入，不直接耦合流水线。

P6 加入地址路由（`lcvex_mem_router`，组合转发、零额外延迟）与 PL011
MMIO 模型（`lcvex_pl011`，语义复刻 QEMU，见 `docs/ISA_SCOPE.md`）：

```text
取指/访存/PTW → 仲裁 → [L1/L2] → 延迟注入 → 路由
                                               ├→ RAM（0x40000000..0x48000000）
                                               └→ PL011（0x09000000..0x09001000）
```

MMIO 访问在核心侧标记不可缓存（`bypass=1`），L1D/L2 直通不分配；
MMU 允许 PA 落入 MMIO 窗口（`cacheable=0`）。

```text
取指/访存/PTW → 仲裁 → [L1/L2] → 延迟注入 → 路由
                                               ├→ RAM（0x40000000..0x48000000）
                                               ├→ PL011（0x09000000..0x09001000）
                                               └→ GICv2/GICv2m（0x08000000..0x08021000）
```

GICv2（`lcvex_gic`）单核无安全扩展模型：GICD/GICC 寄存器按 QEMU
arm_gic.c 语义复刻（探针复位值）；CPU 接口 best_irq/PMR/组使能选路，
`irq` 输出接核心异步异常入口（向量 +0x280/0x80/0x480，exc_code=0x40）。
定时器 PPI 电平输入已预留（PPI 26/27 <- timer IRQ）。

## Generic Timer（P6）

`CNTPCT/CNTVCT` 计数器在**提交时 +1**（与 QEMU `-icount shift=0` 的
“1 虚拟 ns/指令、CNTFRQ=1GHz”语义对齐，CNTPCT = 已执行指令数）；
MRS 读值在 EX 级用 `cntpct_r + 1` 计算（本指令计入）；`ISTATUS` 读时
组合求值；`TVAL` 读截断 32 位、写 `cval = count + sext32(value)`；
CTL/CVAL 按 QEMU `gt_*` 语义读写。定时器中断线输出供后续 GIC 接入。

`WFIT/WFET Xt` 在系统指令提交边界读取 Xt，并与 `CNTVCT_EL0` 的当前值
比较：未到期时保存等待 PC/指令和超时值进入 idle，`WFIT` 由计数到期或
IRQ 唤醒，`WFET` 还可先消费本地事件寄存器；到期恢复不产生额外提交。
QEMU 11.1.0 的 `wfxt_timer` 通过 fork 的 idle hook 退休等待指令，恢复后
再从下一条指令建立 PRE，保持协议序列一一对应。

## 异步中断（P6）

IRQ 在普通提交边界取走（DAIF.I=0）：ELR/SPSR 保存、PSTATE -> EL1h +
DAIF 全置、向量 `VBAR+0x280`（EL1h）；QEMU fork 在 step 模式把异步
异常上报为 exc_code=0x40 的 COMMIT（lcvex_difftest.c），RTL 与之对齐。

## Cache 层次

目标层次结构为：

```text
取指 → L1 I-Cache ┐
                  ├→ 统一 L2 → 下级内存
访存 → L1 D-Cache ┘
```

当前实现参数：I/D L1各4 KiB、64B line、直接映射；统一L2为32 KiB、2-way，
均为阻塞式单未完成事务。D-L1和L2当前采用write-through，DC clean/invalidate
仍依赖该假设；这不是P7-B最终写回层次的完成状态。

### P7-B 写回、一致性与 AXI4 目标（待实现）

P7-B将D-L1和共享L2改为write-back/write-allocate，L2采用包容式目标策略并在
驱逐前probe L1。当前只实现`CORE_COUNT=1`的单客户端一致性：PTW必须观察D-L1
脏页表，DC/IC维护必须逐级完成，MMIO保持不可缓存，DMA/HPS默认为non-coherent。

共享L2上游接口预留core/source/transaction ID、line command、probe response和
owner/sharer状态；单核时退化为一位，不代表已经实现多核MESI。未来扩核在该边界
增加跨核probe和目录状态，L2以下接口保持不变。

L2下游通用总线固定为AMBA AXI4 Full。Catapult canonical profile为128-bit，
64B line使用4拍INCR burst；首版单ID/单outstanding但保留完整ID、LEN、SIZE、
BURST、RESP和LAST字段。512-bit Avalon-MM仅存在于Catapult板级适配层，不进入
通用core/cache模块。完整边界见
[P7_FPGA_PARALLEL_PLAN.md](P7_FPGA_PARALLEL_PLAN.md)。

## 向量和浮点后置接口

P7 将增加 V0～V31（各 128 bit raw state）、FPCR、FPSR 和 CPACR_EL1.FPEN，
仍为单发射、顺序提交。FP/NEON 结果、FPSR sticky flags 与 V destination 必须
在同一 WB/COMMIT 更新；FPCR/FPSR/CPACR 的 MSR 继续走 ID system commit。FPEN
未允许时，FP/Advanced SIMD 和 FPCR/FPSR 访问生成 EC=0x07 FP access trap，
不能写入任何 V/FP 状态。

P7 的 Vn 是未来 P8 Zn[127:0] 的低 128 位别名；P7 不存储 Z 高半、P/FFR，也不
启用 SVE 指令。P7 Gate-F/checkpoint reference 固定为 QEMU Cortex-A76（关闭
EL2/EL3），既有 P6/Linux `max` 兼容线不受替换；其 z-low128 adapter 仅在高 Z
半全零的无 checkpoint smoke 中可用。CPACR 的 P7 owned mask 只涵盖 FPEN，正常
MSR、LCVXSYS3 与 restore 必须保留 P6 的 ZEN/SMEN 等非 FPEN 位。完整状态、位
掩码、协议和 checkpoint 原子恢复顺序见
[P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md)。

## 提交包

提交包是 RTL、差分测试和未来调试模块的共同边界，至少包含：

- `valid`
- `pc`
- GPR 写回使能、编号和数据
- `SP` 写回
- `NZCV` 更新
- 下一条 PC
- 内存写地址、数据和字节掩码
- 异常标志和异常编码

## 复位和早期限制

复位后进入确定的 EL1/裸机状态，PC、GPR、PSTATE、SRAM 内容和外部输入都必须由 testbench 明确初始化。早期测试禁用中断和具有外部副作用的设备访问，避免差分结果受异步事件影响。
