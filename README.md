# LCVEX AArch64 CPU Core

LCVEX 是一个从零开始实现的 AArch64 CPU 核心项目。项目首先面向可验证性和架构正确性，使用修改后的 QEMU 进行逐指令差分测试；在核心仿真测试通过后，再移植到 Altera/Intel FPGA，并逐步加入 Linux 所需的平台功能。

## ISA 范围（重要）

**本项目实现的是一个有限的 AArch64 指令子集，不是完整指令集，也不宣称
ARMv8.2-A 架构合规。** 请按“够用且逐条被差分验证过”来理解它的能力边界：

- 范围以 [`docs/V82_PROFILE_MANIFEST.md`](docs/V82_PROFILE_MANIFEST.md) 的
  机器可检查清单为准：共 117 条 profile 行，其中 `implemented` 94 条、
  `shim` 8 条、`udef` 1 条，另有 13 条明确后置、1 条受阻。
- 主体是标量整数与系统/异常/MMU/Cache（`V82-BASE` 67 条 implemented）；
  FP/Advanced SIMD 是**选定子集**（`V82-SELECTED-EXT` 27 条 implemented），
  饱和、narrow/widen、permute、table 等剩余 FP 族尚未实现并按保留编码
  `UDEF` 处理。
- **SVE、SVE2、SME/ZA 明确排除**在项目范围之外（仅保留探测 shim）。
  未实现的系统指令返回 `PSCI_RET_NOT_SUPPORTED`；未实现的编码走 `UDEF`
  异常，而不是静默按错误语义执行。
- 因此：不要把它当作通用 ARM64 兼容核使用；能跑通 Linux 6.6 与本文档记录的
  工作负载，不等于能执行任意 AArch64 程序。逐条指令明细见
  [`docs/ISA_SCOPE.md`](docs/ISA_SCOPE.md)。

## 已确认的基线

| 项目 | 决定 |
| --- | --- |
| 架构 | ARMv8.2-A，AArch64 only |
| 微架构 | 单发射、顺序执行、非 OoO |
| RTL | SystemVerilog |
| 仿真 | Verilator |
| 验证 | Cocotb + SystemVerilog testbench |
| 参考模型 | 最新稳定版 QEMU release（不跟随 master） |
| 差分测试 | 本地 QEMU fork + patch，逐条指令单步比较 |
| 早期内存 | 1-cycle SRAM |
| Cache | 分离 I/D L1，统一 L2 |
| 异常级别 | EL0 + EL1 |
| 软件目标 | 裸机 C → RTOS → Linux |
| SIMD/FP | 标量核心稳定后实现 NEON/FP，再实现 SVE256 |
| 调试/PMU | 核心测试通过后实现 JTAG/GDB 和简化 PMUv3 |
| FPGA | 最后阶段移植到 Altera/Intel FPGA |

## 当前状态（2026-09-30）

- **核心与验证**：P0–P5 阶段门（Gate A–D）已通过；标量 + MMU/Cache + 异常 +
  FP/NEON 垂直切片均有定向测试与 QEMU 逐指令差分覆盖。
- **Linux**：Linux 6.6 lite 在 QEMU 与 Verilator 全系统仿真中进入用户态；
  `Catapult A10` 板级 DTB、GICv2、Generic Timer、Altera JTAG-UART 已接通。
- **真板里程碑**：AArch64 核心已在 Catapult A10（Arria 10，10AX115N4F40E3SG，
  单核 25 MHz，no-FP profile）上**从 EPCQ Flash 冷启动 Linux**，进入 `/init`
  用户态，并通过板载 JTAG-UART 完成 `help` / `echo` / `sleep` 串口交互。
  物理流程（synthesis/fitter/STA/assembler）0 errors，`sys_clk_25`
  setup/hold 余量为 `+5.723/+0.018 ns`，全时钟 TNS 0。

复现入口：[Linux 板级启动计划](docs/LINUX_BOARD_BOOT_PLAN.md)、
[JTAG 烧写 SOP](docs/FPGA_A10_JTAG_BURN_SOP.md)、
[T-20260928-002 交接](docs/handoffs/T-20260928-002-a10-linux-boot.md)。
详细快照见 [PROJECT_STATUS.md](docs/PROJECT_STATUS.md) 与
[ROADMAP.md](docs/ROADMAP.md)；FP/NEON、多核、SVE、PMU 等后续工作按路线图推进。

## 开发原则

1. 先建立 QEMU difftest，再扩展 RTL。
2. 任何指令都必须经过单元测试和差分测试。
3. 早期只使用 1-cycle SRAM，不让 Cache、MMU、中断干扰标量流水线调试。
4. SIMD/FP、Linux、JTAG、PMU 和 FPGA 都有明确的阶段门，不提前引入。
5. 只有在 commit 阶段修改架构状态；流水线内部状态不直接作为验收依据。
6. QEMU 使用固定的最新稳定 release，并通过本地 patch 管理修改。

## 文档索引

