# 项目路线图

## 目标

实现一个 ARMv8.2-A AArch64 单核 CPU：先在 Verilator 中以标量整数子集通过 QEMU
逐指令差分测试，再加入异常、MMU、Cache、Linux和NEON/FP。当前项目以P7为最终
阶段，同时并行完成Catapult A10的AXI4、写回Cache和首板使能；SVE、调试/PMU、
多核和完整FPGA产品化后置。

## 阶段总览

| 阶段 | 内容 | 进入条件 | 退出条件 | 状态 |
| --- | --- | --- | --- | --- |
| P0 | 规格、仓库、工具链 | 项目初始化 | 可重复构建和运行空测试 | ✅ 完成 |
| P1 | QEMU difftest 基础设施 | P0 完成 | QEMU 可严格执行一条指令并导出状态 | ✅ 完成（P2 锁步；P1 批量 trace gzip/切片/回放落地见 handoff 042） |
| P2 | 标量 ISA 和 1-cycle SRAM | P1 完成 | 标量指令逐条与 QEMU 一致 | ✅ Gate A 通过（M3 继续补全原定缺口） |
| P3 | 顺序流水线 | P2 的执行语义稳定 | 随机程序和 hazard 测试通过 | ✅ Gate B 通过 |
| P4 | 同步异常、EL0/EL1 系统寄存器 | P3 稳定 | 异常向量和 `ERET` 通过差分测试 | ✅ Gate C 通过 |
| P5 | MMU、TLB、I/D L1、统一 L2 | P4 稳定 | 地址转换、Cache 和 fault 测试通过 | ✅ Gate D 通过 |
| M3 | Linux 前 ISA 收敛（插入阶段）：编译器驱动补齐指令、裸机 C、测试增强 | P5/Gate D 完成 | ISA_SCOPE 支持矩阵闭合；microbench+difftest 分层可用 | ✅ 完成（exclusive 族收尾，见 handoff 033） |
| P6 | Linux 平台功能：PL011 UART、Generic Timer、GICv2/GICv2m、DT、PSCI、更多 EL1 系统寄存器与 ARMv8.2 maintenance | P5 + M3 完成 | 能启动 Linux early boot，再逐步进入用户空间 | 🟡 本地功能完成（冻结候选 `b2568a5`：T-043 Gate D + T-044 lite `/init` 35M/main 5M；T-045/T-047/T-048 前置收尾完成，正式 `main`/CI 晋级后置） |
| P7 | FP/NEON：FPCR/FPSR、FP32/FP64 标量、NEON 128 位整数与选定浮点 | 标量和内存系统稳定 | 选定的 FP/Advanced SIMD 子集通过差分测试 | 🟡 P7-0..P7-5 垂直切片均已完成并归档；P7 与 FPGA 线已合并为 `feature/p7-final`；当前功能 RTL 基线 `a110ba3` 已通过本地完整 Gate D 13/13（T-20260830-022）；Gate F-ISA 候选就绪，F-BOARD、可信 CI、`main` 晋级、Linux/nightly 和阶段发布后置 |
| P7-B | Catapult A10上板使能：标准AXI4、写回Cache、单核一致性、EMIF和SoC/Boot | 与P7共享批准文档基线 | Gate F-MEM/F-BOARD并与P7在同一冻结SHA汇合 | 🟡 B25 25 MHz no-FP 子门：M20K/logic-immediate 修复、Gate D、fresh physical、BRAM `t/v/c` 与 parser-recomputed CoreMark（16.937 CM/s、0.677 CM/MHz）及 exact-golden postflight 已通过；T-041 `m→DDR-OK` 正控独立通过。**2026-09-30 新增：AArch64 真板 Linux 6.6 用户态 `/init` 与 JTAG-UART `help`/`echo` 交互通过，并在真实断电重上电后从 Flash 冷启动复现同一里程碑（T-20260928-002，候选 `0b822e64`，JIC `f0cec1ea…`）**；full-FP、DDR/Cache 压力与最终同 SHA 汇合后置。 |
| P8 | SVE256：固定 VL=256、Z/P/FFR、谓词与向量访存（SVE2 不在范围） | NEON/FP 稳定 | SVE 基础子集、谓词和向量访存通过测试 | ⛔ 未开始 |
| P9 | JTAG/GDB、简化 PMUv3（先 4 计数器） | 核心测试通过 | 可暂停/单步/读写状态并读取 PMU | ⛔ 未开始 |
| P10 | Altera/Intel FPGA | 仿真验收完成 | 综合、时序、板级裸机测试通过 | 🟡 进行中：corrected B25 no-FP candidate 已完成 Gate D/fresh physical/volatile SOF；真板 `t/v/c`、官方 CoreMark 原始报告与计时经 strict parser 校验，随后 exact golden 恢复并验证。**2026-09-30：no-FP 候选的 Linux 真板用户态与串口交互、EPCQL Flash 写入（`f0cec1ea…`）以及断电冷启动均已通过。**DDR/Cache 压力、full-FP 发布签核仍未完成。 |

