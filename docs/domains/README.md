# 稳定子域与文件所有权

子域文档用于帮助拆分任务，不取代任务记录中的 `writes` 预约。跨域任务仍由一
个 owner 负责，或先完成接口/协议任务再按 DAG 拆分。

| 子域 | 主要路径（示例） | 典型验证 |
| --- | --- | --- |
| `core-isa` | `rtl/lcvex_decode.sv`、`lcvex_alu.sv`、`lcvex_regfile.sv`、`lcvex_muldiv.sv`、裸机指令测试 | SV/Cocotb、microbench、定向 QEMU 差分 |
| `mem-subsys` | `rtl/lcvex_l1_*`、`lcvex_l2.sv`、`lcvex_mmu.sv`、内存通路 | SV TB、延迟/Cache 锁步、Gate D |
| `mmio-periph` | `rtl/lcvex_pl011.sv`、`pl061.sv`、`gic.sv`、`sim/mmio/` | SV/C++ fabric、定向锁步、Linux smoke |
| `difftest-infra` | `qemu/`、`sim/difftest/`、协调器和 checkpoint | patch 重放、协议 smoke、锁步回归 |
| `verify-suite` | `sim/cocotb/`、`tb/sv/`、`scripts/`、Gate 入口 | L0–L4 分层套餐、覆盖记账 |
| `fpga-platform` | `fpga/catapult_a10/`、板级wrapper、QSF/SDC、EMIF/Flash manifest和适配器 | manifest/Qsys、AXI4/CDC、Quartus full compile/STA、DDR与板测 |
| `multicore-cluster` | `rtl/lcvex_cluster_*`、`lcvex_l2_cluster.sv`、`tb/sv/lcvex_c2_*`、`scripts/mc_shell_check.sh` | C1 壳层 lint、C2 目录式 MSI/一致性 TB |

`rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、顶层 `Makefile`、Gate 脚本、
`docs/PROJECT_STATUS.md` 和 QEMU patch 序列是集成热点，默认串行预约。

## 远期任务地图（可调整顺序）

下面按“近程 → 中程 → 远程”记录主要子域的候选任务。它是路线规划，不把子域
固定为常驻 Agent，也不替代 `docs/tasks/active/` 中的具体任务登记；实际顺序以
阶段门、动态 trace 和失败证据为准。

| 子域 | 近程（P6/Gate E） | 当前（P7/P7-B） | 远程（P8～P10） |
| --- | --- | --- | --- |
| `core-isa` | 关闭 Linux 实证标量缺口；固化系统寄存器、IRQ、ERET、WFI 提交协议；标量 ISA 冻结 | V0～V31、FPCR/FPSR、FP32/FP64 与 NEON 整数 | SVE256 Z/P/FFR；调试异常、JTAG/GDB 可见状态、PMU 接口 |
| `mem-subsys` | checkpoint 恢复 MMU/TLB/Cache/未完成请求；写后失效、页边界/Device/对齐 fault；原子与屏障压力 | 128 位 FP/NEON 访存、cache/背压/fault 交互 | SVE 谓词访存与 fault；BRAM/片上总线适配和 FPGA 时序 |
| `mmio-periph` | 固化 virt 地址图/DT；PL011、PL061、Timer、GIC、PSCI smoke；IRQ/WFI 状态恢复；C model sidecar | 仅按 Linux 实证扩展 PL031、fw_cfg、virtio 等 C model | 板级 UART/GPIO/中断、Avalon/APB/AXI 封装 |
| `difftest-infra` | checkpoint v3（含 MMU/Cache/Timer/GIC/C model）；压缩 trace 与索引；切片恢复；事件序号和路径隔离 | FP/NEON commit packet、参考配置、失败前 checkpoint/二分 | SVE 状态增量压缩；Debug/PMU/FPGA trace bridge；QEMU 升级重放 |
| `verify-suite` | 测试 registry/筛选；Gate E 分级；L0～L4 套餐、资源队列、evidence/现场治理 | FP/NEON 定向/随机/编译器测试及交叉覆盖；PR/nightly 分层 | SVE/Debug/PMU/FPGA 回归、变异测试和差分 fuzzing |
| `fpga-platform` | 平台PoC只读取证与输入锁定 | Catapult B0-Platform、AXI4→Avalon/CDC、SoC/Boot、Gate F-BOARD | 多板型、ECC/RAS、功耗、量产制品和多核平台 |

### 依赖与调整规则

第一波优先做 `verify-suite` 的 registry/query 和 `difftest-infra` 的 manifest/
smoke 核对；两者完成后再从动态 Linux 缺口中选择一个 `core-isa` 或
`mem-subsys` 垂直任务。`mmio-periph` 的新增设备保持“先 QEMU 取证、再独立
C model/RTL 决策”的顺序。任何任务若暴露共享路径、QEMU patch 或提交协议风险，
集成者可以暂停后续任务并调整 DAG，不需要改写已归档 handoff/evidence。

P7-B期间`fpga-platform`首批写集限制在`fpga/catapult_a10/**`和新建的独立AXI4
测试路径；`core/pkg/Makefile/filelist/soc_tb`仍是串行热点。详细wave和交接窗口见
[P7_FPGA_PARALLEL_PLAN.md](../P7_FPGA_PARALLEL_PLAN.md)。
