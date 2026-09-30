# JTAG/GDB 和 PMU 计划

## 调试阶段

调试功能在核心标量和内存系统通过后实现。建议先做仿真可用的 GDB Remote Serial Protocol，再做 FPGA JTAG。

### 最小功能

- halt/resume
- 读写 GPR、PC、PSTATE
- 单步
- 软件断点
- 硬件断点
- 内存读写
- 读取异常状态

### JTAG 方向

首先实现清晰的 TAP 和调试寄存器接口，保持 debug module 与 CPU 核心解耦。是否兼容完整 ARM CoreSight 需要另行评估，不作为第一版硬性目标。

## 简化 PMUv3

建议实现：

- `PMCR_EL0`
- `PMCNTENSET_EL0`
- `PMCNTENCLR_EL0`
- `PMOVSCLR_EL0`
- `PMCCNTR_EL0`
- `PMSELR_EL0`
- `PMXEVCNTR_EL0`
- `PMXEVTYPER_EL0`

初始提供 4 个事件计数器和周期计数器。事件编码先定义为项目文档中的稳定子集：

- cycles
- instructions retired
- load instructions
- store instructions
- branches
- branch mispredicts
- I-Cache miss
- D-Cache miss
- TLB miss

PMU 事件应从明确的提交、Cache 和 TLB 事件点产生，不能从不稳定的流水线中间信号推断。

