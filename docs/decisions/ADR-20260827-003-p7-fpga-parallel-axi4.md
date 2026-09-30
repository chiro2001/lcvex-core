# ADR-20260827-003：P7 与 Catapult 上板双轨、AXI4 和一致性边界

状态：accepted

日期：2026-08-27

关联任务：T-20260827-050

## 背景

P7 FP/NEON 协议已经用户审核。项目还需把写通 Cache 改为写回、增加标准总线、
建立可综合 SoC 并在 Catapult v3 / Arria 10 上验证。已完成的 VexRiscv PoC 证明
板卡、DDR4 EMIF、Flash 和 Linux 启动链可用，但其 32-bit AXI→Avalon 数据路和
RISC-V 平台不能直接作为 LCVEX 架构。

当前项目是单核，用户要求先完成单核一致性，未来再扩展多核。

## 决定

1. P7 与上板使能使用独立长命分支并行开发：`feature/p7-fp-neon` 和
   `feature/fpga-catapult-a10`；最终在 `feature/p7-final` frozen candidate 汇合。
2. L2 下游通用内存总线固定为 AMBA AXI4 Full；Catapult canonical profile 为
   128-bit data，64B line 使用4拍INCR burst。宽度和ID参数化，首版单ID、单
   outstanding。Avalon-MM只存在于板级AXI4→512-bit EMIF适配层。
3. 当前实现单核写回层次和单客户端probe，不实现跨核MESI。共享L2上游从首版
   预留core/source/transaction ID、probe/response/data和owner/sharer状态，以便
   未来扩核而不重写AXI4/EMIF。
4. 首轮保持QEMU virt RAM基址和128 MiB窗口；完整2 GiB、ECC/RAS、硬件一致DMA、
   ACE/CHI、多核中断/PSCI/TLBI均后置。
5. P7-2持有core/pkg访存热点时，Cache线只做L2模块/AXI/平台工作；D-L1/PTW核心
   接线必须等P7-2合并后串行进行。

## 备选方案

- 直接复用PoC的32-bit AXI→Avalon桥：拒绝；burst未端到端保留且与LCVEX 64/128
  位数据路和共享L2目标不匹配。
- 将512-bit AXI作为通用SoC边界：拒绝作为canonical；虽合法但平台耦合强、第三方
  IP连接性较差。512-bit只保留在EMIF Avalon侧。
- 每个核直接作为AXI master访问DDR：拒绝；未来多核无法在普通AXI4下闭合私有L1
  一致性。
- 当前即实现完整MESI/ACE：后置；会扩大P7收尾范围并阻塞单核上板。

## 影响

- 新增平台/AXI4/Cache任务和验证门，但P7 ISA可在独立写集继续推进。
- 共享L2和D-L1写回改造必须处理PTW、maintenance、dirty checkpoint和异步写回
  错误，不能仅替换一个write-through状态机。
- Catapult专用文件必须隔离在`fpga/catapult_a10/`并记录来源与哈希；厂商IP不
  进入通用core/cache模块。

## 验证与迁移

按 [P7_FPGA_PARALLEL_PLAN.md](../P7_FPGA_PARALLEL_PLAN.md) 的 Gate F-ISA、
F-MEM、F-BOARD、F-RELEASE 推进。任何修订本ADR的决定必须新增ADR，不改写本文件。
