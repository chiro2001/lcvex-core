# P7 与 Catapult A10 上板使能并行计划

日期：2026-08-27

状态：**路线与流程已批准；B1–B4 已在 clean FPGA 线完成模块级 L0–L1，P7-0 已在 `d453e29` 完成 L0–L2 状态/协议/checkpoint 入口，P7-1 已在 `f937352` 完成受限标量 FP L0–L2；B0 exact regenerate、P7-2/P7-3、B5 SoC/Boot、真实系统接线和板级验证仍未完成。**

## 当前调度快照

- `feature/p7-fp-neon` 与 `feature/fpga-catapult-a10` 继续保持独立；当前不做跨线日常合并。
- 线内按“一个垂直任务通过其 L0–L2 后合入一次，低耦合任务可组成 integration wave”推进；不把 owner 的半成品 commit 直接灌入长期线。
- 跨线只在预定接口窗口验证：P7-2 后检查 `core/pkg/soc_tb` 与 Cache/AXI4 边界，B5 前检查顶层时钟/复位/地址空间；最终从两线各自阶段门通过的提交创建 `feature/p7-final`，在同一冻结 SHA 跑 Gate F-ISA/F-MEM/F-BOARD 和 Gate D。
- 当前 FPGA 线 B0 exact Qsys/Quartus regenerate 受 Windows 目标工程缺失阻断；B1–B4 仅表示模块级证据，不表示可综合 SoC 或板测完成。
- 当前 P7 线 P7-0 的 QEMU 0012 replay/build、顶层 FP state 接线、FPCR/FPSR raw lockstep、system backpressure、fail-fp 负路径、required smoke 和 13 列 LCVXFP01 root/resume 已在 `d453e29` 及其 evidence 通过；真实 FP/NEON arithmetic/memory 和 Gate D/F 仍后置。

本文把 P7 FP/NEON 与 Catapult A10 上板使能拆为两条可并行开发线。P7 的架构
状态与差分协议以 [P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md) 为准；本文
不修改该协议，也不声称 AXI4、写回 Cache、Quartus 工程或板测已经完成。

## 1. 范围与共同基线

- 共同代码基线是 `p6-pre-p7`（`01ed8eb`）；共同文档基线包含 T-049 的用户
  审核结论和本计划。
- P7 实现线：`feature/p7-fp-neon`，完成 P7-0 至 P7-3。
- 上板使能线：`feature/fpga-catapult-a10`，完成 B0-Platform 至 B5-SoC/Boot。
- 最终汇合线：`feature/p7-final`，只在两线各自阶段门通过后创建/推进冻结候选。
- P8 SVE、P9 JTAG/GDB/PMU、完整 P10 产品化和多核一致性实现不属于当前完成
  条件；当前仅为未来多核预留稳定边界。

“上板使能”包括可综合顶层、标准 AXI4、写回 Cache、Catapult DDR/时钟/复位、
裸机和 Linux 冒烟；不包括量产级 DDR 调优、功耗签核、ECC/RAS 完整处理或多板型
维护。

## 2. 已确认的 Catapult 平台

平台事实来自已在真机运行到 Linux `/init` 的
[`a10-linux-riscv`](../../../a10-linux-riscv/AGENTS.md) PoC：

| 项 | 冻结输入 |
| --- | --- |
| 开发板 | Microsoft Catapult v3 / Mg Catapult |
| FPGA | Arria 10 `10AX115N4F40E3SG` |
| 工具 | Quartus Prime Pro 21.4 Build 67 |
| 配置 Flash | EPCQL1024，Active Serial x4 |
| 系统时钟 | 100 MHz 输入；首版 CPU/外设域 50 MHz |
| DDR 参考时钟 | 266.667 MHz LVDS |
| DDR 物理口 | 72-bit DQ / 9 DQS，通常为 64-bit 数据加 8-bit ECC |
| EMIF 用户口 | 512-bit Avalon-MM，独立 user-clock domain |
| 已验收软件链 | Flash → DDR4 → OpenSBI → Linux → `/init`（RISC-V PoC） |

可复用资产限于 QSF/SDC、EMIF Qsys/IP、EPCQ/SFL、JTAG-UART、CDC 思路、工具
版本和可重放构建/板测流程。VexRiscv、RV32 CSR/Sv32、OpenSBI、CLINT/PLIC、
RISC-V DT、C alias 和既有 32→512 bridge 不直接进入 LCVEX。