## 关键依赖

```text
QEMU difftest
       ↓
标量执行语义
       ↓
流水线和 SRAM
       ↓
同步异常
       ↓
MMU/TLB/Cache
       ↓
Linux 前 ISA 收敛（M3）
       ↓
Linux 平台
       ├→ P7 FP/NEON ─────────────┐
       └→ P7-B AXI4/Cache/FPGA ───┤
                                  ↓
                            P7 final release
```

SIMD/FP 可以在 Linux 基础功能之后实现，但不得改变已经稳定的标量提交协议。

## 总体验收门

- Gate A：所有基础标量指令通过定向和随机差分测试。**✅ 通过**
  （P2，33 条定向 + 10 万随机）。
- Gate B：流水线 flush、stall、乘除法和访存延迟全部覆盖。**✅ 通过**
  （P3，34 条定向 + 锁步 + 10 万随机）。
- Gate C：同步异常和 EL0/EL1 状态转换正确。**✅ 通过**（P4b/P4c，
  `make p4c` 7 组定向锁步：EL1h SVC、EL0 SVC、UDEF、DABT、IABT、
  EL0 越权 MRS、EL0 双 SVC；系统状态见 `docs/ARCHITECTURE.md`）。
- Gate D：MMU、TLB、I/D L1、统一 L2 的功能测试通过。**✅ 当前功能 RTL 基线
  `a110ba3` 本地通过（T-20260830-022）**
  （`make test`、`run_gate_d.sh --parallel` 13/13 全绿：coverage、
  M2-4b/4c 40+40、delay2 32 项、P5a-Hardening 26 项、Gate C 7 组、
  P5a MMU 3 组、P4b、随机 seed 1–3 ×100k、指令覆盖记账、baremetal-C 200 条；
  `CORE_COUNT=1`/`l2_cluster` lint 也 PASS）。
- Gate E：Linux 在冻结 candidate 上进入预先定义的稳定 early boot，并满足
  同一 SHA 的 Gate D/CI、固定 QEMU 输入、连续锁步和失败可复现条件；若 P6
  退出口径包含用户态，则还必须证明 EL0 `/init`（或等价 init）进入后的稳定
  提交窗口。**🟡 冻结候选 `b2568a5` 本地通过（T-044）；CI 与 `main` 晋级
  按当前策略后置；T-046 已确认本地功能完成边界。**
- Gate F-ISA：P7 FP/NEON通过分层ISA、raw-bit差分和P6兼容测试。**🟡 垂直切片
  已完成并有本地 Gate D；尚未与 F-MEM/F-BOARD 在同一最终 SHA 绑定。**
- Gate F-MEM：AXI4、写回L1/L2、单核一致性、PTW/维护/checkpoint和完整Gate D通过。
  **🟡 本地模块/系统级与 checkpoint v4 证据已具备，完整系统级 Quartus/板级后置。**
- Gate F-BOARD：Catapult综合/STA、DDR、裸机和Linux板测通过。**🟡 B25 no-FP BRAM
  correctness/CoreMark 子门已闭合，但完整 Gate F-BOARD 仍未达到。M20K 同步读错拍与
  logical-immediate 综合分歧已修复；corrected candidate `5b33c451` 完成 Gate D
  152/0、fresh physical（25 MHz setup/hold `+9.398/+0.018 ns`）与唯一 volatile SOF。
  T-053 真板 `t/v/c` 取得 `MBPASS 24 8679CF21`、CoreMark v1.01 官方 CRC/selfcheck，
  300 iterations/442,800,996 target cycles/25 MHz；T-055 strict parser 从完整 raw
  transcript 重算得 16.937 CoreMark/s、0.677 CoreMark/MHz，并交叉核对 upstream report。
  final golden programmer + postflight 再次证明 exact golden。direct-terminal 的 c-step
  单行 regex 未处理 Windows 120 列 CSI redraw（wrapper=1），但 transcript 未改写且 strict
  parser PASS；没有重试。启动期仍见 DDR-FAIL；T-041 的 late-calibration `m→DDR-OK`
  证明 DDR magic 子门，但本 CoreMark workload 位于 BRAM，不替代 DDR/Cache 压力验收。
  full-FP 同 SHA 汇合、DDR/Cache stress、Linux 真板与发布签核仍后置。**
