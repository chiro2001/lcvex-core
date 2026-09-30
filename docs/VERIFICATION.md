# 验证计划

## 验证层次

### 单元测试

测试 Decoder、寄存器堆、ALU、移位器、乘法器、除法器、地址生成、Cache、TLB 和页表遍历器。

### SystemVerilog testbench

用于时钟、复位、接口协议、断言、波形和小型定向场景。testbench 不应依赖 Cocotb 才能发现基本 RTL 错误。

### Cocotb

用于程序加载、随机测试、QEMU 协调、差分比较、回归和失败用例保存。

### 软件测试

顺序为：手写汇编、编译器生成的裸机 C、RTOS、Linux 启动代码和用户程序。

## 必测边界

- `XZR/WZR` 读写语义
- `SP` 与 `XZR` 的上下文区别
- 32 位写入后的高 32 位清零
- 加减法进位、借位和溢出
- 负数和大于数据宽度的移位
- 分支目标和链接地址
- Load-use hazard
- 分支错误路径 flush
- 访存字节使能和符号扩展
- 非对齐访问
- 异常发生时的提交边界

## 断言方向

- XZR 永远读为零，写入无效。
- 每周期最多一个架构提交。
- 异常提交时年轻指令全部清空。
- 分支 taken 后错误路径不能提交。
- Cache line 状态始终合法。
- TLB 命中项权限与页表属性一致。
- `ERET` 只能从合法异常状态返回。

## 随机和覆盖

随机测试需要覆盖寄存器、立即数、移位、分支、地址和异常组合。每次随机测试记录种子，使失败可以重放。覆盖率至少跟踪指令类别、操作数形式、hazard 类型、分支方向、Cache hit/miss、TLB 命中/fault 和异常类型。

## 回归门

- 每次提交运行快速单元测试和 D0/D1 差分测试。
- 流水线或内存系统变更运行完整标量回归。
- QEMU patch、系统寄存器、MMU 和 Cache 变更必须运行对应阶段的全量测试。
- FPGA 集成前必须保存一次仿真回归基线。

## P7 FP/NEON 分层门（已通过人工审核）

P7 按 L0 协议/sidecar/mask 静态检查、L1 V/FPCR/FPSR/CPACR trap 的 SV+Cocotb、
L2 固定 Cortex-A76 的定向 QEMU 锁步与 checkpoint、L3 Gate-F candidate 分层推进。
所有 V、FPCR、FPSR、NaN payload、signed zero 和 FPSR sticky flags 都 raw-bit
比较；DN=0 多 NaN 仅按逐指令允许集合/掩码。P7 初期只允许两段 Q store（RTL ABI
预留八段）。每个已支持编码必须有成功、trap 或异常 flag 边界用例，并保存完整 FP
失败包。Gate-F frozen SHA 必须同时通过 P7 L0–L2、P6 checkpoint/max 兼容和完整
Gate D，不能只跑 Gate D 子集。

P7-0…P7-3 是分批验收，而不是完整 ARMv8.2-A FP/Advanced SIMD 合规宣称。具体
ISA、负测与 L0–L3 门见 [P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md)。

## P7-B AXI4、写回 Cache 与板级门

上板使能继续使用L0–L4分层，不以Quartus或真机结果替代RTL/QEMU：

- L0：AXI4 frame/width/burst静态检查、平台manifest/hash、Cache定向microbench；
- L1：SV+Cocotb独立BFM、五通道SVA、dirty/refill/evict/probe/maintenance scoreboard、
  CDC/reset/calibration正反向测试；
- L2：全Cache+AXI4随机背压的QEMU锁步，覆盖PTW脏页表、自修改代码、原子、P7
  单Q访存、fault和checkpoint clean-to-PoC；
- L3：冻结SHA的完整Gate D、Gate F-ISA和Gate F-MEM；
- L4：Quartus full compile/STA、DDR March、重复冷启动、裸机和Linux `/init`板测。

AXI4 master必须验证AW/W独立握手、VALID保持、B/R唯一响应、R/LAST、4 KiB边界、
窄访问/WSTRB、错误响应、任意通道背压和reset中止。Cache必须断言dirty implies
valid、被替换dirty line先成功写回、probe完成前不复用tag、维护/屏障完成后不存在
未确认副作用。

最终发布拆为Gate F-ISA、F-MEM、F-BOARD和F-RELEASE；四者必须绑定同一最终冻结
SHA。精确DAG见[P7_FPGA_PARALLEL_PLAN.md](P7_FPGA_PARALLEL_PLAN.md)。
