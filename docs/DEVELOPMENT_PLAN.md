# 详细开发计划

时间为相对估算，实际以验收门为准，不以日历时间强行切换阶段。

## P0：项目初始化

任务：

- [x] 建立 RTL、仿真、软件、QEMU patch 和文档目录。
- [x] 固定 SystemVerilog、Verilator、Cocotb 版本。
- [x] 固定最新稳定版 QEMU release，并记录版本和校验信息。
- [x] 建立 Makefile/脚本入口和 CI。
- [x] 定义 commit packet 和 trace 格式。

验收：空模块可以编译、仿真、运行一个失败可诊断的测试。

状态：已完成。验收通过记录见提交 `infra: add P0 project skeleton`；
本机验证命令为 `make test`（toolcheck + lint + SV testbench + Cocotb）。

## P1：QEMU difftest

任务：

- 在本地 QEMU fork 中加入单条指令执行接口。
- 实现状态导出和内存写入记录。
- 编写 Cocotb runner 和状态比较器。
- 完成 `ADD/SUB/NOP` 的端到端样例。

验收：同一初始状态下 QEMU 单步结果可稳定重复。

## P2：标量执行语义

任务：

- [x] 完成寄存器堆（x0~x30 + XZR 语义）和 PSTATE（NZCV）。
- [x] 完成 Decoder、ALU、移位器。
- [x] 加入基础数据处理和分支指令（见 `docs/ISA_SCOPE.md` 实现状态）。
- [x] 在 1-cycle SRAM 上实现取指和访存（字节写使能）。

验收：D0/D1 标量差分测试通过。

状态：已完成。寄存器堆、PSTATE、Decoder、ALU、分支和 1-cycle SRAM 的
执行语义已收敛到当前标量实现；Gate D（T-043）包含 P2 定向/随机回归并在
冻结候选上通过。这里的完成表示本项目已定义标量子集，不表示完整 ARMv8.2
指令集已经覆盖。

## P3：顺序流水线

任务：

- 实现 IF、ID/RR、EX、MEM、WB/COMMIT。
- 加入 forwarding、stall、flush。
- 加入多周期乘法和除法。
- 加入随机指令序列和汇编程序。

验收：D2 测试通过，连续随机回归无不可重放失败。

状态：已完成（Gate B 已通过）。核心已重构为 5 级顺序流水线
（IF1/IF2 取指 → ID → EX → MEM → WB/COMMIT）：

- forwarding：EX/MEM/WB 写回前递到 ID 的 GPR/SP/NZCV 读视图；
- stall：load-use（等 load 到 WB 前递）与单端口 SRAM 访存/取指争用；
- flush：分支在 ID 解析（B/B.cond/CBZ/TBZ/BR/BLR/RET），跳转冲刷
  IF/ID 并重定向取指，flush 前先抑制 load-use 依赖；
- 无效指令保持 P2 语义（停住，P4 改同步异常）。

验证：`make difftest-hazard`（forwarding/load-use/flush/NZCV/MOVK rd 依赖
定向 34 条，含 MUL/UDIV/SDIV 的 X/W 形式与除零）通过；
`make difftest-random-big`（10 万条随机，约 5% 乘除）与 QEMU 完全一致；
锁步与 Q5 无回归；T-043 冻结候选的随机 seed 1–3 × 100k 也全部通过。

乘除实现：`rtl/lcvex_muldiv.sv` 移位累加乘法 + 恢复余数除法，64 位 64
周期、32 位 32 周期；EX 忙时冻结 IF/ID 并保持 ID/EX，最后一个计算周期
组合输出 done/result，核心在同一拍推进 EX/MEM 与取指。取指采用
issue-on-capture：fetch PC 只在指令被 IF/ID 捕获后推进，在途地址重复
呈现以保持 SRAM rdata，从结构上避免重复/跳过。

Gate B（流水线 flush、stall、乘除、访存延迟）已覆盖。

## P4：同步异常和系统状态

任务：

- [x] QEMU fork 精确 step hook（Q6，`LCVEX_DIFFTEST_STEP=1`）：
      单指令 TB + 异常入口记录 ESR.EC，插件 `mode=step` 把同步异常
      转成带 `exc_valid/exc_code` 的 COMMIT；SVC/UDF/ERET 已通过
      `make q6` 验证，P0–P3 全量回归无变化。