尚待 B0-Platform 确认：DDR 模组精确 part number、完整 2 GiB 稳定窗口、物理
UART/LED 引脚。首轮 LCVEX 保持 QEMU virt 的 RAM 基址 `0x40000000` 和现有
128 MiB 窗口；板级验证稳定后再单独扩容，不能直接继承 PoC 的 `0x80000000`
地址图或调试 alias。

## 3. 标准 AXI4 边界

LCVEX 的通用内存边界固定为 **AMBA AXI4 Full**，不是类 AXI、自定义五通道、
AXI4-Lite 或 Avalon-MM。Avalon 只允许出现在 `fpga/catapult_a10/` 的板卡适配层。

首版 canonical profile：

- 五个标准通道 AW/W/B/AR/R，完整 `VALID/READY` 背压语义；
- `ADDR_WIDTH`、`DATA_WIDTH`、`ID_WIDTH` 参数化；Catapult 首版
  `DATA_WIDTH=128`，64B line 使用 4-beat INCR burst；
- 单 ID、单 outstanding 是首版性能限制，不删减 ID/LEN/SIZE/BURST/RESP/LAST；
- 支持窄访问、`WSTRB`、`BRESP/RRESP` 和 4 KiB boundary 检查；
- 首版 master 只产生 INCR，不要求产生 FIXED/WRAP 或 AXI exclusive transaction；
- 原子性在核侧/L2 一致性域闭合，不依赖 AXI exclusive；
- MMIO 保持 Device/不可缓存本地路径，不让低速外设流量进入 L2 line cache。

Catapult 专用适配器聚合/拆分 128-bit AXI beat，与 512-bit Avalon-MM EMIF 交互，
并承担 CPU/EMIF 异步时钟域跨越。AXI4 状态机、CDC 和 Avalon 转换不得嵌入 L2，
使通用 Cache 与厂商平台可分别验证。

```text
Core/L1 clients
       │
single-core coherent request/probe boundary
       │
shared inclusive L2 write-back
       │ AXI4 Full 128-bit, 4-beat/64B line
       ▼
Catapult AXI4 CDC + AXI4-to-Avalon adapter
       │ Avalon-MM 512-bit
       ▼
Arria 10 EMIF → DDR4
```

## 4. 当前单核一致性与未来多核预留

当前只实现一个核，不实现跨核 MESI/MOESI，但单核层次必须闭合：

1. D-L1 和 L2 最终为 write-back/write-allocate；I-L1 只读。
2. L2 采用包容式目标策略；驱逐前可 probe I-L1/D-L1，D-L1 脏 owner 必须返回
   最新 line，不能丢弃 dirty victim。
3. PTW 物理访问必须观察 D-L1 中的脏页表数据；不得继续无条件绕过 D-L1。
4. `DC clean + DSB + IC invalidate + ISB` 的 self-modifying-code 可见性逐级验证。
5. MMIO 永不缓存；外部 DMA/HPS master 当前为 non-coherent，依赖软件维护。
6. Cacheable store 可在脏行更新后提交；checkpoint 前执行停止提交、排空、clean
   到 PoC，restore 后 invalidate，不把陈旧 RAM 快照冒充架构内存。

共享 L2 上游接口从第一版参数化：`CORE_COUNT=1`、`core_id/source_id`、
`transaction_id`、line command、probe request/response 和可选 data-return。L2 tag
类型预留 owner、I/D sharer vector 和一致性状态；单核综合时向量退化为一位。
这些字段不是当前多核实现声明。

未来扩核时在该边界增加 ReadShared/ReadUnique/Upgrade、跨核 probe、exclusive
monitor 失效、TLB shootdown、每核 MPIDR/PSCI/GIC/SEV/WFE；共享 L2 以下的 AXI4
和 EMIF 不因核数变化而重写。外部硬件一致 DMA 若有需求，再另行选择 ACE/CHI 或
自定义 snoop bridge。

## 5. 双轨阶段与依赖

### P7 ISA 线

| 阶段 | 内容 | 退出条件 |
| --- | --- | --- |
| P7-0 | V0–V31、FPCR/FPSR、FPEN trap、wire/trace/checkpoint | P7 L0–L2；P6 scalar/max/checkpoint 兼容 |
| P7-1 | 选定 FP32/FP64 标量算术、比较和基本访存 | 每个编码定向 raw-bit QEMU 锁步 |
| P7-2 | 选定 NEON 128-bit 整数和单 Q 访存 | 1V/2store 上限、背压/fault/cache 配置通过 |
| P7-3 | 选定 NEON 浮点 | NaN/FPSR/异常边界和完整 P7 子集通过 |

### Catapult 上板线