- Gate F-RELEASE：同一冻结SHA同时满足F-ISA/F-MEM/F-BOARD和完整Gate D。
  **未达到：B25 BRAM 裸机/串口与 DDR magic 子门已通过，但 DDR/Cache 压力、
  Linux 真板、full-FP 与最终同 SHA 汇合尚未通过。**
- Gate G：未来调试、PMU、多核和完整FPGA产品化不引入回归。

## 近期状态与下一步（2026-08-30）

- **当前主线**：`feature/p7-final`。本地软件/仿真侧证据较完整：Gate D 13/13、
  C3 四核、C4 8/16/32 规模数据、14 workload 性能快照、checkpoint v4 联合恢复、
  QEMU 13-patch fresh replay 均已有 evidence/handoff。
- **主要外部阻塞**：
  - FPGA 线 T-067 未解除：FPGA-F3/F4 均 blocked，未能将 F2 的
    blackbox→QDB→fitter-only 小工程流程落地到真实 A10/SoC 顶层；
    需要更高内存/解决 Quartus debug-fabric/Qsys/顶层 glue 问题后才能继续。
  - Gate F-BOARD（DDR、板级裸机/Linux）与完整 A10 full flow 尚无证据。
  - 可信 CI/自动 CI 已按用户要求禁用；`main` 晋级仍后置。
- **后续候选方向**（按依赖/资源排布）：
  1. 若外部 FPGA 资源解除，执行 `AUD-14`（B5 full flow / DDR / 板级），
     并视结果继续 Gate F-MEM/F-BOARD。
  2. 多核方向继续 C5/多核性能：C4 目前只证明 8/16/32 参数化与 synthetic
     趋势；真实多核指令级并发、probe 并行、per-bank/队列、Linux SMP、
     多核 checkpoint/差分仍后续。
  3. 单核发布侧可继续完整 fourcore 系统级/长 Linux/nightly、更多 profile
     闭合和发布候选整理；但不替代 FPGA/板级门。
- **声明边界**：当前所有“完成”均以仓库 evidence 为限，不宣称 A10/Fmax、
  板级启动、多核架构合规、完整 ARMv8.2-A 或正式阶段发布。

## 近期状态增量（2026-09-02）

- **F1a 完整矩阵全绿**（T-20260901-011）：196/196 pass、98/98 strict 等价、
  98/98 性能 guard、FIFO 无溢出；相对 F0 总周期 **-14.1%**。F1a 默认仍关闭，
  T-012（参数传播 + 默认-on smoke/lint）与 T-013（默认-on 完整 Gate D）待派发。
- **子代理链路冒烟通过**：T-20260902-003 已完成并提交；`T-20260902-001`
  （A10 分阶段资源探针）与 `T-20260902-002`（JTAG 烧写 SOP）已重新派发。
- **Gate 状态不变**：Gate F-BOARD 仍 blocked，T-067 未解除；`main` 晋级仍后置。

## Gate E 冻结候选口径（T-20260826-008）

进入冻结候选前，集成者必须从一个 detached candidate SHA 建立完整 evidence
链，不能把不同 worktree/提交的绿窗口拼接：

1. **Gate D 重跑**：在 candidate 上执行本地 `run_gate_d.sh` 全量（含随机延迟、
   Cache/MMU SVA、覆盖率、裸机 C 和 QEMU 定向差分），记录 source SHA、QEMU
   release/patch hash、资源和退出码。
2. **CI 可信度**：同一 candidate 通过可信 CI 的 fast/difftest 任务，并记录
   CI run、QEMU patch replay 和 artifact；若 CI 尚未覆盖某层，必须明确列为
   candidate 限制，不能用本机结果替代。
3. **early boot 判据**：固定 Image/DTB/CPU/machine/icount、strict manifest
   和 coordinator/plugin/filelist SHA；从 fresh root 与 checkpoint continuation
   到达确定的 Linux early-boot 里程碑，提交包无 mismatch/timeout/意外复位。
4. **用户态判据（若纳入 P6 退出条件）**：同一 candidate 明确观察 EL0 进入、
   `/init`（或等价 init）执行，并在规定窗口内重复通过；早期串口文本或动态
   指令数量本身不构成用户态验收。
5. **失败口径**：首个架构 mismatch、输入/manifest 错误、WFI/Timer/GIC 等待
   超时、PSCI reset/off 和资源超时分别分类；失败点之后的指令不计入通过数。

历史 T-006/T-007 的 16.5M strict 窗口证明了 checkpoint provenance；最新权威
本地证据为同一冻结候选 `b2568a5` 的 T-043/T-044：lite fresh-root 35M 到
`/init ready` 且稳定，main finalized-parent continuation 5M，两条 manifest
均 finalized 并真实回读。CI 与 `main` 晋级不纳入本轮本地长跑等待。