- [x] 实现 EL0/EL1 基本状态（P4b）：EL/SP_sel/DAIF、SP_EL0/SP_EL1、
      ELR_EL1、SPSR_EL1、VBAR_EL1（reset/权限/提交时机见
      `docs/ARCHITECTURE.md`）。
- [x] 实现同步异常、异常向量和 `ERET`（P4b）：UDEF/SVC/IABT/DABT
      在 ID 级提交，分支/ERET 越界合并为 IABT。
- [x] 增加必要的 `MRS/MSR`（P4b）：VBAR_EL1/ELR_EL1/SPSR_EL1/NZCV。
- [x] 将异常纳入 commit packet 与协调器比较（P4c 预置），并跑通
      `make p4b`（5 条异常定向锁步）。
- [x] Gate C 收尾：`make p4c` 7 组定向锁步（含 EL0 越权 MRS→UDEF、
      EL0 双 SVC 往返），P0–P3 全量回归通过；验收记录见
      `docs/ROADMAP.md` Gate C。

验收：非法指令、SVC、Abort 和异常返回测试通过（Gate C）。

状态：**P4 已完成（Gate C 通过）**。下一步 P5：MMU、TLB、I/D L1、
统一 L2（见 `docs/LINUX_PLAN.md` 与 `docs/DEVELOPMENT_PLAN.md` P5）。

## P5：MMU、TLB 和 Cache

任务：

- [x] 4 KiB 页表遍历（P5a）：L0/L1/L2/L3，TTBR0/TTBR1 双区域，
      TCR.T0SZ/T1SZ 区域划分；支持 25–48 位输入 VA，并按输入宽度从
      L0/L1/L2 启动遍历（含 Linux 常用 T0SZ/T1SZ=25）。
- [x] 基础 TLB（P5a）：64 项全相联，L3 页缓存。
- [x] 权限、属性和 fault（P5a）：AP/UXN/PXN 检查，翻译/权限 fault
      复用 P4b 的 DABT 提交路径；MAIR 用于 Device/不可缓存旁路属性。
- [x] 取指翻译与 IABT 合并（P5a-2）：IF 级翻译 if_pc；取指翻译
      fault 按 QEMU 提交流合并到上一条指令的 WB/ID 提交（保留该指令
      已执行的写回）；ERET/MSR 在 ID 提交前等 next_pc 取指翻译判定。
- [x] 分离 I/D L1 Cache（P5b）。
- [x] 统一 L2 Cache（P5b）。
- [x] barrier（ISB/DSB/DMB）和 Cache maintenance 的基础语义（P5b）。

验收：地址转换、权限 fault、Cache hit/miss 和失效测试通过。

状态：已完成（Gate D 已通过）。**P5a（数据翻译）+ P5a-2（取指翻译与
IABT 合并）以及 P5b（I/D L1、统一 L2、维护基础语义）均已完成**；
T-043 在同一冻结候选上通过 Cache/MMU/维护定向、延迟注入和全量回归。
仍未覆盖的维护扩展与缓存一致性余量记录在 `docs/ISA_GAPS.md`，不再把
P5 阶段整体标为进行中。

## P6：Linux bring-up

任务：

- PL011 兼容 UART。
- Generic Timer。
- GICv2 或等价中断控制器。
- Device Tree。
- 原子指令和内存屏障。
- `WFI`、必要 PSCI 接口。

验收顺序：Linux head.S → early console → 内存管理初始化 → init 启动。

Gate E 冻结前的附加条件：

- 在同一冻结 SHA 上重跑 Gate D 全量，并保存可审计的本地/CI evidence；
- 使用固定 QEMU 11.1.0、Image/DTB/CPU/machine/icount 和 strict checkpoint
  manifest，fresh root 与 continuation 均能复现；
- 明确 early-boot 里程碑（PC/提交序列/console 证据）以及是否要求 EL0
  `/init` 和稳定用户态窗口；动态指令数量不能单独替代阶段门；
- 任何 mismatch、输入 hash 变化、PSCI/WFI/Timer 等待超时或资源超限均须
  分类并保留失败现场，不能继续累计后续指令。