- [当前状态、质量评估与后续规划](docs/PROJECT_STATUS.md)
- [项目路线图](docs/ROADMAP.md)
- [详细开发计划](docs/DEVELOPMENT_PLAN.md)
- [架构和微架构](docs/ARCHITECTURE.md)
- [提交包与 Trace 格式](docs/COMMIT_PACKET.md)
- [ISA 实现范围](docs/ISA_SCOPE.md)
- [QEMU 差分测试](docs/DIFFTEST.md)
- [QEMU–Verilator 锁步差分测试详细计划](docs/DIFFTEST_QEMU_PLAN.md)
- [验证计划](docs/VERIFICATION.md)
- [工具链固定版本](docs/TOOLCHAIN.md)
- [Git 工作流](docs/GIT_WORKFLOW.md)
- [多 Agent 并行协作与资源调度](docs/MULTI_AGENT_WORKFLOW.md)
- [任务注册表与任务模板](docs/tasks/README.md)
- [Handoff 交接规范](docs/handoffs/README.md)
- [架构/流程决策（ADR）](docs/decisions/README.md)
- [稳定子域与文件所有权](docs/domains/README.md)
- [Linux 支持计划](docs/LINUX_PLAN.md)
- [Linux 板级启动计划（仿真 / Flash 镜像 / 冷启动）](docs/LINUX_BOARD_BOOT_PLAN.md)
- [FPGA 移植计划](docs/FPGA_PLAN.md)
- [Catapult A10 JTAG 烧写 SOP](docs/FPGA_A10_JTAG_BURN_SOP.md)
- [25 MHz 板级 bring-up 计划](docs/BRINGUP_25MHZ_PLAN.md)
- [调试和 PMU 计划](docs/DEBUG_PMU_PLAN.md)

## 推荐开发环境

早期开发不依赖 FPGA。工具链版本固定，见 [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md)。

## 快速开始

```sh
conda env create -f env/environment.yml
conda activate lcvex
make test
```

`make test` 依次执行：工具链版本核对（toolcheck）、RTL lint
（compile）、独立 SystemVerilog testbench（sim-sv）和 Cocotb smoke
test（sim-cocotb）。

P1 差分测试：

```sh
make difftest
```

需要先在 `../qemu` 构建 QEMU（aarch64-softmmu + plugins，见
[docs/DIFFTEST.md](docs/DIFFTEST.md)）。

P2 起 `make difftest` 同时运行 RTL 核心 ↔ QEMU 的逐指令差分
（Cocotb 加载程序 → 收集提交包 → 与 QEMU trace 比较）。

板级（Catapult A10）相关检查与仿真：

```sh
python3 fpga/catapult_a10/tools/check_platform.py     # 平台清单/来源/锚点
bash    fpga/catapult_a10/tools/lint_platform.sh      # 板级 RTL lint
make sim-sv-gic-spi b25-flash-path-test               # GIC SPI 与 EPCQ 只读通路
make b25-linux-boot-test                              # 128 MiB Linux 全系统启动仿真
```

重型作业（Quartus、Linux 长跑、锁步批次）统一通过
`/home/chiro/projects/.resource-locks/resource-lock` 取得 `local` 或 `gamepc`
独占锁后再执行，详见 [多 Agent 协作规范](docs/MULTI_AGENT_WORKFLOW.md)。

## 目录结构

```text
rtl/          SystemVerilog RTL 与 filelist
tb/sv/        独立 SystemVerilog testbench
sim/cocotb/   Cocotb 测试
sim/difftest/ QEMU 差分 trace 解析、参考模型与运行脚本
baremetal/    裸机程序（Linux lite、板级 microbench、交互式 init）
configs/      Linux 内核 fragment 等平台配置
fpga/         Catapult A10 平台：Quartus/Qsys 工程、加载器、Flash 打包与板测脚本
scripts/      工具链检查等脚本
env/          conda 环境定义
qemu/         固定 QEMU 版本、差分插件与补丁（fork 在 ../qemu）
docs/         项目与验证文档
```

## 验收口径

- **第一阶段（已完成）**：在 Verilator 中运行单发射标量核心，使用 1-cycle SRAM
  执行 AArch64 程序，每条提交指令的架构状态与修改后的 QEMU 单步结果一致。
- **后续阶段**：MMU/Cache、异常、FP/NEON、Linux 与 FPGA 各自按路线图的阶段门
  验收；板级结论必须以真板证据为准，不能用仿真或历史 SOF 代替。
- `main` 只接受通过本地 Gate D 的稳定提交；功能开发走 `feature/<topic>`，
  阶段门由集成者合并，流程见 [Git 工作流](docs/GIT_WORKFLOW.md)。

## 已知边界

- 板级 Linux 目前是**单核 25 MHz、no-FP（不执行 FP/NEON）、整数指令 `/init`**
  的最小可用镜像，不是完整发行版；BusyBox、网络、块设备、多核与 full-FP 板测未做。
- DDR 压力测试、长时间运行与 Cache 一致性压力尚未作为验收项完成。
- QEMU 参考模型固定在已验证的稳定 release，升级需要同时更新
  [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) 与 difftest 基线。