| 阶段 | 内容 | 退出条件 |
| --- | --- | --- |
| B0-Platform | 收编并锁定 part/QSF/SDC/Qsys/EMIF/EPCQ/JTAG-UART 输入与哈希 | clean-room 可重生成平台；不含 CPU/Cache/AXI 实现 |
| B1-AXI4 | 标准 AXI4 package/master、BFM、SVA和随机 slave | 五通道、burst、窄写、错误、reset、随机背压全绿 |
| B2-EMIF | 128-bit AXI4 ↔ 512-bit Avalon-MM、CDC、calibration gate | 双时钟随机压力、数据/byte-enable/错误无丢失重复 |
| B3-L2-WB | 包容式 L2 WB、dirty victim、单客户端 probe、maintenance | SV+Cocotb scoreboard、fault和随机替换通过 |
| B4-L1-Coherence | D-L1 WB、PTW一致性、DC/IC维护、checkpoint排空 | self-modifying code、页表、原子、全Cache锁步通过 |
| B5-SoC/Boot | 可综合SoC、BRAM、复位树、JTAG-UART、EPCQ/DDR AArch64 boot | STA正slack；DDR/裸机/Linux板级门通过 |

## 6. 并行 integration waves

| Wave | P7 线 | Catapult 线 | 串行热点 |
| --- | --- | --- | --- |
| W0 | P7-0 实现 | B0-Platform | 无共享代码写集；不并行写 QEMU fork |
| W1 | P7-1 标量 FP | B1-AXI4、B2-EMIF | 顶层 Makefile/filelist 由集成者批量接线 |
| W2 | P7-2 NEON/Q 访存 | B3-L2-WB 模块级实现 | `core/pkg/soc_tb` 归 P7-2；B3 不做核心接线 |
| W3 | P7-3 NEON FP | B4-L1-Coherence | `core/pkg` 仅在 P7-2 合并后交给 B4 |
| W4 | P7 Gate-F ISA candidate | B5-SoC/Boot | 冻结 SHA 串行运行 Gate D/MEM/BOARD |

`rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、`rtl/filelist.f`、顶层 `Makefile`、
`tb/sv/lcvex_soc_tb.sv`、Gate脚本、`PROJECT_STATUS/ROADMAP` 和 QEMU patch 序列为
串行预约热点。B0/B1/B2 默认写 `fpga/catapult_a10/**`、新 AXI4 模块和独立测试，
不得提前占用这些热点。

两个功能 Agent 可同时分析/编码，但重型 Verilator、QEMU 锁步、Quartus、Linux
和 Gate 继续进入集成者队列；本机总资源遵守 50% 上限。QEMU fork 只由 P7 线的
单一任务串行修改，Catapult 线只读复用 QEMU 结果。

## 7. 验证和最终阶段门

### Gate F-ISA

P7-0…P7-3 的 L0–L2、Cortex-A76 strict lockstep、P6 max/checkpoint 兼容和完整
Gate D。它不证明 AXI4 或板级通过。

### Gate F-MEM

- AXI4 protocol assertions 和独立 SV/Cocotb BFM；
- L1/L2 dirty/refill/evict/partial-store/probe/maintenance/fault；
- PTW脏页表、self-modifying code、原子、随机延迟和checkpoint quiesce；
- 全Cache+AXI4模型的完整 Gate D 与 P7 单Q访存组合回归。

### Gate F-BOARD

- EMIF calibration、DDR March/地址线/byte-enable测试；
- Quartus full compile、资源、Fmax、setup/hold slack 和CDC审计；
- BRAM裸机 → DDR裸机 → Cache/MMU → Timer/GIC/JTAG-UART → Linux `/init`；
- SOF/JIC、工具版本、输入和日志均有 SHA256/provenance。

### Gate F-RELEASE

仅在同一 `feature/p7-final` frozen SHA 同时通过 Gate F-ISA、F-MEM、F-BOARD 和
既有完整 Gate D 后发布最终 tag。任一门失败都创建独立 regression task，不把
两条分支不同 SHA 的绿色结果拼接。

## 8. 首批待登记任务

本计划归档后由新的调度轮登记，当前不自动启动：

1. P7-0 垂直任务：RTL状态/trap + QEMU patch/plugin + coordinator/checkpoint +
   L0–L2；写集包含 core/pkg/QEMU/checkpoint 热点。
2. B0-Platform 垂直任务：只写 `fpga/catapult_a10/**`、平台 manifest、独立说明和
   可重生成检查；不复制 VexRiscv/RISC-V 软件链。

两项从同一批准文档基线登记，使用不同 topic branch 和 sibling worktree；默认
只有 `done` 依赖才可进入下一阶段。