状态：P6 本地退出条件已满足（T-043 Gate D + T-044 lite 35M 到
`/init ready`，另有 main 5M early-boot continuation）；正式 Gate E、
`main` 晋级和 CI 仍待阶段回顾确认，不能把本地退出写成正式晋级。

## P7：FP/NEON

状态：协议冻结已落实 Sol 深审并于2026-08-27通过用户人工审核；尚未实现
FP/NEON，可按P7-0至P7-3登记垂直任务。

任务：

- 审核并落实 `P7_FP_NEON_PROTOCOL.md`：Cortex-A76 Gate-F profile、V0–V31、
  FPCR/FPSR/CPACR、V1 scalar required handshake、raw-bit trace/失败包、552B
  LCVXFP01 原子 checkpoint 与旧链拒绝规则；不得替换既有 P6/Linux max 基线。
- P7-0：FPCR/FPSR reset/mask/访问 trap 和 V state；P7-1：选定 FP32/FP64
  标量；P7-2：选定 NEON 整数和单 Q 访存；P7-3：选定 NEON 浮点。
- 每层加入定向、raw-bit NaN/FPSR、QEMU strict lockstep 与 checkpoint；结构化
  多寄存器向量访存、未列 FP 族和 P8 SVE 不得被隐式纳入。

验收：P7-0…P7-3 通过 L0–L3；Gate-F frozen SHA 还须完整 Gate D 和 P6
checkpoint/max 兼容。用户既定策略允许以 T-046 的 P6 本地 Gate-E 在 feature
分支进入实现；正式 Gate-F/main/CI 晋级仍按正式条件。所有未列 FP/Advanced SIMD
架构族闭合前不得宣称完整 ARMv8.2-A FP/NEON 合规。

## P7-B：Catapult A10 上板使能（与P7并行）

状态：平台和架构路线已冻结，实现尚未启动。该线属于P7最终发布所需的上板
回归，不等同于完整P10产品化。

任务：

- B0-Platform：收编Catapult v3、Arria 10、Quartus 21.4、EMIF、QSF/SDC、
  EPCQ和JTAG-UART的可重放输入；
- B1-AXI4：标准AMBA AXI4 Full 128-bit canonical接口、BFM和协议SVA；
- B2-EMIF：AXI4到512-bit Avalon-MM及CPU/EMIF CDC；
- B3-L2-WB：包容式共享L2 write-back和单客户端probe；
- B4-L1-Coherence：D-L1 write-back、PTW一致性、DC/IC维护和checkpoint排空；
- B5-SoC/Boot：可综合SoC、BRAM、复位/calibration、AArch64 Flash/DDR启动和板测。

并行限制：P7-2持有`core/pkg/soc_tb`访存热点期间，B3只做L2模块级实现；B4核心
接线必须等P7-2合并。QEMU fork只由P7线串行修改。完整分支、写集和阶段门见
[P7_FPGA_PARALLEL_PLAN.md](P7_FPGA_PARALLEL_PLAN.md)。

验收：Gate F-MEM和Gate F-BOARD通过，并在同一`feature/p7-final`冻结SHA与
Gate F-ISA、完整Gate D共同形成Gate F-RELEASE。

## P8：SVE256

任务：

- Z/P/FFR 寄存器。
- 固定 VL=256 bit。
- 谓词、向量 Load/Store 和基础运算。
- 向量异常和内存访问边界。

验收：基础 SVE 指令和谓词测试通过；SVE2 不在当前范围内。

## P9：调试和 PMU

任务：

- 仿真 GDB RSP。
- JTAG TAP 和暂停/恢复/单步。
- 简化 PMUv3，先实现 4 个计数器。

验收：GDB 可断点、单步、读写寄存器；PMU 计数与提交/周期事件一致。

## P10：Altera/Intel FPGA

P7-B只完成固定Catapult A10平台的首板使能。以下任务保留为未来产品化：

- 多板型和可配置平台支持。
- 完整2 GiB、ECC/RAS、功耗和长期可靠性签核。
- 量产时序余量、升级/恢复和制品发布流程。
- 与P9调试/PMU及未来多核平台的产品级整合。

验收：板上运行裸机程序，随后运行已通过仿真的 Linux 冒烟测试。
