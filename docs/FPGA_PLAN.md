# Catapult A10 FPGA 上板使能计划

## 定位

本计划是 P7 最终发布的并行上板使能线，不等同于完整 P10 FPGA 产品化。权威
双轨DAG、AXI4、一致性和最终阶段门见
[P7_FPGA_PARALLEL_PLAN.md](P7_FPGA_PARALLEL_PLAN.md)。

当前状态：目标平台和架构边界已冻结；B0 离线平台包、B1 AXI4、B2 EMIF、B3 L2-WB、B4 单核 D-L1/L2 probe 已在独立 FPGA 线完成模块级验证；Windows Quartus 工程缺失，B5 SoC/Boot、Quartus 综合/布线、真实系统接线和板测尚未完成。

## 目标平台

- Microsoft Catapult v3 / Mg Catapult。
- Arria 10 `10AX115N4F40E3SG`。
- Quartus Prime Pro 21.4 Build 67。
- 100 MHz板级输入，首版CPU/外设域50 MHz；DDR参考266.667 MHz。
- 72-bit DDR4物理口，512-bit Avalon-MM EMIF user interface。
- EPCQL1024 Active Serial x4；早期控制台使用Altera JTAG-UART。

平台输入来自已上板到Linux `/init` 的 sibling PoC，但只收编QSF/SDC、EMIF、
EPCQ/SFL、JTAG-UART、CDC和构建证据。所有输入记录来源、工具版本、SHA256和
再生成命令；LCVEX运行时不得依赖sibling工作树。

## 阶段

### B0-Platform：平台冻结与收编

- 建立`fpga/catapult_a10/`及platform manifest。
- 白名单收编QSF/SDC/Qsys/IP/Flash/JTAG-UART输入；不复制整个PoC目录。
- 固化器件、pin、时钟、复位、EMIF calibration和初始128 MiB地址窗口。
- 区分可再生厂商输出和必须版本管理的输入。
- fresh clone完成静态manifest、Qsys regenerate和最小平台elaboration/full compile。

### B1-AXI4：标准总线与验证环境

- L2下游使用AMBA AXI4 Full，canonical `DATA_WIDTH=128`。
- 64B line使用4-beat INCR burst；支持窄访问、WSTRB、RESP和标准背压。
- 建立独立SV与Cocotb BFM、随机slave和协议SVA。
- 首版单ID/单outstanding，但端口与类型保留ID和burst字段。

### B2-EMIF：Catapult适配器

- AXI4 128-bit与Avalon-MM 512-bit宽度转换。
- CPU/EMIF异步clock domain crossing。
- calibration完成前保持CPU/内存请求端复位或阻塞。
- 独立验证byte-enable、窄写、line读写、随机背压、reset和错误。

### B3-L2-WB：共享写回缓存

- write-back、write-allocate、dirty victim和partial-store merge。
- 包容式目标策略和`CORE_COUNT=1`的L1 probe/response。
- 维护操作、替换写回、refill/writeback fault和AXI4交互。
- 未来owner/sharer状态参数化，但不实现跨核MESI。

### B4-L1-Coherence：单核层次一致性

- D-L1改为write-back；I-L1保持只读。
- PTW观察D-L1脏页表；DC/IC维护逐级传播。
- self-modifying code、原子、屏障和checkpoint clean-to-PoC。
- P7单Q访存必须在全Cache+AXI4随机背压配置复跑。

### B5-SoC/Boot：综合与上板

- 建立仿真专用TB之外的可综合SoC顶层和板卡wrapper。
- Cache/tag/data映射M20K/MLAB，复位只清metadata，不用大规模复位数据阵列。
- BRAM裸机→DDR March→AXI压力→Cache/MMU→Timer/GIC/JTAG-UART。
- 实现AArch64 EPCQ/BRAM启动路径，再运行Linux串口/JTAG-UART冒烟。
- 记录ALM/register/RAM/DSP、Fmax、setup/hold slack、功耗估计和启动时间。

## 板级门

板测不能替代RTL/QEMU验证。进入板级前必须通过受影响L0–L2和Gate F-MEM；最终
Gate F-BOARD要求：

- EMIF calibration和DDR地址线/数据线/byte-enable测试；
- Quartus full compile 0 error，warning已分类，STA无负slack；
- SOF/JIC与输入manifest绑定；
- 冷启动/重复复位、裸机Cache/MMU和Linux `/init` 可重复；
- 失败保留SignalTap/日志/构建报告，但大型产物不进普通Git历史。

## 明确后置

- 完整2 GiB地址空间和ECC/RAS签核；
- 多核MESI/MOESI、ACE/CHI和硬件一致DMA；
- P8 SVE、P9 JTAG/GDB/PMU；
- 多板型、量产时序余量、功耗和长期可靠性产品化。
