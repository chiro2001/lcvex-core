# B25 post-bring-up CPU microbench 与 CoreMark 计划

## 1. 目标与边界

本计划承接 T-20260907-044/T-20260920-037/T-20260920-038 已完成的 25 MHz
BRAM 启动和 polling JTAG-UART 双向交互，在同一 LCVEX Core 上建立可从干净仓库
复现的真板 microbench 里程碑。

退出条件：

1. 参数化 board runner、静态校验和操作 SOP 受 Git 管理，不再依赖某个
   `build/agents/` 目录作为唯一源码；
2. BRAM-resident AArch64 correctness microbench 覆盖整数 ALU、逻辑/移位、
   条件与函数控制流、栈、乘除法、不同宽度 Load/Store 和符号/零扩展；
3. 纳入固定上游版本、许可证和 bare-metal port 的 CoreMark；同一镜像可在
   Verilator 快速自检和 B25 真板标准运行中使用；
4. CoreMark 输出 seed、size、iterations、校验 CRC、总 cycle、25 MHz 换算时间、
   CoreMark/s 与 CoreMark/MHz。只有满足官方 seed/CRC、内存布局和至少 10 秒测量
   窗口才标记 `VALID`；否则输出 `INVALID`，不得对外宣称分数；
5. 完成受影响 L0-L2、完整 Gate D、fresh Quartus physical/约束检查、单次
   assembler、易失 SOF 真板运行和 exact golden 恢复；
6. 禁止 JIC/EPCQ/Flash 写擦、板级 reset、power-cycle、停止标准/未知进程、
   关闭断言或修改参考结果。

首批 microbench 全部驻留 64 KiB M20K，外部 DDR 不是前置条件。DDR 只通过现有
monitor `m` 命令做独立诊断；`DDR-FAIL` 不得阻塞 BRAM microbench，也不得被误写为
已验证 DDR 故障或 DDR 通过。

## 2. 冻结基线

- 集成基线：`763622496991b5cd7c743c5ff05b9678b763483c`。
- 已验证 candidate SOF：36,842,105 bytes，SHA-256
  `bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264`，
  checksum `0x315AC2B3`。
- Golden SOF：36,844,906 bytes，SHA-256
  `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`，
  checksum `0x31510BB6`，design hash `193DE4BC8A30F3ED5F1F`。
- CPU/SoC 时钟：25 MHz；首批 profile 保持 `A64_FP_SIMD=0`。
- 当前 live FPGA：T-20260920-038 已证明为 exact golden。

## 3. 任务 DAG

```text
T-20260920-039 计划与集成父任务
       ├── T-040 tracked/parameterized board runner + SOP（无硬件）
       │        └── T-041 existing candidate DDR `m` 诊断 + golden 恢复
       └── T-042 BRAM correctness microbench + CoreMark port（本地 L0-L2）
                  └── T-043 frozen candidate 完整 Gate D
                           └── T-044 fresh no-FP physical/UCP
                                    └── T-045 单次 assembler/SOF
                                             └── T-046 真板 microbench/CoreMark
                                                     + exact golden 恢复
```

T-040 与 T-042 写集互斥，可并行分析；本轮由主 Agent 串行执行。T-041 只消费旧
candidate，不修改 RTL；T-044/T-045/T-046 必须依赖最新冻结 SHA，不能复用旧绿色
结论冒充新 payload 验收。

## 4. Microbench 协议

monitor 保留既有 `p/?/m/d/echo`：

- `t`：运行有界 correctness suite，逐项更新 BRAM result table，最终只输出一条
  `MBPASS <count> <signature>` 或首个 `MBFAIL <id> <got> <expected>`；
- `v`：运行 CoreMark port 的短自检，验证 seed、数据结构、CRC 和输出通路，供
  Verilator 与真板快速比较；
- `c`：运行标准 CoreMark 测量。先用 25 MHz 单调 cycle counter 标定 iterations，
  正式区间不少于 250,000,000 cycles；正式区间不得包含 UART 输出；
- 长任务开始/结束输出短 marker，过程中不刷屏，避免 JTAG-UART 改变测量结果；
- 任何失败都回到 monitor，不允许把板卡锁死在无限循环。

计时优先使用已证明单调且频率明确的现有计数源。若现有 architectural counter 在
MMU-off/EL1 板级环境不可用，T-042 可在 `PLAT_STATUS` 增加只读 64-bit
`logic_clk_25` cycle counter；reset 值为 0，只读，不驱动 CPU/总线状态，并加入
行为级/vendor-timed/SoC 定向测试。不得使用 host wall time 计算 CoreMark 分数。

## 5. CoreMark 可复现合同

- 只从 EEMBC 官方 CoreMark 仓库固定 release/tag/commit 导入；保留原许可证、
  `README`、上游 commit 和逐文件 SHA-256；禁止构建时联网下载。
- bare-metal port 不依赖 libc、文件系统、动态内存或 DDR；工作区、栈、结果表总和
  必须通过 ELF section 与 64 KiB range checker。
- 编译器路径、版本、flags、linker script、seed、iterations、TOTAL_DATA_SIZE、
  ELF/BIN/HEX/MIF hash 全部写入 manifest。
- 本地验证至少包含：上游 CRC/seed 合规、port 单元测试、反汇编检查、镜像逐字节
  一致、CoreMark short self-check、完整 SoC `t/v`、负例和超时行为。
- 真板证据保存原始 transcript、parser result、cycle/score 算式和 artifact hash；
  `VALID` 判定由 parser 从原始字段重新计算，不能仅相信固件打印的字符串。

## 6. DDR 独立判定

T-041 使用 T-030 exact candidate，仅做一次受控会话：

1. 易失配置 candidate；等待启动并发送 `?`，要求最终看到 `CAL-OK`；
2. 发送 `m`，保存 `DDR-OK` 或 `DDR-FAIL`；再发送 `?` 交叉检查状态；
3. 不因结果重试 candidate；执行一次 exact golden 恢复并由最终 chain 证明；
4. `m -> DDR-OK` 才关闭 DDR magic 读写子门；失败则记录为独立 DDR blocker，
   不阻塞 T-042 BRAM microbench。

## 7. 验证与资源门

- 轻量分析、编译和静态测试不占 heavy slot；Verilator full-SoC、Gate D 取得
  `local`；Quartus、assembler 和真板取得 `gamepc`。
- 所有 heavy 作业使用 `/home/chiro/projects/.resource-locks/resource-lock`；锁内可按
  当前资源选择并行度，但不得影响用户交互进程。
- T-044 physical 期间，后续只做分析；必须等待 fresh timing 报告后再确定 assembler。
- 真板任务只允许易失 SOF、给定 JTAG-UART、task-owned server；禁止持久配置和
  广泛进程终止。

## 8. 文档治理

T-040 修订 `FPGA_A10_JTAG_BURN_SOP.md` 中“未上板/无 candidate”的历史状态，
把 cached standard-server design hash 陷阱、AST/ref binder、single-use marker、
candidate/golden 分离和 resource-lock 写入正式 SOP。历史 handoff/evidence 不改写。

每个后继任务分别提交 handoff/evidence；父任务在 T-046 完成后更新
`TASKS.md`、`PROJECT_STATUS.md` 和 `ROADMAP.md`。
