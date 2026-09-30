# 项目现状、质量评估与后续规划

本文是 LCVEX 的当前状态快照和近期执行依据。长期目标仍以
[项目路线图](ROADMAP.md) 与 [详细开发计划](DEVELOPMENT_PLAN.md) 为准；当阶段
状态或验收口径发生冲突时，应先更新本文和对应阶段门，再继续扩展功能。

## 当前权威快照（2026-09-30）

- **AArch64 真板 Linux 用户态与 JTAG-UART 交互已通过（T-20260928-002）**。候选
  提交 `0b822e64`（分支 `feature/T-20260928-002-linux-bringup`）经
  239 文件 stage 远端逐项回读 0 mismatch 后，在同一次 `gamepc` 锁内完成
  synthesis/fitter/STA/assembler：fitter 78,190 ALM (18%)、82,961 registers、
  121 RAM blocks、21 DSP；STA 的 `sys_clk_25` setup/hold 为
  `+5.723/+0.018 ns`，全时钟 TNS 0；SOF 36,842,103 bytes、SHA-256
  `dc33f5cd444f591b8efddd8736b652a1afe537f5e4319737445be5b246c862df`。
- **真板启动链**：BRAM loader 从 EPCQ 读 payload → `CHECK KERNEL/DTB` → CRC →
  `LOAD OK; EL1` → `Linux version 6.6.0`（`Machine model: LCVEX Catapult A10`）→
  `9000000.serial: ttyJ0 ... (irq = 11)` → `Run /init as init process` →
  `LCVEX Catapult A10 /init ready`；同一 JTAG-UART 会话中 `help` 返回
  `commands: help, echo [text], sleep, about`，`echo LCVEX_UART_OK` 返回
  `LCVEX_UART_OK`，提示符 `lcvex>`。原始日志见
  `build/agents/T-20260928-002/board-evidence-20260930/`。
- **EPCQL Flash 首写已打通**：写 JIC 前必须先用 Quartus 自带 Serial Flash
  Loader helper（`helper_sofs/sfl_enhanced_10_02e060dd.sof`）配置 FPGA，否则报
  `Error (209062): Flash Loader IP not loaded on device 1`。helper 配置 43.2 s，
  JIC `quartus_cpf` 转换 19.3 s，JIC 写入 8m27s、0 errors、0 warnings，
  JIC 134,217,955 bytes、SHA-256
  `f0cec1eab276fd9d8775d8bc584b7dbcc454e509ce9530fad0214231f6ef8b52`。写前已核对
  golden 恢复包在位（JIC `86ee77ad…`、SOF `290ab3cf…`）。
- **两个真实缺陷已修复**：(1) 板级 SoC 例化 `lcvex_gic` 但 QSF 未列该源文件，
  综合报 "undefined entity"，现已在 `check_platform.py` 增加“仿真 filelist 的每个
  `rtl/*.sv` 必须出现在 QSF”守卫；(2) GIC 96 项串行优先级扫描在 25 MHz 上产生
  143 ns 组合链（setup 违例 -103.394 ns），改为平衡锦标赛树后为 +5.723 ns，
  GIC 定向测试、SoC smoke 与全系统 Linux 仿真在该 RTL 上重跑。
- **断电冷启动也已通过**：用户真实断电再上电后，在**没有任何主机下载**的窗口内
  （只运行只读的 `jtagconfig`/`nios2-terminal`）完整捕获到 loader → `LOAD OK; EL1`
  → `Linux version 6.6.0` → `ttyJ0` → `Run /init` → `/init ready`，并再次回答
  `help` 与 `echo LCVEX_UART_OK`，即 FPGA 配置与 payload 全部来自 EPCQ Flash。
  （loader 的 41 字节头部会留在 JTAG-UART TX FIFO，所以中途接上终端也能拿到完整记录。）
  同一条串口随后执行 `sleep`（`nanosleep` 1 秒）返回 `sleep: 1 second elapsed`，
  再接 `echo AFTER_SLEEP_OK` 返回 `AFTER_SLEEP_OK`，覆盖 EL0 syscall、
  hrtimer/GIC PPI30 定时器中断与返回用户态路径。
  该 profile 为 no-FP（`A64_FP_SIMD=0`），单核
  25 MHz，DDR 可见 128 MiB，但默认 SWIOTLB 预留约 64 MiB，`Memory:` 报告
  `57608K/131072K available`；用户态为整数指令 `/init`，未跑 BusyBox。
- **进行中的验证**：canonical DTB（非诊断 DTB）的 128 MiB 全系统 Linux 仿真在
  GIC-tree RTL 上重跑，用于替换此前带 `swiotlb=1024`/`initcall_debug` 诊断参数的
  证据。

## 历史权威快照（2026-09-27）

- **T-044 的 BRAM/JTAG-UART 目标已闭合**：原始 T-20260907-044 失败证据保持不变；
  T-20260919-001 随后用厂商时序等价模型稳定复现首读、换地址和 debug 读取旧 word，
  修复 `lcvex_bram_boot` 的综合 M20K 同步读响应错拍。修复后 focused、行为级 BRAM、
  独立 ELF-derived oracle 13/13、CAL-OK/WAIT/FAIL 三场景 SoC 以及 compile/lint 均通过。
- **最终候选功能门全绿**：T-20260920-023/024 又定位并修复 Quartus 对 logical-immediate
  decode 的综合分歧，16,384 个编码穷举通过。T-20260920-025 在冻结候选 `c31b3aea`
  完整 Gate D 全绿：coverage 8760、M2 base/cache 40+40、delay2 32、hardening 26、
  random seed 1/2/3 各 100002 commits、ISA coverage 62/62、baremetal 200；未关闭断言、
  未跳过比较，也未修改参考结果。
- **fresh physical 与 assembler 通过**：T-20260920-027 的 fresh synthesis/fitter/STA
  为 0 errors，25 MHz setup/hold/recovery/removal 分别为
  `+7.481/+0.017/+13.549/+0.178 ns`；FIFO 24/24、data-delay 20/20 与生产 UCP/reset
  `60/624` 均通过。T-028 证明 warning 16788 只来自固定 Quartus SLD padding；T-030
  只运行一次 assembler，生成唯一易失 SOF：36,842,105 bytes、SHA-256
  `bb292699...fd264`、checksum `0x315AC2B3`、design hash
  `0CC907F3DD48A9C78864E3C5BD66B9AF`，没有 POF/JIC/RBF/JBC/SVF/JAM。
- **真板双向交互通过**：T-20260920-037 的一次 sealed candidate session 输出
  `LCVEX25 BOOT / CAL-WAIT / DDR-FAIL / READY`；同一 terminal 中 `?` 返回
  `CLOCK25 CAL-OK DDR-FAIL`、`p` 返回 `PONG`、`d` 返回 event 3/byte `0x64` 的
  `RXDBG`、`Z` 原样回显。最终 RXDBG 为 event 4/byte `0x5A`，RXPATH
  `A45A/A45A/A45A/04040400`，RXCPU getc/dispatch/putc/TX 均满足验收。
- **Golden 正控已独立恢复**：T-037 自身唯一 golden programmer 尝试失败并按合同停止；
  T-20260920-038 随后只执行一次 golden-only 易失配置，Quartus programmer exit 0，
  configuration/operation/checksum/JTAG-ID、0 errors/0 warnings 全部通过。最终标准
  `jtagconfig -n` 同时匹配 golden design hash `193DE4BC8A30F3ED5F1F`、
  `JTAG UART #0` 与 `JTAG PHY #0`，因此当前 live FPGA 已证明为 exact golden。
- **DDR 延迟校准正控已通过**：T-20260920-041 再次启动时先见
  `CAL-WAIT/DDR-FAIL`，首个 `?` 已为 `CAL-OK DDR-FAIL`；唯一 `m` 返回 `DDR-OK`，
  随后的 `?` 为 `CAL-OK DDR-OK`。这证明外部 DDR 的 uncached magic 写读子门通过，
  启动 `DDR-FAIL` 是有限等待留下的旧状态；不等同于 DDR 压力、Cache 或 Linux 验收。
- **BRAM CPU microbench/CoreMark 真板闭环已完成**：T-042 的可审计 64 KiB BRAM image
  含 24 项 AArch64 correctness 与 EEMBC CoreMark v1.01 port；T-049 修复有限 JTAG-UART
  TX 背压，修正 MIF SHA 为 `0743295f...610a2f`。在候选 `5b33c451` 上，T-050 完整
  Gate D 152 green/0 red、coverage 8760、random 3×100002、ISA 62/62、baremetal 200；
  T-051 fresh physical 25 MHz setup/hold `+9.398/+0.018 ns`、FIFO/data-delay/UCP/reset
  全绿；T-052 从 accepted fitted DB 单次生成唯一 volatile SOF
  `39c29454...a2def`，POF/JIC/RBF/JBC/SVF/JAM 为 0。
- **真板 correctness 与 CoreMark 计时通过**：T-053 在 25 MHz candidate 上的 `t`
  返回 `MBPASS 24 8679CF21`；`v` 为官方 CRC 正确的 `CMSELF PASS`，1,479,468 cycles，
  `score=INVALID`（不冒充分数）。`c` 输出 EEMBC upstream success 与 `CMRESULT VALID`：
  300 iterations、442,800,996 个硬件 cycle、25,000,000 Hz；T-055 对原始 JTAG-UART
  transcript 做严格、可审计的 120-column ConHost redraw 归一后，重新计算并交叉核对
  上游 size/ticks/seconds/iterations/CRC/compiler/BRAM/validation 字段，结果为
  **16.937 CoreMark/s、0.677 CoreMark/MHz**。direct-terminal 原单行 response regex 因
  终端右边界重绘误超时，raw transcript 和严格 parser 均保留；没有重试硬件。
- **exact golden 已恢复并证明**：T-053 最终唯一 golden programmer transaction 成功；
  postflight design hash `193DE4BC8A30F3ED5F1F`、SOF SHA
  `290ab3cf...a2385f92`、JTAG ID、UART/PHY 均匹配，standard server 保留、busy=0、
  port1310=0。T-054 仅为本任务加入固定 candidate/golden + 用户 Flash boot attestation
  的 narrowly scoped preflight policy；默认 exact-golden gate 不变。
- **安全与剩余边界**：Candidate/terminal/golden 次数严格为 1/1/1；JIC/EPCQ/Flash 写擦、
  reset、power-cycle 和停止标准/未知进程均为 0。T-053 启动仍显示 `DDR-FAIL`，但该
  workload 与 upstream manifest 明确定位在 64 KiB M20K BRAM，因此本任务不宣称 DDR
  压力、Cache 或 Linux 板测；T-041 既有 late-calibration `m→DDR-OK` 正控继续作为独立
  证据。Full-FP、DDR/Cache 压力、Linux 真板与完整 Gate F-BOARD/RELEASE 仍后置。

## 当前权威快照（2026-09-19）

- **首板结果**：T-20260907-044 已按历史成功路径两次把冻结 B25 SOF
  `032c82dd...2920b` 配置到 FPGA 易失 SRAM。两次 Quartus 均匹配 checksum
  `0x33878BC3` 与 JTAG ID `0x02E060DD`，报告 `Configuration succeeded`、
  0 errors/0 warnings；JTAG-MPSSE device 1 / instance 0 也能正常连接。
- **功能验收失败**：两次 B25 均没有输出 `LCVEX25 BOOT`、`READY`、状态行或
  `PONG`，发送 `?`、`p`、`Z` 无响应。第二次在配置结束后 2.049 秒启动 terminal，
  排除了等待过久、强制退出、stdin 管道和未释放自建 server 等流程因素。
- **Golden 正控通过**：同一 15 MHz 自建 server、programmer 与 console 路径配置
  历史 golden SOF `290ab3cf...5f92` 后，立即读到 `OpenSBI v1.9` 与 Linux 7.2.0
  日志。当前板卡最终运行 golden SOF；没有执行 JIC/EPCQ/Flash、power cycle 或
  板级 reset，也没有停止未知进程。
- **故障范围与下一步**：外部板卡/电缆/programmer/JTAG-UART 通路已由正控排除，
  故障已由 T-20260919-001 的修复前后对照证明为综合专用
  `lcvex_bram_boot_altsyncram` 在同步 M20K 接受新地址的同一沿捕获旧 `req_q`。
  旧 RTL 的 PC=0、下一 word 和 debug 读取均稳定返回前一地址；修复后 focused、
  行为级 BRAM、ELF-derived oracle 13/13 负例、CAL-OK/WAIT/FAIL SoC smoke、compile/
  lint 全绿，并已合入 `bd59d4fc`。下一步流水线并行推进 merge-SHA Gate D 和
  `A64_FP_SIMD=0` 标量 bring-up physical；旧 B25 SOF 不再使用。no-FP 只用于尽快
  验证 PC=0→UART→DDR，不代替最终 full-FP fresh signoff。
- **快速 physical 增量**：no-FP profile `d00d566d` 已完成全新远端 source closure
  与 synthesis，Quartus 总耗时 7分38秒、0 errors，估算 ALM 79,546、DSP 21、
  peak virtual memory 3,794 MiB；boot RAM 明确为 8192×64 True Dual Port M20K 且
  使用同源 MIF。fitter/STA 仍等待共享 `local` 上的 no-FP 三场景 SoC smoke，未生成
  SOF、未改变板卡。

## 历史权威快照（2026-09-10）

- **最终 physical 候选**：B25 candidate
  `d2f5cfdd2791945a82d47300b94debd0e40a96d6` 已由 T-20260909-013 在全新
  GamePC probe 上完成 synthesis → fitter → STA。SDC 为 14,384 bytes、SHA-256
  `7ab96f705ffc81d1046d23ce704c0c55f0a8df7c1bd4c137b2ae13fe421eebd5`；没有复用
  T-002 fitted DB；T-013 本身没有运行 assembler，后续 T-043 只读消费其冻结输入。
- **fresh timing/resource**：synthesis `06:20:46`、fitter `00:26:01`、STA
  `00:00:39`，均 0 errors；ALM 164,852/427,200（39%）、RAM 121（4%）、DSP
  186（12%）。`sys_clk_25` setup/hold/recovery/removal 为
  `+8.085/+0.019/+13.608/+0.181 ns`，Fmax `31.33 MHz`；全局 setup/hold/
  recovery/removal/min-pulse 为 `+0.320/+0.000/+0.656/+0.174/+0.120 ns`，0
  violation。DDR 五项与四 corner metastability 通过。
- **CDC/waiver**：六组 FIFO payload 的 24 个 setup/hold report 全部无路径；四
  corner × 五组 data-delay 共 20/20 通过，最差 `+1.319 ns`。fresh fitter 的 raw
  UCP/reset 数量从 T-011 的 `63/627` 漂移为 `61/626`，但 T-20260910-001 v2
  invariant 从原始报告证明两者完整规范化集合完全相同：TDI/TMS/TDO
  `25/35/4`、reset 624（family `606/4/13/1`）。合并 SHA 上 actual T-011/T-013
  export+check 均 PASS，fixture 2/2 正例与 27/27 负例通过；旧 v1 合同保持字节不变。
- **证据状态**：T-20260910-002 已区分 candidate/tree、owner evidence 与 integration
  commit，并复核 25 个 artifact 引用为 0 mismatch。T-013 现已正式 `done`；此前
  UCP cardinality blocker 已解除，测量数值没有被改写。
- **SOF 已封存**：T-20260907-043 在 T-013 的独立 clone 上只运行一次 Quartus
  assembler；工具报告 Successful、0 errors/0 warnings，源工程 539 项前后 diff 0，
  fitted `final/partitioned/synthesized` 数据库变化 0。唯一 SOF 为 36,842,093 bytes、
  SHA-256 `032c82dd88f99c5e19b845d199e6ef6d205e4be6b62c8171a2f9370a0032920b`，
  Quartus checksum `0x33878BC3`；POF/JIC/RBF/JBC/SVF/JAM 均未生成。
- **当时下一步/权限门**：编译并行化 A/B（T-20260909-014）延后，不抢占首板主线。
  T-043 已完成；当时停在 T-044 的 FPGA 易失配置独立权限门。该权限随后于
  2026-09-19 获得并执行，结果以上方 2026-09-19 快照为准。

## 当前权威快照（2026-09-07）

- **R21物理基线**：功能候选`80b1f813de47a1223dd135117650419a0b6c05fc`，
  accepted physical baseline `689959472faf59844fb486834fad27f8fedb2ca6`；
  `Fmax=48.57 MHz`，50 MHz setup WNS/TNS/endpoints为
  `-0.588 ns/-67.238 ns/550`，hold/recovery/removal/min-pulse均非负。
- **B25本地候选**：T-20260907-037 source
  `259188ac33322a74a8911c9c37edc6302f6d6169`。真实25 MHz时钟、64 KiB初始化
  M20K/BRAM monitor、轮询JTAG-UART、MMU-off uncached DDR、AXI line fill和
  EMIF timeout/reset/late-response韧性已合入；父线AXI/EMIF SV、Cocotb 7/7、
  SoC CAL-OK/WAIT/FAIL smoke、MIF/manifest/checker和平台/SoC lint全绿。
- **当前关键路径**：T-037本地L0-L2完成，T-042已具备fresh 25 MHz
  synthesis/fitter/STA派发条件；物理输入必须显式携带ignored `boot.mif`并纳入
  generated manifest。Gate D可与远端physical并行，但必须在板级配置前完成。
- **板级权限**：用户只授权依赖全绿后使用指定`nios2-terminal`连接
  JTAG-MPSSE `device=1 instance=0`做console收发。尚未授权T-043 assembler/SOF、
  `quartus_pgm`易失配置、reset/power或任何JIC/EPCQ/Flash写擦。
- **参考基线**：本机和GamePC的`a10-linux-riscv`均为clean `b2ffcc9`；LCVEX
  `source.lock`仍固定旧平台`3db828e`，只吸收平台/流程经验，不整体移植RV32、
  OpenSBI、Sv32、PLIC/CLINT、地址图或软件镜像。

## 当前权威快照（2026-09-02）

- **集成线/当前候选**：`feature/p7-final` @ `7389791`（F1a 矩阵接受提交）。主 Agent 后续新增了 `T-20260902-003` 子代理冒烟测试与 `T-20260902-001/002` 重新派单提交，RTL 功能未变。
- **F1a 性能线**：冻结 `f0edcd2` 上完整 196 行矩阵全绿（196/196 pass、98/98 strict 等价、98/98 性能 guard、FIFO 无溢出），相对 F0 总周期 **-14.1%**；F1a 默认仍关闭（`FETCH_FIFO_ENABLE=0`），T-012/T-013 待派发。
- **最近完整本地 Gate D**：`T-20260901-008`，在 `4cf2137` 上 151 项全绿；当前 HEAD 尚未在同一 SHA 重跑完整 Gate D（只新增 F1a 证据与接受提交）。
- **FPGA 线**：B0–B5 本地完成；G5 L1D/L2 M20K wrapper standalone synthesis PASS；真实 SoC synthesis/fit 仍待重跑。`T-20260902-001`（资源探针）与 `T-20260902-002`（JTAG SOP）已重新派发。
- **文档同步**：本文件与 `ROADMAP.md`、`TASKS.md` 正在补齐 9 月 1 日 F1a 批次及 9 月 2 日派单状态。

## 当前权威快照（2026-08-30）

- **集成线/当前候选**：`feature/p7-final` @ `1d5a356`（本状态同步的基线 HEAD）。
  最近一次完整本地回归的功能 RTL 基线为 `a110ba3`；相对该 SHA，当前 HEAD 只
  新增 AUD-12/AUD-13 证据、QEMU patch 对账/修复、文档与状态登记，**没有 RTL
  功能改动**。
- **本地 Gate D 全绿（T-20260830-022）**：在 `a110ba3` 上 `make test` PASS、
  `bash sim/difftest/run_gate_d.sh --parallel` 13/13 PASS、`CORE_COUNT=1`/
  `l2_cluster` lint PASS；可选 C3 四核 `cluster4_multi` 与 C4 8 核
  `cluster8` 模块级 TB 也 PASS。evidence：
  [`T-20260830-022.json`](tasks/evidence/T-20260830-022.json)。
  该结果不替代可信 CI、Gate F-BOARD、Linux/nightly 或 `main` 晋级。
- **C3 四核完成**：C3 four-core 实现已合入 `feature/p7-final`
  （merge `fccb674`），定向与完整四核 message-passing/sysctrl/timer 矩阵通过；
  已知边界为 GIC/PSCI-lite、尚无 TLB shootdown / 多核 checkpoint / Linux SMP。
- **C4 8/16/32 规模数据完成**：T-20260830-018（8 核）与 T-20260830-019
  （16/32 核）已合入。8 核 default-FP cluster lint/elab 与 synthetic smoke
  通过；16/32 核 no-FP cluster、目录模块和参数化 synthetic smoke 通过；
  16 核 default-FP 完整 lint/elab 未在窗口内完成，32 核未测。**这是规模/趋势
  测量，不是 8/16/32 完整功能、Linux SMP 或架构合规。**
- **性能线 14 workload 全量快照（P-SNAPSHOT）**：T-20260830-021 已合入，
  重建 runner 后 14/14 workload 全部 PASS 并归档 JSON；摘要见
  [`docs/PERFORMANCE_SNAPSHOT.md`](PERFORMANCE_SNAPSHOT.md)。仅为 Verilator
  仿真性能代理，非 A10/Fmax/架构签核。
- **AUD-12 checkpoint v4 通过**：`LCVXSYS4`/`CONTEXTIDR_EL1` 的 QEMU
  `-incoming` + DUT restore 联合恢复通过，非零 CONTEXTIDR 值恢复后继续锁步
  一致；相关 smoke 全绿。证据：
  [`T-20260829-117.json`](tasks/evidence/T-20260829-117.json)。
- **AUD-13 fresh replay 修复通过（13-patch canonical）**：T-20260830-023
  重新对账并生成 13-patch canonical（`b6b820...`），干净 apply 13/13、幂等、
  QEMU/plugin 构建 PASS、trace+lockstep smoke PASS；`EXT-02-001` 已标记
  resolved。证据：
  [`T-20260830-023.json`](tasks/evidence/T-20260830-023.json)。
- **FPGA 线**：F2 有突破（T-20260830-008：重型模块 standalone 峰值均 <16GB，
  并验证 blackbox synth → QDB import → fitter-only 可跳过子分区重综合）；
  F3/F4 仍 blocked（T-20260830-016/020：真实 A10/SoC 顶层受 Qsys/`alt_sld_fab`
  和顶层 glue elaboration 内存限制，未产出 fit/STA/SOF）。**T-067 未解除**，
  不宣称 A10 full flow、DDR、板级或 Gate F-BOARD。
- **GitHub CI 已禁用自动触发**：T-20260830-007 已合入，`.github/workflows/ci.yml`
  仅保留手动 `workflow_dispatch`；本地 CI 脚本和 `run_gate_d.sh` 不受影响。
- **当前阶段门总结**：P5/M3/P6 本地功能、Gate D（`a110ba3`）、C3/C4 规模数据、
  性能快照、AUD-12/13 均已形成本地证据；尚未满足 Gate F-MEM/F-BOARD/F-RELEASE，
  也未进行可信 CI、完整板级、Linux SMP/多核差分或 `main` 晋级。

- **dsh 多 Agent 试点与派发适配（2026-08-28T22:50）**：T-070 试点完成并归档
  （实现 `e40f119`、定稿 `eb9d507`、归档 `9688d44`），验证 codex 时代的
  多 Agent 流程在 dsh（DeepSeek harness）下闭环可走通：任务登记/sibling
  worktree/默认通道派单（省略 model）/带时间戳报告/合并 SHA 复跑/evidence
  定稿。同步把 `docs/tasks/TEMPLATE.json` 模型路由字段对齐现行规则（删除
  `disabled_profiles`）。新增 ADR-20260828-004 固化 dsh 执行口径：派单一律
  省略模型（Terra/Sol 职责由集成者当前会话承担）、subagent 完成通知取代
  sleep 轮询（事件驱动）、报告结构化双写、evidence 两提交自引用 head_sha、
  agent/job 双 id 体系、主 Agent 用 DCP compress 主动压缩上下文（每逻辑节点
  一次，摘要写完整事实）。`MULTI_AGENT_WORKFLOW.md` §2.1/§2.2/§10/§11 已按
  ADR-004 修订。
- **feature/p7-final 跨线整合（2026-08-28T19:29）**：P7 线（含 P7-5 FP16）与
  FPGA 线（AXI4/写回 L1/L2/单核一致性/SoC/Boot，merge base `c76cc28d`）合并为
  `feature/p7-final`（merge SHA `78771bf`）。共享 RTL 以 P7 线为主，带 FPGA 独有
  Cache/AXI4/SoC RTL；post-merge 验证 `make compile`(44 modules)、`make test`
  (P0)、P7-5 FP16 lockstep 102 条全绿。同一 SHA 完整 Gate D 全绿（M2/R1 40 项并行、
  Gate C 7 组、P5a 3 组、P4b、随机 3×100k、覆盖记账、baremetal-C 200），evidence
  `docs/tasks/evidence/T-20260828-p7-final-gateD.json`。这构成 Gate-F ISA 与
  F-MEM 的组合候选；远端 full flow（T-067）、F-BOARD、CI/main 晋级、Linux/nightly 仍在途。
## 历史权威快照（2026-08-27，供追溯）

- 集成线：`feature/p7-fp-neon`（从 P6 收尾提交 `01ed8eb` 分出）；最新冻结
  P6 功能候选仍为 `b2568a5`，
  精确文档版本始终以“包含本快照的提交 SHA”为准。
- 阶段：P5/Gate D 与 M3 已完成；P6 本地退出条件及阶段回顾前置项均已
  关闭。P7 架构与验证协议已经 Terra 初稿、Sol 深度优化和用户人工审核；
  P7-0 状态/协议/checkpoint 切片已完成并归档（T-051，集成 SHA `d453e29`）；具体
  P7-1 选定 FP32/FP64 标量算术与基础访存已在集成 SHA `f937352` 通过并进入归档；
  P7-2（NEON 128 位整数/单 Q）已在合并 SHA `072cf12` 通过 L0-L2 并归档；P7-3 选定 2S/4S/2D NEON FP 已在合并 SHA `9c6adee` 通过完整矩阵 48/48 并归档，Gate-F 仍按项目级阶段门验收。
- 并行路线：P7继续使用`feature/p7-fp-neon`；Catapult A10上板使能使用独立
  `feature/fpga-catapult-a10`，按B0-Platform至B5-SoC/Boot实现标准AXI4、写回
  Cache、单核一致性和板级启动。两线只在最终`feature/p7-final`冻结候选汇合。
- 最新里程碑：冻结候选 `b2568a5` 的纯标量 no-FP/NEON Linux lite 6.6
  fresh-root 连续锁步 35M 到用户态 `/init ready` 且稳定；同候选 main 从
  finalized parent 连续 5M 通过，证据见
  [T-20260826-044](tasks/evidence/T-20260826-044.json)。
- Gate 状态：冻结候选 `b2568a5` 已在本地同时通过 T-043 Gate D 与 T-044
  Gate E。按用户当前策略不等待 CI，因此这是 **P6/Gate E 本地功能验收完成**；
  T-046 已确认该本地结论；`main` 晋级与可信 CI 仍按 Git 规则后置。
  P7 冻结候选 `d3dfe7a` 已在 detached gate worktree 通过 T-061 完整 Gate D：
  M2/R1、delay2-cache、P5a hardening、Gate C、P5a MMU、P4b、随机 3×100k、
  coverage 60/60 和 baremetal-C 200 全绿；这不等于 Gate-F-BOARD、CI 晋级或
  Linux/nightly 完成。
  P7-5 合入后的新冻结候选 `e36b7b1`（merge T-069）已在 detached gate
  worktree 通过完整 Gate D（2026-08-28T17:56，`bash sim/difftest/run_gate_d.sh
  --parallel`）：make test、coverage、M2-4b 40 项并行、26 项并行锁步、Gate C
  7 组、P5a 3 组、P4b、随机 3×100k、指令覆盖记账、baremetal-C 200 全绿
  （evidence `docs/tasks/evidence/T-20260828-069-gateD.json`）；作为更新后的
  Gate-F ISA candidate，仍不等于 Gate-F-BOARD/CI/main 晋级/Linux/nightly。
- 活动任务：T-047、T-048 已完成并归档；T-049 冻结的 P7 V/FP 状态、commit、
  QEMU 锁步、checkpoint 与测试协议已于 2026-08-27 通过用户人工审核并归档。
  T-050已把Catapult平台、标准AXI4、单核一致性、未来多核预留、双轨DAG和
  Gate F-ISA/F-MEM/F-BOARD/F-RELEASE落实为文档与ADR。当前调度轮已登记并派发
  T-20260827-051（P7-0）和T-20260827-052（B0-Platform），两者共同绑定
  `c76cc28d`、写集互斥，P7-0 已归档为 `done`（集成 SHA `d453e29f5577`；QEMU 0012
  clean replay/build、plugin、filelist/core/SoC FP state wiring、system-commit
  backpressure、fail-fp 负路径、A76 required lockstep、13 列 LCVXFP01 root/resume
  和 max/legacy guard 均有证据；真实 P7-1 以外的 FP/NEON arithmetic/memory 和 Gate D/F 仍待完成）；T-20260827-058 的受限 FP32/FP64 标量算术与基础访存已在 `f937352` 完成集成复测并归档，T-20260827-059 的 P7-2 NEON 整数/单 Q 访存已在 `072cf12` 完成集成复测并归档，T-20260827-060 的 P7-3 NEON 浮点已在 `9c6adee` 完成集成复测并归档，保持写集与 B 线隔离。B0 当前为 `blocked`（离线
  manifest/checker 已在 merge SHA `0292cbb8b85a` 通过；T-057 于
  `2026-08-27T08:25:49+08:00` 确认 Windows Quartus Pro 21.4 Build 67 可用，但
  `D:\\Projects\\fpga-altra\\lcvex` 缺失，exact Quartus/Qsys regenerate 尚未执行）；
  各自 direct sibling worktree 已创建。
  模型路由自 2026-08-28 起更新：派单省略 `model` 即默认 `deepseek-v4-flash[max]`
  （原默认 `gpt-5.6-luna[max]`），已同步至 `docs/MULTI_AGENT_WORKFLOW.md`。
  用户确认可用命令行创建 Quartus 工程，已登记 T-20260828-063：由独立 subagent
  在 Windows `D:\Projects\fpga-altra\lcvex` 创建/恢复可重生成工程并执行
  Qsys/IP regenerate（允许在线搜索官方 CLI 资料），用于解除 T-052/T-057 的
  目标工程缺失阻塞；写集仅限该远端目录与 handoff/evidence，不触碰 B0 平台包。
  T-20260828-063 已于集成 SHA `d0f6e82` 归档为 `done`：远程
  `D:\Projects\fpga-altra\lcvex` 已从零创建，15 项 platform payload 哈希与仓库
  `SHA256SUMS` 完全一致；`qsys-generate` 与 `quartus_ipgenerate` 再生成 exit 0，
  smoke 工程（`lcvex_smoke_top` 包装 Qsys/Avalon Tie-off）`quartus_sh --flow
  compile` 全流程通过：synthesis/fit/STA/assembler 0 errors，SOF 36.8 MB，
  EMIF 内部 setup/hold 全正 slack，clk_266 Fmax 476.64 MHz。已知缺口：
  仓库 B0 包缺 `flash/sfl/sfl_sys.qsys`（完整 SFL 再生成输入）；主工程尚无
  LCVEX 顶层 wrapper（`catapult_a10` 合成到 synthesis 阶段因无顶层退出码 3）。
  基于此，T-052/T-057 已于 `2026-08-28T01:12:00+08:00` 解除阻塞（blocked →
  ready），下一步补 SFL 输入/工程顶层后执行 exact regenerate 与真实 full flow。
  T-20260827-062（B0 可重生成工程骨架）与 T-20260827-052（B0 平台输入收编）
  已于集成 SHA `e5313e7` 归档为 `done`：新增 `lcvex_catapult_a10_top` 顶层
  shell、reset/calibration gate、`skeleton_manifest.json`、`check_skeleton.py`
  与 `lint_platform.sh`，QSF/SDC 顶层锚点已接线，离线 L0/L1 在合并 SHA 全绿
  （check_platform 15/15、check_skeleton 5/5、Verilator lint pass、SHA256
  15/15）。当前 B 线活跃任务为空；下一步为补录 SFL Qsys 输入、以真实顶层
  wrapper 在远端跑 `quartus_sh --flow compile catapult_a10` full flow/STA
  （Gate F-BOARD 前置），并登记 B5-SoC/Boot。
  T-20260828-064 已于集成 SHA `e389c53` 归档为 `done`：在 T-063 创建的远端
  工程上用真实顶层 `lcvex_catapult_a10_top` 跑通 full compile + signoff STA
  （`quartus_sh --flow compile catapult_a10` exit 0，0 errors/68 warnings；
  STA 最差 setup +0.220 ns、hold +0.017 ns；Fmax sys_clk_50 213.49 MHz、
  clk_y3 499.25 MHz、EMIF core user 283.29 MHz；SOF SHA256
  `04130f9d…`）。SFL/EPCQ 输入已补齐为 39 文件完整生成目录（来源锁定
  `a10-linux-riscv @ 3db828e hw/ip/sfl`，无 RISC-V/VexRiscv 越界），平台
  payload 从 15 扩展到 50 文件并在合并 SHA 离线 L0 全绿。已知边界：DDR
  March/板级校准/上板测试仍属 Gate F-BOARD；B5-SoC/Boot 待登记。
  T-20260828-066（P7-4 FMA 与 FP/整数转换）已于集成 SHA `4b253ad` 归档为
  `done`：实现标量 S/D FMADD/FMSUB/FNMADD/FNMSUB、SCVTF/UCVTF/FCVTZS/
  FCVTZU（含定点子集）、FCVT S↔D，以及 NEON 2S/4S/2D FMLA/FMLS 与向量
  转换；raw IEEE/FPSR/FPEN/backpressure 语义沿用 P7 协议。集成复跑全绿：
  make compile/test、P7-4 SV raw + Cocotb 5/5、P7-1/2/3 SV+Cocotb 回归、
  A76 required lockstep 94/54/27/142、P6 scalar 40/40、LCVXFP01 checkpoint
  差分（5 entries/40 artifacts）。FP16、sqrt、estimate、min/max、round、
  完整 FP exception-enable 与 SVE 仍后置；Gate F-ISA 冻结 SHA 完整 Gate D
  待集成者串行复跑。
  T-20260828-065（B5-SoC/Boot）实现与本地验证已完成并合入 FPGA 线
  （merge SHA `23218fb`）：新增 `lcvex_catapult_soc_top/axi/coh/pkg`、
  `lcvex_bram_boot` 与 BRAM 启动代码（`boot.S`/`ddr.S`），地址映射
  BRAM 0x0 / DDR 0x40000000 / JTAG-UART 0x09000000 / EPCQ CSR 0x09001000 /
  PLAT_STATUS 0x09003000；本地 L0/L1 在合并 SHA 全绿（soc smoke positive +
  cal-blocked、lint、platform 50/50、skeleton 6/6、sha256sum）。任务当前
  `blocked`：远端 `quartus_sh --flow compile catapult_a10` 在 b5k 合成阶段因
  Session 0 残留两个 `quartus_syn`（约 44 GB）无法终止、Free 内存仅 0.5 GB
  而中止，未取得 fit/STA/SOF；需要宿主清理/重启后重跑 b5l（已登记
  T-20260828-067）。DDR March、Linux/上板验证仍属 Gate F-BOARD。
  P7-0 的 Terra/Sol 一次性审核均允许受限 RTL/SV/Cocotb，B0 的 Sol 审核允许
  manifest 工作；B1-AXI4 已完成一次性 Sol 审核并归档为 `done`，clean FPGA 线
  owner L0/L1 已交付，按不与现有写集
  重叠原则实现，不依赖 Quartus/B0 regenerate。B2-EMIF 已完成一次性 Sol GO，owner 以 3294s 实际耗时完成交付；clean FPGA 线 L0/L1 已通过并归档为 `done`，B3 Cache/L2 接线后置，基于 clean FPGA 线且不写 B0 目录。B3-L2-WB 已完成一次性 Sol GO，continuation owner 以 972s 实际耗时完成交付；clean FPGA 线 L0/L1 已通过并归档为 `done`，B4/L1 接线后置。B4-L1-Coherence 首轮 Sol 在 `2026-08-27T06:45:23+08:00` 发现 L2→L1 probe/drain 缺口，集成者提交 `46d391d` 修订契约后，Sol 于 `2026-08-27T06:53:55+08:00` 以 16s 确认 GO；owner 以 2612s 实际耗时完成模块级交付，已在 clean FPGA 线 merge SHA `52144b450182` 通过 L0-L1 并归档为 `done`。该结果仅覆盖模块级 D-L1/L2 probe、maintenance、checkpoint 和 B3 回归；真实 core/I-L1/AXI4/SoC 接线、QEMU、Gate F-MEM、Quartus 和板测后置。协议联调、QEMU/Quartus 和重型验证仍由集成者串行安排；审核仅在写集、契约或证据实质变化时重开。“不等待CI”仍不授权将当前提交晋级`main`。
- 为利用用户提供的 Windows 工具环境，T-20260827-057 已于 `2026-08-27T08:25:49+08:00` 收到 Turing 的 861s 报告：SSH/pwsh 与 Quartus Pro 21.4 Build 67 可用；远端 Miniforge base 已安装 Ninja 1.13.2（`conda-forge`），但 `D:\\Projects\\fpga-altra\\lcvex` 不存在，因此任务仍为可恢复的 `blocked`，尚未进入 synthesis/fit/STA；该任务只写环境证据，不修改 Linux RTL、QEMU 或其他 FPGA 参考目录。
- T-20260826-002 已在合并提交 `5e8e828` 完成并于 `d60b9d4` 归档：trace
  manifest 绑定 Image/DTB/QEMU/plugin 输入与 artifact SHA256，切片采用全局
  半开 seq、parent 内容摘要和严格 gzip 校验；`make trace-manifest-smoke`
  与 checkpoint L0–L2 复跑通过。该基础设施完成不等于 Gate E 或 Linux 长跑验收。
- T-20260826-003 已在合并提交 `4b1d7b6` 完成并于本轮归档：补齐
  `LDCLRP/LDSETP/SWPP` 三个 LSE128 单核事务，加入 16B 对齐/范围与双半翻译
  预检、base/cache 定向锁步和 registry 入口；300 条窗口及既有 LSE/WFI 回归
  通过。该批次不宣称完整 LSE128、多核一致性或 Gate E。
- 本地资源默认仍按 50% 预算排队；如重型阶段有实测必要，集成者可在 evidence 中
  记录并临时提升到 75%，CI 上限同为 75%；本次 T-002 未使用提升额度。
- T-20260826-004 已完成并归档：当前 QEMU SHA 绑定的 lite checkpoint 从
  seq=6,999,999 恢复 500,000 条通过；旧 main-scalar seq=7,999,999 链在
  CPU vmstate post-load 阶段 0 条失败，未绕过校验。使用同一当前 QEMU/CPU
  配置新建 20,000 条 main bootstrap 链并从 seq=19,999 恢复 10,000 + 500,000
  条通过；后续主线长窗必须从该 bootstrap 扩展，不能把旧链失败算作 RTL 结果。Gate E
  仍未完成。续跑脚本生成的新局部 checkpoint 尚未自动带 parent/global manifest，
  已转为下一项基础设施修复；证据见 [T-20260826-004](tasks/evidence/T-20260826-004.json)。
- T-20260826-005 已完成并归档：resume/step checkpoint 在 strict lifecycle 下
  自动绑定输入、QEMU 上下文和 parent manifest，保留 local seq 并记录
  `global_seq_offset`；pending/篡改/冲突链均拒绝，成功 fixture 已 finalize
  并回读。旧 init-only 链不再作为新 resume parent；重新建立 strict root 链
  后才能继续 Linux 深段。
- T-20260826-006 已完成并归档：重新建立的 strict root lite/main 链均已通过 10k；
  lite 使用当前 QEMU 实际 bootloader 配置 `BOOT_DTB=0x44000000`、
  `BOOT_ENTRY=0x40200000`（无 INITRD），main 使用 `0x44000000/0x40080000`。
  两线各递归通过 500k+500k+500k+5M+5M，global 保存点到 11,509,999，child manifest
  parent/hash/offset 完整。仍未宣称 Gate E，后续深段由 T-007 取证。
- T-20260826-007 已完成并归档：从 T-006 global=11,509,999 strict child
  继续，lite/main 各 5,000,000 条通过，global 保存点达到 16,509,999；
  plugin/coordinator/filelist/QEMU/source SHA、parent/TSV/artifact 证据已记录。
  这仍是 Gate E 候选窗口，不是阶段门通过。
- T-20260826-020 已完成并归档：在已验收 `1b92a22` 基线上，lite/main 从同一
  T-007 finalized parent 各连续 5,000,000 条严格锁步通过，global 保存点达到
  21,509,999；两条 child manifest、parent hash、TSV/artifact/restore 均可审计。
  该窗口仍不直接宣称 Gate E，且 main 线保留 legacy `/tmp/Image-t80000` 只读输入。
- T-20260826-019 已完成并归档并集成到 `ac533b2`：补齐 ARMv8.2 `DC CVAP`、
  `AT S1E0R/W`、`AT S1E1RP/WP`，收紧 IC/DC/TLBI tuple；MMU 实现 PAN-aware
  权限和 AT regime，`PAR_EL1` 延迟至提交更新。base/cache、MMU PAN、EL0 UCI
  trap、P5a/TLBI 回归均通过；剩余 CVADP/OS/RV/range/EL2/EL3 maintenance 留在
  后续范围。
- T-20260826-024 已在包含 T-023 runner 修复的新 candidate `b7c91de` 上完成
  Gate D 全量回归：M2/R1、随机延迟、P5a-Hardening、Gate C/P5a/P4b、随机
  seed 1–3、覆盖率和 baremetal-C 全部通过，证据见
  [T-20260826-024](tasks/evidence/T-20260826-024.json)。这是本地 Gate D 通过，
  仍需可信 CI/QEMU patch replay 和同 SHA 的 Linux Gate E 验收。
- T-20260826-027 已完成 Gate D candidate 的 Linux continuation：使用 T-007
  parent 原始 plugin、独立 QEMU/Verilator 物理核（2/3、4/5）和全新 child 链，
  lite/main 各 5M 严格锁步并 finalized 到 global `21,509,999`，证据见
  [T-20260826-027](tasks/evidence/T-20260826-027.json)。这构成 Gate E candidate
  证据，但尚未完成 Gate E 的 early-boot/EL0/CI 全部判据。
- T-20260826-030 已在包含 CI/patch-replay 修复的最新 candidate SHA 上重复完成
  lite/main 各 5M；child finalized 到 global `21,509,999`，lite QEMU log 明确
  记录 `/init` 进入和 `LCVEX linux-lite /init ready`。当前仍等待 CI 最终结果，
  因此 Gate E 尚未宣称通过。
- T-20260826-033 已关闭 Linux 深段首次暴露的 `PSTATE.ALLINT` bit13 缺口：
  `MRS SPSR_EL1` 差异根因定位到 QEMU FEAT_NMI 可见状态，RTL 已补
  `MSR/MRS ALLINT`、异常入口/ERET、`SCTLR.NMI` 条件 IRQ 屏蔽和 checkpoint
  sideband；base/cache 定向与 T-031 失败点后 9M replay 全绿。
- T-20260826-034 已在包含 T-033 的当前 candidate SHA 上从 fresh root 连续
  锁步 `35,000,000` 条，strict root manifest finalized 到 seq `34,999,999`，
  QEMU 明确记录 `/init` marker，marker 后窗口无 mismatch；证据见
  [T-20260826-034](tasks/evidence/T-20260826-034.json)。
- T-20260826-035 修复 `run_qemu.py` 超时 SIGKILL 导致 gzip trace 缺失的 CI
  根因；本地 `make difftest-qemu` 全绿。旧 CI run `32935884451` 已取消，
  历史 run `32949011243` 不作为当前冻结候选证据；按用户策略本阶段不等待 CI。
- T-20260826-042 已修复 Linux main 在 local `seq=2,139,121` 暴露的
  `SCTLR_EL1` PAuth EnIA/EnIB/EnDA/EnDB 写掩码缺口：正常 MSR 与 checkpoint
  restore 共用 `0x0000000037ffdfff`，base/cache 定向、`make test`、checkpoint
  smoke 和 T-039 parent 后 2.5M 首错重放全绿。
- T-20260826-043 已在冻结候选 `b2568a5` 完整重跑本地 Gate D。首轮仅有
  planner 资源排队超时；调整不重叠 cpuset 后缓存复跑退出 0，M2/R1 40/40、
  delay2 32、hardening 26、随机 seed 1–3 ×100k、coverage、baremetal-C 和
  50/50 并行结果全部通过，无孤儿进程。
- T-20260826-044 已在同一 `b2568a5` 完成 Gate E：lite no-FP fresh-root
  35M 到 `/init ready` 并稳定，70 checkpoints/490 artifacts；main 从 T-039
  finalized parent 连续 5M，跨过旧首错并生成 10 checkpoints/70 artifacts。
  两条有效 manifest 均 finalized 且真实回读通过。另发现 `finalize_manifest`
  在 parent plugin 校验失败前写完成态的原子性缺陷，已登记 T-045；无效链明确
  `do-not-reuse`，不影响两条验收链。
- T-20260826-045 已修复上述 finalize 原子性缺陷：完成态先在内存中执行
  输入、artifact、TSV、parent/provenance 全量校验，成功后才原子替换
  `manifest.json`。parent/plugin mismatch 永久 fixture 证明失败后原始字节与
  pending 状态不变；manifest/trace、DUT、Timer、GIC、sys v2/v3、MMIO
  checkpoint smoke 在集成 SHA 全部通过。
- T-20260826-047 已加入 SCTLR PAuth 脏 sidecar 联合恢复回归：seq=2 精确
  捕获 MSR 后/MRS 前边界，只向 DUT 副本注入 bit31/30/27/13，QEMU 原
  vmstate/RAM/sys 与 finalized manifest 保持不变；恢复后 MRS 与后续 MOVZ、
  既有 SYS v2/v3 smoke 在集成 SHA 全部通过。
- T-20260826-048 已收敛 P6 标量事实基线：P2/P3/P5 不再显示为进行中，
  Linux 动态证据更新为 lite fresh-root 35M 且不冒充全族覆盖；coverage
  清楚区分 `expected_hit=60/60` 与 `observed_families=61`，EXPECT 集和
  退出码未改变。
- T-20260826-008 评审结论：Gate E 仍未具备充分验收证据。冻结 candidate
  必须补同一 SHA 的 Gate D detached 全量、可信 CI/QEMU patch replay、明确
  early-boot 判据，以及（若纳入 P6 退出条件）EL0 `/init` 稳定用户态判据。
  P7 只能在该 candidate 冻结后按 FPCR/FPSR → 标量 FP → NEON 整数 → 选定
  NEON 浮点的顺序进入。

本文其余带日期的章节是按时间追加的评估和实施历史，可能保留当时已失效的阶段
判断；它们用于追溯，不覆盖本节、`ROADMAP.md` 当前阶段表和任务注册表。

## 历史评估基线（2026-08-23）

- 评估日期：2026-08-23（Asia/Shanghai）
- 评估基线：`main`，提交 `b1a7302`
- 评估范围：RTL、SystemVerilog/Cocotb/C++ 验证、QEMU 插件与 fork patch、
  构建/CI、项目文档和最近提交记录
- 工作区：评估开始时干净；QEMU fork 的工作区改动可由仓库内唯一 patch
  反向校验，固定基线为 QEMU 11.1.0 `84f0721`

## 历史评估摘要（2026-08-23）

LCVEX 已经形成一个**可运行、可与 QEMU 严格锁步的 AArch64 标量原型**。
项目最有价值的资产是明确的 commit packet、批量 trace 与 socket 锁步两条
差分路径，以及能保存最近提交状态的失败诊断。现有支持子集在已覆盖场景中
表现稳定，本次复跑的基础、hazard、随机、异常和 MMU 用例均通过。

但当前工程成熟度不应描述为“P0～P4 已完整收敛、可以直接开发 Cache”。更
准确的定位是：

> **P3 标量子集和 P4 最小异常路径已形成可靠原型，P5a 数据/取指翻译是通过
> 少量定向锁步的实验实现；在开始 P5b 前必须先关闭架构语义、提交协议和内存
> 接口上的高风险缺口。**

主要原因有三点：

1. 已发现 MMU AP 权限表错误、AF 未检查、`MRS/MSR NZCV` 位域错误，以及
   若干解码掩码/立即数语义缺口；当前测试没有覆盖这些组合。
2. WB 通过 `memwb_valid` 的 0→1 边沿产生提交，依赖现有单端口 SRAM 带来的
   自然气泡；Cache hit 允许连续退休后可能漏提交。内存接口也没有请求/响应
   握手，Store 在 EX/MEM 发出而不是在明确的 commit fire 边界完成。
3. CI 只跑 lint、一个 SV smoke 和 ALU Cocotb；异常、MMU、随机差分、独立
   Cocotb core test、协议负路径和断言均未进入 CI。文档中的 Gate A～C 因此
   代表“现有测试集合通过”，不能等同于对应架构范围已经完整。

近期方向应从“马上增加 Cache”调整为“先建立 P5a-Hardening 阶段门，再开发
P5b”。这不是推翻当前实现，而是保护已有差分基础设施，使后续 Cache、Linux
和 FPGA 不再建立在隐含的 1-cycle SRAM 时序假设上。

## 历史评估实现盘点（2026-08-23）

### 阶段状态

| 阶段 | 仓库记录 | 本次评估结论 |
| --- | --- | --- |
| P0 工具与骨架 | 已完成 | 可重复构建；版本检查有效，但环境未完全锁定，CI 覆盖不足 |
| P1 QEMU difftest | 已完成 | 批量 trace、实时锁步、精确异常 step hook 均已落地，是当前最成熟部分 |
| P2 标量语义 | Gate A 通过 | 支持子集稳定并随 M3 持续扩展：位掩码/位域、LDP/STP、寄存器偏移寻址、乘加族、CSEL/BFM/LDR literal、exclusive 已完成（见 M3 进展与 ISA_SCOPE.md） |
| P3 五级顺序流水线 | Gate B 通过 | forwarding、load-use、flush、乘除已验证；提交/内存流控尚未为连续退休和可变延迟做好准备 |
| P4 EL0/EL1 与同步异常 | Gate C 通过 | 7 组最小锁步通过；R1 已补完整 ESR_EL1/FAR_EL1 syndrome 比较（exc_esr/exc_far）与空流水线取指 fault 合并 |
| P5a MMU/TLB | M0 定向测试完成 | 见下文“P5a-Hardening 进展”；权限/AF/UXN·PXN/TTBR gap/PA 越界已与 QEMU 锁步，TLB 一致性仍属 R1 |
| P5b Cache | 未开始 | 在 P5a-Hardening 和内存接口重构通过前不应开始 |
| P6～P10 | 未开始 | 路线顺序合理；P6 前需插入编译器/基础 ISA 与异常状态收敛阶段 |

因此，当前不能用一个简单百分比表达完成度。对外建议使用两条状态：

- **验证基础设施：P4/P5a 所需主路径已具备。**

## P5a-Hardening 进展（2026-08-23，M0 部分完成）

按 M0 顺序 1/2 完成 `verify/p5a-hardening-tests`（9 组定向测试）与
`feature/p5a-arch-fixes`（R0.1～R0.4 修复）。提交：`8a1a7b6`、
`fd7c987`（分支 `feature/p5a-arch-fixes`，基于 `verify/p5a-hardening-tests`
`4281fcb`）。修复内容与权威依据：

1. **NZCV 位域**：`MRS` 返回 `[31:28]`（`nzcv << 28`），`MSR` 取
   `wdata[31:28]`。QEMU probe 确认 `mrs x3,nzcv` 在 N=1 时 `x3=0x80000000`。
2. **MOV wide 保留 `opc=01`** -> UDEF（QEMU EC=0x00），不再当写零。
3. **ADD/SUB 立即数 `sh=1`** 实现 `LSL#12`；`bit23=1` 为 ADDG/SUBG（MTE）
   指令族，不在支持范围 -> UDEF。
4. **B.cond `cond=1111`** 与 QEMU `trans_B_cond` 一致按无条件分支处理。
5. **ADD/SUB 扩展寄存器形式（bit21=1）** 未支持 -> UDEF，不再误判为
   移位寄存器。
6. **MMU AP 矩阵**按 QEMU `simple_ap_to_rw_prot` 修正（4 AP × EL0/EL1 ×
   read/write 全组合锁步）；取指按 `get_S1prot`（EL0 需 EL0 读权限+UXN=0，
   EL1 需 PXN=0 且 AP!=01）。
7. **MMU AF**：L3 描述符 `AF=0`（HA=0）-> AccessFlag fault。
8. **TTBR gap / PA 越界**：非 canonical VA（T0SZ=16 下 `0x1000000000000`）
   与越出 SRAM 的 PA 均与 QEMU 锁步为 DABT（EC 0x25）。

### 回归结果（修复后，本机实跑）

- `run_p5a_hardening.sh`：9 组定向测试全绿（NZCV / MOV wide / ADD·SUB
  shift / B.cond 1111 / AP 矩阵 / AF / UXN·PXN / TTBR gap / PA 越界）。
- `make p4c`（7 组异常）、`make p5a`（3 组 MMU）、`make q6`、
  `make lockstep-q5`、`make lockstep`（P2 36 条）全过。
- `make difftest`（P1/P2 trace）、`make difftest-hazard` 全过。
- `make difftest-random`：固定 seed 1～5，各 100k 提交全过。
- `make test`（toolcheck/lint/SV smoke/Cocotb ALU+regfile）全过。

### M0 剩余项

- 系统寄存器 reset/读写掩码/EL 权限/提交时机表格文档（NZCV 已修，其余
  待 M1 前补齐）。
- “Gate A/P4/P5a 通过”文案改为精确支持矩阵：`ISA_SCOPE.md` 已更新，
  本文阶段表后续合并时按“可链接回归摘要”口径修订。
- 失败样本由 Cocotb 与独立 SV testbench 复现（当前经 lockstep 运行器
  可复现，双轨 reproducer 待 M1/CI 阶段补齐）。

**M0 未完成的已知边界**（保持 R1 状态）：TLBI/TLB 一致性、ESR_EL1/FAR_EL1
完整 syndrome、SCTLR/TCR/TTBR 写后失效、块描述符（1M/2M/…）、页边界跨页
访问（R0.7，随 M1 内存握手一并处理）。

## M1 进展（2026-08-23，M1-A 完成）

分支 `feature/commit-memory-handshake`，提交 `ef2f9b3`（核心）、
`3a277a6`（.gitignore）、`a2ba9e7`（Cocotb 双轨）。M1 工作项 1
（stage valid/ready 与显式 commit_fire）完成：

- WB 提交改为 `commit_fire = memwb_valid && !memwb_committed_r &&
  commit_ready`：条目首周期提交（与旧边沿同拍），连续 WB 有效时每
  周期一条；`commit_ready=0` 背压沿 WB->EX/MEM->ID/EX->IF/ID 传播，
  不丢不重，释放后排队条目连续提交。
- 顺带修复两个潜伏 bug：`mmu_req_issue` 当拍不同步冻结 ID/EX 与
  EX/MEM/MEM-WB（相邻两级同驻导致重复提交）；WB 保持的已提交幽灵
  条目参与前递会污染 load 数据（已用 `!memwb_committed_r` 关闭）。
- 验证：`sim-sv-backpressure`（SV）与 `test_commit_backpressure`
  （Cocotb）双轨独立复现背压不丢不重 + 释放后连续提交，并入
  `make test`。P0~P5a 全回归、random seed 1~3 × 100k 全绿。

## M1 完成（2026-08-23，M1-A/B/C 全部落地）

`feature/commit-memory-handshake` 后续提交：`14f8104`（内存接口组件）、
`043ba28`（核心/SoC 重接）、`c19f7f6`（SVA）。M1 五项工作全部完成：

1. **stage valid/ready + 显式 commit_fire**（M1-A）：WB 提交不再依赖
   单端口 SRAM 气泡；背压沿 WB->EX/MEM->ID/EX->IF/ID 传播；顺带修复
   `mmu_req_issue` 相邻两级同驻与幽灵条目前递两个潜伏 bug。
2. **request/response 内存协议**（M1-B）：`mem_req_t/mem_rsp_t` +
   `lcvex_mem_ram`（1-cycle SRAM 包装，strb 跨度 fault/背压保持）+
   `lcvex_mem_delay`（0/1/随机延迟注入）+ `lcvex_mem_arb`（PTW>数据>
   取指 + 响应路由）；核心 imem/dmem/ptw 三路全部改走该接口，load
   数据注册化（不再实时读端口）。
3. **Store 副作用与接受一一对应**：dmem 请求被仲裁器接受即产生一次
   写入，指令在 EX/MEM 停留到响应消费；响应 fault（如跨顶回绕 R0.7）
   提交为 DABT。
4. **仲裁抽离**：PTW/IF/MEM 仲裁从 core 主状态机移入 `lcvex_mem_arb`，
   SRAM/Cache/延迟注入器共享同一接口。
5. **SVA**（M1-C）：单提交源互斥、提交源->脉冲对应、无重复 Store、
   相邻两级不同驻、32 位写回零扩展；所有运行构建启用 `--assert`。

M1 退出条件实跑：0/1/随机（0..4 周期，LFSR）延迟与 commit_ready
背压下无丢失/重复提交（delay-1/delay-2 锁步全绿）；连续 WB valid
每周期一条（背压释放后实测连续提交）；Store+DABT/IABT 交叉场景在
p4c/p5a/hardening 覆盖；P0~P5a 全回归无变化。

**M2 前置遗留**（保持 R1）：TLBI/TLB 一致性、ESR_EL1/FAR_EL1 完整
syndrome、SCTLR/TCR/TTBR 写后失效、块描述符、真实负载下的 I-L1/D-L1。

## M2 进展（2026-08-23，D-L1 完成）

分支 `feature/commit-memory-handshake`，提交 `5eab29b`。按 M2 模块化
边界的第一步完成：

- `rtl/lcvex_l1_d`：D-L1 数据缓存（写通 + no-write-allocate，直接映射，
  64 B line / 64 组 = 4 KiB，物理地址 tag/index，单阻塞 miss），完全复用
  M1-B 的 `mem_req/mem_rsp` 协议，插入 dmem 与仲裁器之间不触及核心。
- 单元测试 `sim-sv-l1d`：读命中/读 miss 填行/写通/写命中行更新/
  冲突替换/越界 fault 全过。
- SoC 参数 `D_L1_ENABLE=1`；`lockstep-build-l1d` 构建下 p4c 7 组、
  p5a 3 组、hardening 9 组、q6、P2 lockstep 36 条全部与 QEMU 锁步一致。

**M2 剩余**：I-L1（`lcvex_l1_i`，结构与 D-L1 对称但只读）、统一 L2
（32 KiB 2-way）、ISB/DMB/DSB、DC/IC/TLBI 最小子集、Device/不可缓存
（MAIR 属性旁路）、维护指令与覆盖率的系统测试。

## M2 进展（2026-08-23，I-L1 完成）

提交 `b4d4f25`。I-L1 只读缓存完成（结构与 D-L1 对称、无写路径），
SoC 增加 `I_L1_ENABLE`；`lockstep-build-l1di`（I+D 双缓存）下
p4c/p5a/hardening/q6/P2 19 组锁步全过。同时修复两个 L1 正确性 bug：
响应字节按请求偏移右旋（`rotate8`，refill 捕获含偏移的块），以及
D-L1 写命中索引（块对齐偏移改完整字节偏移）。

**M2 剩余**：统一 L2（32 KiB 2-way）、ISB/DMB/DSB、DC/IC/TLBI 最小
子集、MAIR Device/不可缓存旁路、维护指令系统回归。

## M2 进展（2026-08-23，统一 L2 完成）

提交 `bab3bd7`。统一 L2（I/D 共享，32 KiB、2-way、LRU、写通）完成并
接入仲裁器与延迟/SRAM 之间；`lockstep-build-l1dl2`（I+D+L2 全缓存）
19 组锁步与 QEMU 一致。三个缓存 TB 的握手改为“保持 valid 直到响应”
（命中 1 拍响应不再被错过）。顺带修复 L2 tag 位宽（SETS=256 时
tag=[63:14]）。

**M2 剩余**：ISB/DMB/DSB（不能当 NOP）、DC/IC/TLBI 最小子集、
MAIR Device/不可缓存旁路、维护指令系统回归（Gate D）。

## M2 进展（2026-08-23，M2-4a 屏障 + M2-4b 缓存/TLB 维护完成）

分支 `feature/commit-memory-handshake`，提交 `90b3d45`（M2-4a）与
`af4cf5c`（M2-4b）。M2 的指令语义部分收口（详见 handoff 015/016）：

- **M2-4a（`d6fef1e`）**：ISB/DMB/DSB/SB 解码为 `SYS_BARRIER`，在 ID 级
  等前方流水线（含未完成访存）排空后提交并重取；`hard_barrier` 定向测试
  与 QEMU 锁步。
- **M2-4b**：IC/DC/TLBI 最小子集落地。
  - `mem_req_t` 增加 `maint` 字段（`MAINT_IC_IVAU/IALLU`、DC 各 op、
    `MAINT_TLBI`），编码取自 QEMU `helper.c v8_cp_reginfo` 并探针实测。
  - `lcvex_decode`：SYS 空间（op0=01）识别 IC/DC/TLBI；EL0 权限按
    SCTLR_EL1.UCI 与 PL1-only 区分（QEMU accessfn 语义）。
  - `lcvex_core`：维护指令走 `sys_at_id`（ID 级排空后提交）；IC IVAU 的
    VA 经数据侧 MMU 翻译成 PA 后向 I-L1 发失效请求（翻译失败与 QEMU
    system 模式一致不产生异常）；IC IALLU 整表失效；TLBI 发
    `tlb_invalidate` 脉冲；DC 各 op 在写通层次为功能无操作（仅识别提交）。
  - `lcvex_l1_i`：支持按 PA 单行失效与整表失效（直接响应、不下发下游）；
    `lcvex_mmu`：新增 `tlb_invalidate` 输入整表失效并中止在途遍历。
  - 验证：`hard_selfmod`（含 IC IVAU）在基础与全缓存（I+D+L2）配置下均
    与 QEMU 一致（全缓存转绿 = M2-4b 完成判据）；新增 `hard_tlbi` 定向
    测试（运行期修改 L3 描述符 + TLBI VMALLE1IS + DSB/ISB + IC IVAU，
    验证 TLB 整表失效后重新遍历），基础与全缓存均锁步通过。

**M2-4b 过程中修复的两个 RTL bug**

1. 解码器 `unique case` + 拼接表达式在 Verilator 下不匹配（IC/DC/TLBI
   被误判为 UDEF），改为显式 if-else 编码匹配。
2. **P5a 遗留**：`mmu_req_va/is_insn/is_write` 的 mux 以
   `d.is_load || d.is_store` 判断请求类型，而数据翻译完成后 load/store
   仍停留 ID，此刻先发出的取指翻译会被误标为数据翻译（VA 取
   `d.mem_addr`），导致取指按数据页地址翻译。改为以 `data_req_valid`
   为准；`hard_tlbi` 暴露，修复后 MMU 全套（hardening 12 组 + p4c/p5a/
   p4b）与随机回归无回归。

## M2 进展（2026-08-23，M2-4c MAIR Device/不可缓存旁路完成）

提交见 handoff 017。按 MAIR_EL1 属性把 Device（memtype 0..3）与 Normal
Non-cacheable（0b0100）区域直通 L1/L2（不命中、不分配、不更新行）：

- `mem_req_t` 增加 `bypass`（缺省 0=正常缓存路径）；MMU 按页描述符
  AttrIndx[4:2] 索引 MAIR_EL1 输出 `cacheable`，TLB 记录 `tlb_cacheable`；
- 核心把翻译结果 `cacheable` 随取指/数据路径映射到
  `imem/dmem_req.bypass`；L1D/L1I/L2 新增 `S_BYPASS` 直通状态；
- 单元 TB 新增 bypass 用例（旁路写不更新行、旁路读直通 RAM、不分配）；
  新增 `hard_mair_bypass` 定向锁步（Device/NC/WB 三页读写），基础与全缓存
  配置均与 QEMU 一致；全回归绿。

## M2 进展（2026-08-23，M2-5 Gate D 系统回归完成）

提交见 handoff 018。Gate D 退出条件全部关闭：

- 全缓存 + 随机下级延迟（0..4 周期 LFSR）锁步构建
  （`lockstep-build-l1dl2-delay2`），定向 4 组 + 随机 3000 条与 QEMU
  一致；
- 缓存 SVA（单 outstanding、下游响应消费必在等待态；L1I 维护响应与
  IVAU 行失效断言）；I-L1 维护失效单元用例；
- 新增 MMU 单元 TB（TLB hit/miss/fault/权限/MAIR cacheable/
  tlb_invalidate 重新遍历）；
- `make coverage`：L1D/L1I/L2/MMU/mem_if TB 合并覆盖率（7199 点）；
- Gate D 验收脚本 `run_gate_d.sh`（14 步、35 项子检查）全绿；
- 顺带修正 `hard_mair_bypass` 的 MAIR 立即数字节序。

**P5b 之后（R1/Linux 前）**：ESR_EL1/FAR_EL1 完整 syndrome、块描述符、
SCTLR/TCR/TTBR 写后失效、交叉工具链/ELF/裸机 C、空流水线取指 fault
合成提交（handoff 016/018 记录；块描述符/空流水线/ESR-FAR 已完成，
见 handoff 019-021）。

## P6/Linux 前 R1 进展（2026-08-23，块描述符完成）

提交见 handoff 019。MMU 支持 4K 颗粒下 L1（1 GB）/L2（2 MB）块描述符：

- 遍历重构为统一完成态 `S_COMPLETE`（AF/权限/PA 越界/TLB 填充）；
  `desc_pa`/`desc_pa_page` 按级别生成输出地址与 4K 页基址；
- MMU 单元 TB 新增 2MB/1GB 块与块内多页用例；新增 `hard_block_desc`
  定向锁步（base/全缓存/delay2 均与 QEMU 一致）；
- 回归：make test、hardening 14/14、m2/R1 10/10、run_gate_d.sh 39 项
  全部 PASS。

**R1 剩余**：ESR_EL1/FAR_EL1 完整 syndrome、SCTLR/TCR/TTBR 写后失效、
空流水线取指 fault 合成提交、交叉工具链/ELF/裸机 C。

## P6/Linux 前 R1 进展（2026-08-23，空流水线取指 fault 完成）

提交见 handoff 020。关闭“系统指令提交后下一条取指 fault 无法合并”的
已知限制，并修复 mmu_en=1 时任意 MSR 的死锁：

- 前瞻 MMU 状态（mmu_en_eff/tcr_eff/ttbr0_eff/ttbr1_eff/mair_eff）：
  ID 级 MSR 提交前取指翻译按提交后状态进行；MMU 实例接入前瞻输入；
- MSR 提交条件：使能 MMU 的 SCTLR 与 mmu_en=1 时的 MSR 等待
  `fetch_next_settled`，翻译失败经 `sys_fetch_merge` 合并为 IABT
  （与 QEMU step 插件语义一致）；
- 新测试 `hard_sys_fetch_fault`（MMU 使能后下一条未映射 -> IABT 合并）
  与 `hard_msr_mmu_on`（mmu_en=1 时 MSR 不阻塞）；M2/R1 定向 14/14、
  hardening 16/16、run_gate_d.sh 47 项全部 PASS。

**R1 剩余**：ESR_EL1/FAR_EL1 完整 syndrome（含锁步协议扩展）、
SCTLR/TCR/TTBR 写后失效（可选）、交叉工具链/ELF/裸机 C。

## P6/Linux 前 R1 进展（2026-08-23，ESR_EL1/FAR_EL1 完整 syndrome 完成）

提交见 handoff 021。异常提交从仅比较 ESR.EC 升级为完整 ESR 与 FAR：

- QEMU fork patch 导出完整 `env->exception.syndrome` 与
  `env->exception.vaddress`；协议/插件/协调器比较 `exc_esr/exc_far`；
- RTL 新增 esr_el1/far_el1 寄存器（MRS/MSR 支持），各异常源生成
  EC<<26|IL|ISS（UDEF/SVC/IABT/DABT/外部中止）；FAR 仅 abort 类更新；
- MMU 输出 fault_fsc（翻译 0x04+level、AF 0x08+level、权限 0x0C+level、
  PA 越界/外部中止 0x10、tsz_oob 与 TTBR gap=0x04）与 tlb_level；
- 新增 `hard_esr_far`（MRS 回读验证架构可见）；全套异常用例在完整
  ESR/FAR 比较下通过；run_gate_d.sh 51 项全部 PASS。

**R1 剩余**：SCTLR/TCR/TTBR 写后失效（可选）、交叉工具链/ELF/裸机 C。

## M3 进展（2026-08-23，编译器指令第一批 + 裸机 C 跑通）

提交见 handoff 022。用真实交叉编译器建立 ISA 缺口清单并补第一批：

- 逻辑立即数（位掩码）AND/ORR/EOR/ANDS（`mov w,#0xf0f0f0f0` 等）；
  位域 SBFM/UBFM（LSR/LSL/ASR 立即数、SXTB/UBFX）；
- `baremetal/` 启动/链接/最小 C + `scripts/build-baremetal.sh`；
  编译后的裸机 C 在 RTL 上与 QEMU 锁步 200 条一致；
- 新增 `hard_compiler_isa` 定向测试；run_gate_d.sh 55 项全部 PASS。

**M3 剩余**：MADD/MSUB/UMULL、CSEL 族、BFM、LDR literal、寄存器偏移
寻址、exclusive；扩展裸机 C 测试，Linux head.S 缺口清单。

## M3 进展（2026-08-24，LDP/STP 成对访存完成）

提交见 handoff 023。LDP/STP 全寻址模式（offset/pre/post、X/W 对）落地：

- 提交包扩展双/三 GPR 写回与成对存储表示（QEMU 插件语义：X 对单条
  128 位存储 data=rt，W 对 64 位 data={rt2,rt}）；
- 成对访存双请求 FSM、wb2/wb3 前递与 load-use、SP 基址更新；
- 修复 WB 级 dmem 响应 fault 不冲刷/不重定向的潜在 bug；
- mmu 关闭时非 canonical 地址报 address-size fault（FSC=0）与 48 位内
  未映射区外部中止（0x10）区分；
- 裸机 C 增加 pair_t 结构体访问（stp/ldp），200 条锁步一致；
  run_gate_d.sh 59 项全部 PASS。

**M3 剩余**：MADD/MSUB/UMULL、CSEL 族、BFM、LDR literal、寄存器偏移
寻址、exclusive；随后 Linux head.S 缺口清单。

## M3 进展（2026-08-24，寄存器偏移寻址 + 扩展寄存器 ADD/SUB 完成）

提交见 handoff 024。编译器数组/索引寻址落地：

- LDR/STR 寄存器偏移（`[rn, rm, lsl #s]`，含 byte/half/word/dword、
  LDRSB/LDRSH/LDRSW、PRFM=NOP）；扩展寄存器 ADD/ADDS/SUB/SUBS
  （uxtw/sxtw/uxtb/lsl 选项 + 移位，非 S 形式支持 SP）；
- 裸机 C 扩展数组访问与结构体对（-mgeneral-regs-only），200 条锁步
  一致；hardening 21/21、M2/R1 24/24、run_gate_d.sh 67 项全部 PASS。

**M3 剩余**：MADD/MSUB/UMULL、CSEL 族、BFM、LDR literal、exclusive；
随后 Linux head.S 缺口清单。

## M3 进展（2026-08-24，乘加族 MADD/MSUB/SMADDL/UMADDL 完成）

提交见 handoff 025。Data-processing 3-source 乘加族全部落地并锁步：

- 解码：`insn[28:23]∈{110110,110111} && insn[22]==0` 的 3-source 分支，
  加/减由 **bit15** 区分（bit21=0 -> MADD/MSUB；bit21=1 bit23=0 ->
  SMADDL/SMSUBL；bit21=1 bit23=1 -> UMADDL/UMSUBL）；
- `lcvex_muldiv`：op 扩为 4 位（0..8），新增 `acc`（Ra 初始累加）与
  `sub_mode`（减族在 acc 上减乘积）；SMADDL/UMADDL 对 Rn/Rm 做
  符号/零扩展后走 64 位移位累加；32 位 MADD 结果截断低 32 位；
- `operand_c` 加入 ID/EX 流水线与提交包旁路；
- **修复**：除零短路原条件 `op!=MUL` 会误伤 b=0 的 MADD 族（结果应为
  Ra 而非 0），改为仅 UDIV/SDIV 生效，并补 b=0/a=0/32 位溢出截断
  三个定向边界；
- `hard_madd` 定向 36 条指令/40 条提交覆盖 6 种操作 + 3 个边界，base、
  全缓存、delay2 三档全绿；裸机 C 改用 volatile 读取防止常数折叠，
  确认真实发出 `madd x0,x0,x1,x2` 与 `umull x0,w0,w1`，200 条锁步一致；
- 回归：M2/R1 26/26、hardening 22/22、Gate D 全量 PASS（含随机 100k）。

**M3 剩余**：CSEL 族、BFM、LDR literal、exclusive；随后 Linux head.S
缺口清单。

## M3 进展（2026-08-24，条件选择族 CSEL/CSINC/CSINV/CSNEG 完成）

提交见 handoff 026。Data-processing 2-source 条件选择全部落地并锁步：

- 解码：`[28:24]==11010 && [23:21]==100 && [30:29]∈{00,10}`；
  `[30:29]` 区分 CSEL/CSINC 与 CSINV/CSNEG，bit10 区分加一/取负；
  条件在 ID 级按前递 NZCV 求值（与 B.cond 同一 `cond_taken`），
  decode 合并选中值，ALU 新增透传 op；
- 32 位按低 32 位运算并零扩展（CSNEG 回绕 `-0x80000000`）；XZR
  操作数语义正确（不用 SP）；
- 裸机 C 新增 `csel_fn` 三元表达式，编译器真实生成
  `cmp + csel x0,x0,x2,ls`；`delay(8)->delay(4)` 保持 200 条窗口覆盖；
- `hard_csel` 定向 55/60 条覆盖 8 种条件两分支 + 32 位回绕 + XZR，
  base、全缓存、delay2 三档全绿；M2/R1 28/28、hardening 23/23、
  Gate D 全量 PASS（含随机 100k）。

**M3 剩余**：BFM、LDR literal、exclusive；随后 Linux head.S 缺口清单。

## M3 进展（2026-08-24，BFM 位域插入完成）

提交见 handoff 027。Bitfield 三种 opc（SBFM/UBFM/BFM）补齐：

- 解码开放 `[30:29]==01`（此前 UDEF），W 形式 N/immr[5]/imms[5]
  约束提到三种 opc 共用；BFM 以旧 Rd 为 deposit 基础（`operand_c` +
  rs3 前递/load-use 复用 MADD 路径）；
- ALU 新增 `c` 输入与 `bfm_deposit`（QEMU `trans_BFM` 语义）：
  si>=ri 提取插入低位，si<ri 左移插入，字段外保留旧 Rd，W 高 32 位
  清零；`BFI/BFXIL/BFC` 别名自动覆盖；
- `test_alu` 3 例 + `hard_bfm` 定向 25/30 条（单比特、全宽、W、
  源 XZR），base、全缓存、delay2 三档全绿；M2/R1 30/30、
  hardening 24/24、Gate D 全量 PASS。

**M3 剩余**：LDR literal、exclusive；随后 Linux head.S 缺口清单。

## M3 进展（2026-08-24，LDR literal 完成）

提交见 handoff 030。PC 相对加载四种形式落地：

- 解码 `[29:24]==011000`：opc=00/01/10/11 对应 LDR W/X/LDRSW/PRFM，
  地址 = pc + SignExtend(imm19)<<2；LDRSW 复用符号扩展通路；
- a64.py 新增标签相对 literal 编码器（±1 MiB 校验）；
- `hard_ldr_literal` 定向 10/15 条三档全绿（含 LDRSW 符号位、
  lit64 8 字节对齐、PRFM=NOP）；
- **M3 仅剩 exclusive**；测试增强计划见 TEST_ENHANCEMENT_PLAN.md。

## M3 进展（2026-08-24，exclusive 指令完成，M3 收尾）

提交见 handoff 033。单寄存器 exclusive 族
（LDXR/LDAXR/STXR/STLXR/CLREX）落地，M3（Linux 前 ISA 收敛）全部
关闭：

- 语义按 QEMU 11.1.0 源码 + 实跑探针锁定：LDXR 记录 clean VA 与加载
  值；STXR 地址相等且内存当前值（按 STXR 宽度截取）相等才条件写并
  返回 0，否则不写返回 1；STXR 无论成败、CLREX、ERET、复位清监视器；
  **A profile 异常入口不清**（SVC/UDEF/Abort，探针实测 w10=0）；
- RTL：decode 识别 exclusive 族；核心新增架构监视器（提交时更新）、
  STXR 排空后“读比较写”两相访存（失败无副作用）、提交包新增
  `mon_we/mon_valid/mon_addr/mon_data`；
- 协议：QEMU 插件按指令编码 + 寄存器状态追踪监视器并在 COMMIT 上报，
  协调器逐提交比较；修复 QEMU 插件对“地址匹配但值不匹配”失败 STXR
  上报幻影 store 的问题（按状态寄存器结果丢弃）；
- **随机回归暴露并修复 3 个真实 bug**：STXR 状态写回未纳入 load-use
  （下一指令读到 EX/MEM 假值 0）；分支冲刷在 EX/MEM 访存冻结时丢失
  分支本身（flush 门控到可接收）；STP 的 rt2 未登记读源（读到陈旧值）；
- 验证：`hard_exclusive` 定向 55 条（含跨 size、CLREX、LDAXR/STLXR、
  SVC/ERET 往返、rs=31）base + 全缓存锁步全绿；随机 seed 1~3 × 100k
  （含 exclusive 对/直接 STXR/CLREX 路径）全部 PASS；make test 全绿。

**M3 剩余**：无（ISA_SCOPE 支持矩阵已闭合）；下一步 Linux head.S 缺口
清单 → P6。

## M3 进展（2026-08-24，UMULH 与系统 microbench 锁步补强）

在 Linux 12M 锁步首次分歧处补齐 `UMULH`（Data-processing 3-source）：

- 解码 `0x9b/0x9c` 主类中 `bit22:21=10`、`[15:10]=011111` 的 `UMULH`，
  只读 Rn/Rm、写回 Rd，不更新 NZCV；
- 多周期乘除单元新增 128 位移位累加路径，最终提交无符号乘积高 64 位，
  不截断低半部导致进位丢失；
- `t_sys.c` 增加 `0xffffffffffffffff×2` 与 `0x100000000×0x100000000`
  两个边界检查；`PAR_EL1` Normal RAM 成功属性与 QEMU 的 `0xb00` 对齐。

验证：`make microbench` 全量 8/8 通过，`MB_ONLY=sys` 通过；裸机镜像
`MAX_INSNS=12000` 逐指令锁步全绿（覆盖两条 UMULH）；`make test` 全绿。

## P6 进展（2026-08-24，Linux 启动 ISA 缺口闭合）

提交见 handoff 034。用真实 Linux 6.6 内核（本机构建）+ QEMU trace 实证
启动前 15 万条指令，得到权威缺口清单并全部实现：

- 指令：`REV/REV16/REV32`、`CLZ/CLS`（W/X）、`CCMP/CCMN`（立即数/
  寄存器，条件真=比较标志、假=NZCV 立即数）、`BTI`（按 NOP）、
  `MSR（immediate）DAIFSet/DAIFClr/SPSel`；
- 系统寄存器：只读 ID 族（MIDR/ID_AA64*/CTR_EL0/CNTFRQ/CurrentEL）、
  读写（CPACR/MDSCR/PMUSERENR/CNTKCTL/TPIDR/TPIDRRO/SP_EL0/TCR2/
  PIR/PIRE0）、EL2（读 0 写忽略）；值/掩码与 QEMU `-cpu max` 实测一致；
- 修复真实 bug：addsub-ext 与 reg-offset 的 rm 未登记读源（load/STXR
  晚写回读到陈旧值，随机回归复现）；
- 验证：`hard_p6_isa` 75 条定向（base+全缓存）全绿；随机 seed 1~3 ×
  100k（含新族）全 PASS；make test 与覆盖记账（新增 rev/clz/ccmp/
  ccmn/bti 族）全绿。

**P6 平台准备**：RTL 内存模型已从 1 MiB SRAM（0x44000000..0x44100000）
扩展为 128 MiB RAM（0x40000000..0x48000000），与 QEMU virt 布局完全对齐；
差分测试程序基址保持 0x44000000（QEMU 11.1.0 virt 无条件在 0x40000000
放置 DTB，实测 0x40000000..0x40100000，基址必须避开）；新增 >1 MiB
镜像加载锁步（hard_big_mem）与大容量 RAM 单元测试（TOP=0x48000000
边界）；**Gate D 全量回归 PASS**（96 个步骤全绿，见 handoff 035）。

**P6 剩余**：平台功能（PL011 UART、Generic Timer、GICv2、DT、PSCI）。

**P6 PL011 UART（见 handoff 036）**：新增 `lcvex_mem_router`（组合转发，
零额外延迟）与 `lcvex_pl011`（QEMU 11.1.0 pl011.c 语义逐条复刻，探针
实证复位值/INT_TX/回环/FIFO/ID）；MMU 允许 MMIO PA（cacheable=0），
MMU 关闭时窗口访存放行；`hard_uart` 定向锁步 62 条（base/全缓存/随机
延迟全绿）+ `lcvex_pl011_tb` 单元测试 + mmu_tb MMIO 用例；Gate D 全量
回归验证。

**P6 Generic Timer（见 handoff 037）**：CNTPCT/CNTVCT 计数器每提交 +1
（与 QEMU `-icount shift=0` 对齐：CNTPCT=已执行指令数），CNTP/CNTV
TVAL/CTL/CVAL 按 QEMU `gt_*` 语义实现（ISTATUS 读时组合、TVAL 截断/
sext32、中断线输出）；QEMU 锁步/trace 统一加 `-icount` 使计数器确定性
可差分；`hard_timer` 定向锁步 40 条全绿；已知限制：EL0 定时器 CNTKCTL
门控（EC=0x18）留待 EL0 sysreg 保真度阶段。

**P6 GICv2 + 异步 IRQ（见 handoff 038）**：`lcvex_gic` 单核无安全扩展
模型（GICD/GICC 寄存器 + SGIR/IAR/EOI/优先级选路，QEMU arm_gic.c 语义
复刻 + 探针复位值）；核心 IRQ 入口（普通提交边界、向量 +0x280/0x80/
0x480、exc_code=0x40）；QEMU fork step 模式 async COMMIT；`hard_gic`
50 条 + `hard_irq` 30 条定向锁步全绿；已知限制：IRQ 不在 sys 提交
（MSR/ERET）边界抢占，FIQ 未实现。

**P6 Device Tree 确定性校验（2026-08-24）**：新增
`scripts/validate_virt_dtb.py` 与 `make dtb-smoke`，固定 QEMU
`virt,gic-version=2,dtb-randomness=off`，验证 128 MiB RAM、PL011、GIC、
Generic Timer、PSCI HVC 和单核 CPU 节点，并输出 compact DTB SHA256；KERNEL
锁步实际 FDT 导出文件移至 `build/difftest/`，避免 `/tmp` 原始 DTB 堆积。

**P6 Linux 启动实证（见 handoff 039）**：QEMU 内核启动 trace 已推进到
"alternatives: applying system-wide alternatives"（800k 指令；此前
handoff 034 为 "random: crng init"）；关闭新实证缺口 LDUR/STUR 族与
CSET 等别名（`hard_ldur` 45 条定向锁步全绿）；建立内核 trace 基建
（DTB 提取/截断、Image text_offset 补丁、启动命令）；下一步：协调器
双镜像加载 + RESET_PC 变体 -> 内核锁步差分。

**P6 Linux 锁步推进（2026-08-24，见 handoff 043-048）**：已从早期
713k 逐步推进到 14,000,000 条提交，QEMU/RTL 全部一致；期间补齐
PCREL 别名、PACIASP/HINT、TLBI、DAIF、AT/PAR、STLR/LDAR、UMULH 和
RBIT。14M 窗口结束时仍处于 Linux 内核路径，尚未进入 PSCI、用户空间或
Gate E 的长时间稳定运行验收。长跑锁步已支持降低进度日志频率，避免产生
GB 级无索引日志。

**P6 Linux 深启动缺口（2026-08-24，见 handoff 048）**：14M 窗口前的
`RBIT X24,X24` 分歧已关闭，RBIT W/X 已纳入 RTL、定向、随机和 microbench
覆盖；`hard_p6_isa` base/cache 双配置全绿。下一轮继续以运行时指令定位
缺口，不以静态反汇编替代提交包。

**P6 PSCI HVC 最小闭环（2026-08-24，见 handoff 049）**：14.85M 附近的
`DISCON kind=3` 已通过压缩 QEMU 尾迹定位为 alternatives 修改出的
`HVC #0`（`PSCI_VERSION`），不是 RTL 状态分歧。step 插件现在把 PSCI/
semihosting hostcall 延迟到下一条指令回调，作为普通 COMMIT；RTL 解码器
加入 HVC/SMC 最小 PSCI 返回集（VERSION、FEATURES、MIGRATE_INFO_TYPE 返回 2、
AFFINITY_INFO、单核 CPU_ON），`hard_psci` 29 条锁步已在 base/cache 两配置
通过。修正后的 Linux 长跑在 `seq=14867468` 暴露并关闭了
`MIGRATE_INFO_TYPE` 返回值缺口（QEMU=2，旧 RTL=0）；尚未从头重跑越过该点。
独立长 trace
曾达到约 1.2 GiB RSS，已停止；后续长跑必须继续使用 `tb-size=64` 的 step
锁步并绑定物理核。下一步是 Linux 15M+ 深启动；差分 checkpoint 设计和分阶段
验收见 handoff 050，当前不启用 `CKPT_EVERY`。

**P6 差分 checkpoint L1/L2 原型（2026-08-24，见 handoff 050/052/055）**：新增
`CKPT_REQ/CKPT_READY` 协议、QEMU fork device-state 保存、共享 RAM backend
和压缩 base/diff/arch/sys/timer/gic 链；`hard_psci` 29 条每 10 条保存全绿，RAM 链恢复后
`cmp` 全等，`restore-qemu` 在 seq=9 恢复到 PC `0x44000028`。新增
`make checkpoint-dut-smoke`，已验证裸机 GPR/SP/NZCV/下一条 PC 注入和流水线
冲刷；真实 Linux 的 MMU/TLB/cache 恢复和链压缩仍待完成，
实际 `diff-19.arch.gz` 摘要继续 5 条提交、附加 128 MiB RAM 灌入的 smoke
也已通过；新增 Generic Timer `*.timer.gz` sidecar（CNTPCT/CNTFRQ、CVAL、CTL
及 offset 字段），`read-timer` 和 `make checkpoint-timer-smoke` 全绿；QEMU
`-incoming` 恢复时由插件校正虚拟计数基准，同一 seq=0 的 QEMU/DUT 下一条
`CNTVCT` 联合恢复通过；新增 GICv2 单核摘要（前 96 IRQ 的 enable/pending/active/
priority 与 GICC 控制状态），`make checkpoint-gic-smoke` 从 seq=29 恢复 5 条
MMIO 指令全绿；同一 seq=19 checkpoint 启动 QEMU `-incoming` + step 插件后，
与 DUT 联合锁步 5 条也已全绿，包含 `*.sys.gz` 系统寄存器注入。Linux MMU/
TLB/cache 状态尚未完整恢复，Linux 长跑暂不启用差分 checkpoint。handoff 055
新增版本化 `manifest.json`：绑定 Image/DTB、QEMU 可执行文件和
`qemu/VERSION` 的 SHA256，并记录所有压缩 artifact 与 `manifest.tsv` 的摘要；
`checkpoint.py` 在恢复前拒绝输入或链内容变化，`make checkpoint-manifest-smoke`
覆盖篡改拒绝。随后以 `/tmp/Image-t80000` 做 KERNEL=1、100 条受控锁步，
在 seq=49 的真实 Linux 早期 checkpoint 上完成 QEMU `-incoming` 与 DUT
5 条联合恢复；handoff 056 记录了旧 QEMU sys sidecar 的 live-SP 采样缺口及
patch 修复，并在修复后的 QEMU 上完成 `SCTLR.M=1` checkpoint 5 条联合恢复；
当前仍不支持链压缩/自动淘汰，Linux 15M+、Timer IRQ/WFI 和用户空间尚待验收。

**P6 系统寄存器批量闭合（2026-08-24，见 handoff 057）**：固定 QEMU
11.1.0 的 `cpu-sysregs.h.inc` 取证清单共 44 个 ID/CLIDR 寄存器，新增
`qemu-sysreg-inventory` 和 `hard_id_sysreg`；44 个读取在 base/cache
两配置共 47 条逐指令差分全绿。该批次只覆盖只读 profile 寄存器，不提前
宣称 FP/NEON/SVE、PMU/JTAG 或 EL2/EL3 功能。

handoff 058 进一步记录 Linux 到达 SVE/SME 探测后的 P6 兼容 shim
（ZCR/SMCR、RDVL/RDSVL、CSSELR）以及 ERET PC alignment EC=0x22 修正；
这些 shim 不代表 P8 SVE/SME 完成。旧 checkpoint sidecar 尚未包含
ZCR/SMCR/CSSELR，正式恢复需升级 sys sidecar v2。

**P6 SVE/SME 探测 shim 修正与 sidecar v2（2026-08-24，见 handoff 059）**：
用真实 Linux 尾段续跑（seq=9999999 起）逐条关闭探测与 alternatives
补丁暴露的缺口：SMCR/SMPRI 编码拆分与 MRS 读回、CSSELR 编码/掩码、
SMIDR/AIDR 只读 ID、RDSVL 按 QEMU SME VQ 映射取整、EXTR（ror 别名，
含 32 位回卷）、RNDR/RNDRRS 确定性镜像，并修复两个 P4 遗留 SP 银行
bug 与 SPSel 解码过度限制。`hard_sve_probe`（60 条）与 `hard_p6_isa`
（100 条，含 EXTR/SPSel 边界）base/cache 全绿；续跑已推进到本地
180 万条（总 ~11.8M）全绿。sys checkpoint sidecar 升级 v2（新增
ZCR/SMCR/CSSELR），`make checkpoint-sys-smoke` 验证捕获+恢复闭环；
旧 14m 链在 QEMU 重建后复制为 `linux-resume-14m-rndr`（更新 manifest，
vmstate 兼容）。

**P6 Linux 尾段与锁步诊断修复（2026-08-25，见 handoff 062）**：从
`tail-resume-ckpt4` 的 `RESUME_SEQ=1999999` 恢复，续跑 900000 条逐指令
差分通过，跨过全局约 14.8M 目标。此前在 `MSR DAIF` 附近观察到的提交丢失
被证明是协调器失败诊断 `read_mem()` 内部调用 `tick()` 造成的 DUT 偷跑，
不是 RTL 的 IF/ID 覆盖；现已改为无时钟直接读取 Verilator RAM，并删除临时
逐拍调试端口/日志。`hard_p6_isa` 的 MSR DAIF 定向测试保留为正式回归。
当前 P6 仍未完成 Gate E：Timer IRQ/WFI、稳定 early boot 后的用户空间和
更长负载验收待继续；checkpoint 链的空间上限与 sidecar 版本约束保持不变。

**P6 Linux 深段 MMIO/PAuth 收敛（2026-08-25，见 handoff 063）**：真实
Linux IRQ/初始化路径暴露并关闭 GIC MMIO2 地址窗口、GICv2m MSI frame
探测、SCTLR2_EL1 与 PAuth key 写入缺口；QEMU difftest 活跃时屏蔽 PAuth
enable 位，使 P6 的 PAC HINT=NOP shim 与参考模型一致。DUT TLB 扩为
64 项全相联，续跑 checkpoint 链使用绝对 artifact 路径。`hard_gic` 52 条、
MMU MMIO2 单元、M2-4b base/cache 全部通过；多个新链的 Linux 续跑已连续
通过约 26M 指令，并修正 EXTR 64 位拼接方向、PSTATE/RAS/TPIDR2/SMCR.FA64 探测；YIELD 已按 NOP 对齐；约 28M 首次暴露 LSE `LDADDAL` 原子缺口。P6 仍未完成 Gate E：Timer IRQ/WFI、稳定 early boot 后
用户空间和更长连续负载待继续。

**P6 LSE 原子族与 ECV 视图（2026-08-25，handoff 069/本轮）**：从
`tail-resume-ckpt17-20260825` 的 `diff-999999` 复现并逐项关闭了 Linux
深段原子缺口。RTL 在 EX/MEM 采用单阻塞两阶段事务：先读旧值，再按操作码
计算并发写；CAS 比较失败不发 Store，比较成功只发一次 Store，旧值按 W/X
宽度写回目标寄存器。当前支持单寄存器 `LDADD/LDCLR/LDEOR/LDSET/LDSMAX/
LDSMIN/LDUMAX/LDUMIN/SWP`、`ST*` 别名和 `CAS/CASA/CASL/CASAL` 的 W/X
形式，B/H 编码共用同一数据通路；随后又加入 LSE128 `CASP/CASPA/CASPL/
CASPAL` 的 X 寄存器对四阶段事务。`CNTVCTSS_EL0/CNTPCTSS_EL0` 已映射为
QEMU FEAT_ECV 的同值视图。QEMU 插件新增 CAS/CASP 失败幻影 MEM_W 过滤，
避免把比较失败误报为架构 Store。

验证证据：`make compile`、`make lockstep-build-kernel` 成功；从上述 Linux
checkpoint 续跑 100,000 条逐指令锁步通过（覆盖 LDADDAL、CASA/CASL、
CNTVCTSS_EL0、STCLR）；`hard_lse_atomic` 100 条在 base 与 I+D+L2 全缓存
配置均与固定 QEMU 11.1.0 完全一致。正式入口为 `make p6-lse`。CASP 后又
从 checkpoint 连续通过 505193 条，随后 QEMU 在 Linux 等待路径进入 WFI/halt，
协调器等待下一条 PRE 超时；这不是 CASP 差分错误。LSE128 其他原子操作
（LDCLRP/LDSETP/SWPP）和 Gate E 仍未完成。数据/取指 MMU issue 冻结修复已
提交为 `c9c26f1`，详见 handoff 072；WFI/WFE 与 Timer IRQ 的本轮实现见下。

**P6 WFI/WFE 与 Timer IRQ 唤醒（2026-08-25，本轮）**：新增 `SYS_WFI`/
`SYS_WFE`/`SYS_SEV`/`SYS_SEVL`，等待指令在架构提交后进入核心 idle；WFI
等待期间虚拟计数器继续推进，Generic Timer 物理 PPI 按 QEMU virt 正确接到
GIC PPI30（虚拟计时器 PPI27）。QEMU fork 的 0003 patch 在 WFI/WFE helper
退出前显式触发插件 idle 回调；插件以普通 COMMIT retire 等待指令，并通过
`ASYNC` 协议提交 IRQ 唤醒，协调器让 DUT 从 idle 产生对应 EXC_IRQ packet。
`hard_wfi`、`hard_wfe` 各 2 条以及 `hard_wfi_timer_irq` 45 条在 base 配置
全绿；Timer IRQ 用例覆盖 WFI→PPI30→IRQ 向量→IAR/EOI→ERET，后续需补
全缓存/随机延迟和 Linux 长段恢复验证。随后从 `casp-debug-20260825`
`RESUME_SEQ=499999` 复验 Linux 5192 条无差分错误，QEMU 在同一 WFI 等待
路径 120 秒无新 PRE；该结果记录于 handoff 074，Gate E 仍未完成。

**P6 WFIT/WFET 超时等待（2026-08-25，本轮）**：QEMU 11.1.0 原有
`WFIT/WFET` 与 `wfxt_timer` helper 已接入 LCVEX fork 的 idle hook，插件
识别带 `Xt` 寄存器的等待编码，并在超时/事件恢复后清理旧的 wait 状态，
避免后续 IRQ 被误归因到上一条等待指令。RTL 新增 `SYS_WFIT/SYS_WFET`，
在提交边界锁存 Xt 超时值；未到期进入 idle，到期恢复不产生伪造提交，WFET
优先消费本地事件寄存器。新增 `hard_wfit_wfet_timer` 覆盖未来超时、已到期
立即继续和 `SEVL` 事件消费，14 条在 base/cache 均与 QEMU 11.1.0 锁步一致；
`make test`、`make m2-4b`、`make p6-lse` 仍全绿。该实现尚未解决 Linux
实际等待点的中断源/恢复设备状态，也不代表跨核 SEV 或 EL0 陷阱矩阵完成。

**P6 checkpoint Timer/IRQ 边界收敛（2026-08-25，本轮）**：恢复后的 QEMU
原始虚拟时钟可能比 sidecar 计数领先少量 tick；新增 patch 0006 以模 2^64
方式把 Generic Timer deadline 从架构计数转换回 `QEMU_CLOCK_VIRTUAL`，并保留
`UINT64_MAX` 的已触发远期哨兵，patch 0007 在 timer callback 后显式 kick
step vCPU。RTL Timer IRQ 使用“本条提交后的可见计数”，并在 IRQ 提交时冲刷
取指/IFID，避免把旧顺序取指带入 IRQ 向量；checkpoint 恢复同时保留
PSTATE.PAN/DIT 到 SPSR_EL1。Linux 从 `casp-debug-20260825` 的
`RESUME_SEQ=499999` 连续通过 **100,000 条**（含 Timer PPI、IRQ handler、
SPSR PAN/DIT 读取），随后同一入口扩大到 **1,000,000 条**仍无 PRE/COMMIT
差分错误；随后从该边界再通过 1,000,000 条并保存新的压缩链，当前可验证
全局进度约 **31M 条动态指令**，Gate E 仍未完成。

**P6 Linux 31M 后 Debug 系统寄存器缺口（2026-08-25，本轮）**：第四条
压缩链在局部 `seq=20243` 首次遇到 `MSR OSDLR_EL1, XZR`
（编码 `0xd510139f`）。QEMU 11.1.0 `debug_helper.c` 将该寄存器实现为
RAZ/WI dummy；RTL 已加入 `SREG_OSDLR_EL1` 解码和读零/写忽略语义，
`hard_p6_isa` 扩展到 103 条，在 base/cache 均与 QEMU 一致。Linux 第四条
链需从该失败 checkpoint 重新续跑，不能将本次失败点后的路径计入已通过数。

**P6 Linux 31M 后 SMULH 缺口（2026-08-25，本轮）**：修复 OSDL/OSLAR 后
重新从第三条链恢复，第四条链在局部 `seq=527841` 首次遇到
`SMULH x1, x3, x1`（`0x9b417c61`）。已扩展多周期乘法器的有符号高半乘积
路径，并将 `hard_madd` 增至 43 条；base/cache 定向锁步均通过。该 Linux
窗口需从最新修复后的 checkpoint 重新续跑，当前仍不宣称用户空间已验收。

## M3 进展（2026-08-24，覆盖率补缺：BLR/LDRSB/LDRSH）

提交见 handoff 029。按「每条已支持指令必须有定向测试」补齐三个缺口：

- BLR 定向（adr+blr 间接调用：x30 链接写回、冲刷、前递）；
- unsigned-immediate 解码补全 LDRSB/LDRSH（此前仅 LDRSW，其余
  UDEF）与 PRFM=NOP；新增 `ldr_x` 管道字段区分 W/X 符号扩展宽度；
- **修复真实 bug**：LDRSB/LDRSH 的 W/X 分配反了（opc=10 是 X 形式、
  opc=11 是 W 形式），此前从未被差分验证，锁步首条即失败；修复后
  decode 单测 6 例 + 定向 40/45 条三档全绿；
- 已知限制：非对齐访存当前按 PA 越界报 FSC=0x10，未实现 0x21 对齐
  fault（测试编码误用 [x9] 时暴露）；
- Gate D 全量 PASS：M2/R1 32/32、hardening 25/25。

**M3 剩余**：LDR literal、exclusive；随后 Linux head.S 缺口清单。

- **处理器功能：P3 支持子集稳定，P4/P5a 为受限实现，Gate D 尚未进入。**

### RTL 能力

- 单发射、顺序执行的 IF/ID/EX/MEM/WB 流水线。
- EX/MEM/WB 到 ID 的 GPR、SP、NZCV 前递；load-use、单端口内存争用、
  分支冲刷和多周期乘除冻结。
- 已实现的数据处理、分支、基础 unsigned-immediate Load/Store、ADR/ADRP、
  SVC/ERET 和一组 EL1 系统寄存器，详细清单见 [ISA 范围](ISA_SCOPE.md)。
- EL0/EL1、banked SP、ELR_EL1/SPSR_EL1/VBAR_EL1 和最小同步异常入口。
- 4 KiB、四级页表遍历，统一 8 项全相联 TLB，数据与取指翻译，取指 fault
  与上一条提交的合并逻辑。
- 128 MiB、同步 1-cycle RAM 仿真模型（0x40000000..0x48000000，QEMU virt
  布局）；尚无总线、MMIO 或可变延迟
  response 协议。

### 验证与参考模型能力

- QEMU 11.1.0 固定 release、可重放 patch 和官方 TCG 插件。
- P1 文本 trace；P2 socket `SOCK_SEQPACKET` 锁步；P4 起使用 fork 中精确
  step hook，严格检查 `PRE/COMMIT/seq`。
- 提交比较覆盖 PC、next PC、GPR、SP、NZCV、Store 和异常 EC；失败时保存
  PRE、DUT/QEMU post-state、内存写和最近 32 条提交窗口。
- 固定种子随机程序、hazard 定向程序、异常/EL 切换和 MMU 定向程序。
- ALU、独立寄存器堆的 Cocotb 单元测试，以及一个 MOVZ/B 的独立 SV core
  smoke test。

目前的验证边界也很明确：

- 随机生成器只生成已知合法的已支持编码，不能发现 decoder 过度接受保留
  编码、漏检查固定字段或把另一类合法指令误解码的问题。
- 锁步消息没有导出并逐条比较全部系统寄存器、ESR/FAR、页表遍历事件或
  Cache/TLB 内部行为；部分状态只通过后续 MRS 间接观察。
- P4/P5 用例主要由 C++ 协调器复现，尚未同时形成等价的 Cocotb 和独立 SV
  reproducer；与项目验证规范的“三条路径独立复现”目标仍有差距。
- 尚无 RTL SVA、功能覆盖率、代码覆盖率、形式检查或随机失败样本归档任务。

## 本次实跑结果

以下结果均在上述基线本机实跑，而不是仅引用交接文档：

| 命令 | 结果 | 实际覆盖 |
| --- | --- | --- |
| `make test` | PASS | 工具版本、Verilator lint、SV MOVZ/B smoke、8 个 ALU 和 3 个独立 regfile Cocotb test |
| `make difftest-hazard` | PASS | 34 条提交，覆盖前递、load-use、flush、NZCV、MOVK 和乘除路径 |
| `make difftest-random SEED=7 LENGTH=10000` | PASS | 10,002 条提交与 QEMU 一致 |
| `make p4c` | PASS | 7 组 EL1/EL0、SVC、UDEF、IABT/DABT、越权访问和双 SVC 锁步 |
| `make p5a` | PASS | 24/26/40 条三组数据翻译、取指翻译与 fault 合并锁步 |

`make test` 仍提示 `aarch64-none-elf-gcc` 未安装。仓库交接记录中的
`SEED=1 LENGTH=100000`（100,002 条）回归为历史通过结果，本次评估没有重复
执行该大回归。

## 实现质量评估

### 做得好的部分

| 方面 | 评价 | 依据 |
| --- | --- | --- |
| 验证架构 | 强 | commit packet 是 RTL/QEMU/调试共同边界；批量与锁步并存，异常阶段没有误用普通 before-instruction callback |
| 可诊断性 | 强 | 锁步检查 seq、超时、DISCON/EXIT/EOF，保存完整状态和最近提交窗口 |
| 范围控制 | 较强 | AArch64 only、单核顺序、先仿真后 FPGA 等边界清楚，没有提前引入厂商 IP |
| 代码可读性 | 中上 | 模块和状态命名清楚，复杂的异常/取指合并有中文注释和交接记录 |
| 可重复性 | 中上 | QEMU release/commit/patch 已固定，常用回归有统一 Make 入口 |
| 已覆盖子集正确性 | 中上 | 定向、hazard、随机和锁步形成了互补证据；本次复跑全部通过 |

### 需要优先处理的质量风险

#### R0：开始 P5b 前必须关闭

1. **MMU 权限语义与文档不一致。** `lcvex_mmu.perm_fault` 对 AP[2:1]
   的解释错误：EL1 RW 应允许 `00/01`，当前允许 `01/10`；EL0 read 应允许
   `01/11`，当前还错误允许 `10`。代码注释声称 AF 必须置位，但 L3 处理没有
   检查 AF。现有用例只使用 AP=01/11 且 AF=1，正好绕开了错误组合。
2. **系统寄存器 NZCV 位域错误。** AArch64 `MRS NZCV` 的 NZCV 位于
   `[31:28]`，`MSR NZCV` 也从 `[31:28]` 取值；当前 decoder 在低 4 位读写，
   而测试汇编器甚至没有列出 NZCV 编码，因此该路径未被差分覆盖。
3. **decoder 严格性不足。** ADD/SUB immediate 没有实现合法的
   `shift=LSL #12`；MOV wide 的保留 `opc=01` 被当成写零；ADD/SUB extended
   register 可能被宽松掩码误当成 shifted-register；若干分支固定/保留位也未
   完整检查。当前合法子集随机测试无法证明保留编码会产生 UDEF。
4. **提交脉冲依赖气泡。** `memwb_prev_valid` 只对 `memwb_valid` 上升沿提交，
   在当前约 0.5 IPC 的单端口 SRAM 下可工作；一旦 Cache hit 让 WB 连续有效，
   后续指令可能不提交。正确条件应是显式 `wb_valid && wb_ready`/`commit_fire`，
   而不是 valid 电平边沿。
5. **内存副作用没有明确退休握手。** Store 在 EX/MEM 直接拉高 SRAM 写使能，
   commit packet 到 WB 才报告；接口没有 request/ready/response，也没有标识
   “一次请求已接受”。在可变延迟、页表遍历或 Cache backpressure 下容易出现
   重复写、错地址写或已产生副作用但无法精确异常的问题。
6. **内存边界检查只检查首地址。** 多字节访问靠近 `SRAM_TOP` 时没有检查完整
   访问范围，SRAM 模型又只取低地址位，会产生回绕。该行为必须在接入 Cache
   前改为显式 fault，不能依赖数组索引截断。

#### R1：Gate D 前必须关闭

1. **MMU 仍缺少必要一致性。** TTBR0/TTBR1 区域 gap/canonical VA、TG/TnSZ
   合法性、各级描述符保留位、AF、输出地址合法性和跨页访问都未系统覆盖；
   修改 SCTLR/TCR/TTBR 后没有 TLB 失效，TLBI 尚未实现。
2. **异常状态不足以支撑 Linux。** 目前 commit 只携带 ESR.EC，RTL 没有
   ESR_EL1/FAR_EL1 和 fault status/ISS；ERET 非法状态、对齐 fault、访问类型
   与精确 syndrome 尚未形成架构状态和测试矩阵。
3. **流水线控制集中在单个大模块。** `lcvex_core.sv` 同时承担取指、MMU
   仲裁、hazard、系统状态和提交，已经接近千行；新增 Cache 前应先抽出明确的
   fetch/data/PTW 接口和 stage advance/kill 协议。`lcvex_regfile.sv` 有单元
   测试，但核心实际使用另一份内部 GPR 数组，也造成测试对象与产品路径分离。
4. **验证计划中的断言尚未落地。** RTL 中没有“每周期最多一提交、flush 后
   错路不提交、Store 不重复、异常清空年轻指令、TLB 权限一致”等 SVA。
5. **CI 与 main 稳定规则不匹配。** 当前 GitHub Actions 不运行 regfile/core
   Cocotb、QEMU 差分、p4c、p5a 或随机回归；所以“main 只接受通过 CI 的稳定
   提交”目前只代表很小的 smoke gate。
6. **QEMU 重放脚本不安全且不幂等。** 对已有 fork 执行 `checkout -f` 会丢弃
   本地改动；已应用 patch 后再次运行也会失败。应在临时 worktree/新目录验证
   patch，而不是修改开发中的 fork。

#### R2：Linux bring-up 前必须关闭

- 原定第一阶段 ISA 仍缺逻辑立即数、bitfield/移位别名、LDP/STP、pre/post
  index、register-offset Load/Store、MADD/MSUB、conditional select 等常见
  编译器输出；原子/独占访问和完整 barrier 也未实现。
- 没有固定 AArch64 交叉编译器、ELF 装载、linker script、裸机 C 回归或
  编译器生成指令统计，暂时无法用真实软件约束 ISA 优先级。
- P6 所需 timer/IRQ/GIC、WFI、更多 EL1 系统寄存器和 Device memory 语义
  尚未设计；不能用“barrier 当 NOP”作为 Linux 阶段的最终语义。

### 总体质量判断

当前代码适合作为**验证驱动的研究原型和架构探索基线**，还不适合作为
**可直接扩展到 Cache/Linux/FPGA 的稳定 RTL 基线**。验证基础设施质量高于
RTL 完整度，文档完整度高于 CI 约束力。后续工作的最高收益不是继续堆功能，
而是把已发现的隐式时序假设转化为接口协议、断言和阶段门。

## 后续方向与执行规划

### M0：P5a-Hardening——架构语义收敛

目标：修复已知架构错误，并让“已支持/未支持/保留编码”的边界可证明。

工作项：

1. 为 decoder 建独立定向测试：ADD/SUB immediate shift、所有保留字段、
   MOV wide opc、shifted/extended register 区分、分支固定字段和 W/X 边界。
2. 修正 NZCV 系统寄存器位域，并对每个已支持系统寄存器补 reset、读写掩码、
   EL 权限、提交时机和 MRS-after-MSR 锁步测试。
3. 修正 AP 矩阵并加入 4 种 AP × EL0/EL1 × read/write 全组合；加入 AF=0、
   UXN/PXN、各级 invalid/错误 descriptor、TTBR gap、非 canonical VA、PA 越界
   和页边界访问。
4. 明确本阶段支持的 TCR/TG/VA/PA 范围；不支持的组合必须同步异常，不能
   静默按当前简化规则执行。
5. 将现有“Gate A/P4/P5a 通过”文案改成精确的支持矩阵；只有矩阵内全部定向
   + 差分通过才标记完成。

退出条件：上述定向测试全部与 QEMU 一致，P4c/P5a 无回归；至少 5 个固定
seed、每个 100k 提交通过；失败样本可由 Cocotb 和独立 SV testbench 复现。

### M1：提交与内存接口重构

目标：移除对单端口 1-cycle SRAM 和自然气泡的隐式依赖，为 Cache 提供稳定
边界。

工作项：

1. 为各流水级定义统一的 `valid/ready/advance/kill` 规则；WB 以
   `commit_fire` 消费一个 entry，允许连续周期各提交一条，也允许任意暂停。
2. 把取指、数据访问、页表遍历改成显式 request/response 协议，至少包含
   `valid/ready`、地址、读写/字节使能、response valid/data/fault。
3. Store 只在确定不会被 flush/fault 且请求被接受时产生一次副作用；提交包
   与该次接受事件一一对应。
4. 将 PTW/IF/MEM 仲裁从 core 主状态机中抽离；让 SRAM、未来 Cache 和测试
   延迟注入器共享同一接口。
5. 落地 SVA：单提交、提交顺序、无重复 Store、flush/异常 kill、request 保持、
   response 对应和 XZR/32-bit zero-extension。

退出条件：在 0/1/随机延迟和 backpressure 下无丢失/重复提交；构造连续 WB
valid 的测试能做到每周期一次正确提交；Store + iTLB miss/fault 等交叉场景
通过；全部旧回归无变化。

### M2：P5b Cache 与 Gate D

目标：在已稳定的物理内存协议之上加入阻塞式 Cache，而不是把 Cache 控制
继续嵌入 core。

建议第一版固定参数和策略：

- I/D L1 各 4 KiB、64 B line、直接映射、物理地址 tag/index、单个阻塞 miss。
- 统一 L2 固定为 32 KiB、2-way、64 B line；先以正确性和替换可验证性为主。
- 第一版 D-L1 优先选择 write-through + no-write-allocate，降低精确 Store、
  失效和下级可见性的复杂度；性能数据稳定后再单独评估 write-back。
- MAIR 区分 Normal/Device；Device/不可缓存访问旁路 Cache，禁止投机和合并。

工作顺序：cache line SRAM/tag 单元测试 → I-L1 → D-L1 → 统一 L2 →
maintenance/barrier → 系统回归。`ISB` 必须冲刷并重取，`DMB/DSB` 必须等待
相关未完成访问；不能只因为当前是顺序核就无条件解码成 NOP。加入 DC/IC、
TLBI 的最小明确子集，并记录权限、失效范围和完成点。

Gate D 退出条件：hit/miss/refill/evict、冲突替换、脏/写穿副作用、I/D 失效、
Device bypass、TLB hit/miss/fault 和 maintenance 全部有单元与系统测试；可注入
下级延迟；P0～P5a 全量回归通过。QEMU 只作为架构状态参考，Cache 内部事件
必须另用参考模型、断言和覆盖率验证。

### M3：编译器与 Linux 前置能力

目标：先能稳定运行真实编译器生成的裸机程序，再接平台设备。

1. 安装并固定 AArch64 bare-metal 交叉工具链；加入 ELF loader、linker script、
   启动代码和最小 libc-free C 测试。
2. 用编译器输出与 Linux `head.S` 建立 ISA 缺口清单，优先补逻辑立即数、
   bitfield/shift、LDP/STP、常用寻址、MADD/MSUB、conditional select、
   exclusive/atomic 和 barrier，而不是按编码类别平均扩展。
3. 完成 ESR_EL1、FAR_EL1、SCTLR/TCR/TTBR/MAIR 合法位、必要 TLBI/Cache
   maintenance 及相应 commit/trace 状态。
4. 建立“手写汇编 → 编译器裸机 C → 小型 RTOS”三级回归；每个失败保留
   ELF、反汇编、seed/输入和最近提交窗口。

退出条件：多组 `-O0/-O2/-Os` 裸机 C 程序与 QEMU 一致；异常/MMU/Cache
状态可诊断；第一批 Linux 启动代码所需指令和系统寄存器全部进入支持矩阵。

### M4：P6 Linux 平台

按 PL011 → Device Tree → Generic Timer → IRQ/GICv2 → WFI/PSCI 的顺序加入，
每一步保留独立裸机测试，再推进 Linux `head.S`、early console、MMU 初始化、
timer/IRQ 和 init。P7 以后 FP/NEON、SVE、调试/PMU、FPGA 的阶段顺序维持现有
路线图，不提前并行进入。

## 回归与 CI 建议分层

| 层级 | 触发 | 内容 | 目标时长 |
| --- | --- | --- | --- |
| PR-fast | 每次提交 | `scripts/ci-fast.sh`：toolcheck、lint、SV smoke/背压/memif、Cocotb ALU/regfile/背压（无 QEMU） | 分钟级 |
| PR-difftest | RTL/QEMU/系统状态变更 | `scripts/ci-difftest.sh`：P1/P2、lockstep、hazard、P4c、P5a、P5a-Hardening、Q6、短随机 | 分钟级 |
| nightly | 每晚或手工 gate | `scripts/ci-nightly.sh`：5 seed × 100k、随机内存延迟锁步、patch 从干净 QEMU release 重放 | 小时级 |
| milestone | 阶段合并前 | 对应 Gate 全量、裸机软件、失败归档、版本与已知限制快照 | 可审计 |

CI 接入 QEMU 时应缓存固定 release 的构建产物，但必须另有任务从干净 release
验证 patch 可重放。任何 Gate 状态都应链接一次具体的 CI run 或保存的回归
摘要，避免只在交接文档中记录“本机通过”。

已落地（`.github/workflows/ci.yml`：pr-fast / pr-difftest / nightly 三 job，
QEMU fork 按 `QEMU_COMMIT`+补丁哈希缓存；`qemu/scripts/apply-patches.sh`
重写为幂等且不再 `checkout -f`，`--fresh` 支持干净重放）。三个门禁脚本
本地实跑全绿，日志保存于 `build/ci-*/` 供 Gate 链接回归摘要。

## 近期任务顺序

建议严格按以下顺序开分支，避免 P5b 与基础修复互相放大：

1. ✅ `verify/p5a-hardening-tests`：9 组失败测试 + 支持矩阵
   （`4281fcb`，`main` 尚未合并，见下）。
2. ✅ `feature/p5a-arch-fixes`：R0.1～R0.4 修复 + P0～P5a 全回归
   （`8a1a7b6`、`fd7c987`）。
3. ✅ `feature/commit-memory-handshake`（M1）：M1-A/B/C 完成
   （`ef2f9b3`、`14f8104`、`043ba28`、`c19f7f6`）。
4. ✅ `infra/full-regression-ci`：fast/difftest/nightly 门禁脚本 + GitHub
   Actions 三 job + 幂等 QEMU patch 重放（`3f24948`）。
5. ⏭ `feature/p5b-l1-cache`，随后 `feature/p5b-l2-cache`：按 M2 的模块化边界
   实现——**下一步**。

只有前四项的退出条件满足后，P5b 才正式进入“进行中”（M1 已完成，
下一步为任务 4 `infra/full-regression-ci`，随后任务 5 P5b Cache）。

分支状态：`verify/p5a-hardening-tests` 与 `feature/p5a-arch-fixes` 尚未
合并回 `main`；合并前需按文档维护规则更新本文件阶段表、Gate 文案与回归
摘要链接。

## P6 内核锁步进展（2026-08-24，协调器内核锁步启动，卡在 seq=1794）

- 协调器多镜像加载 + bootloader 写入口（`--image2/--image3`、
  `--init-pc`、`--boot-dtb/--boot-entry`）与 `run_lockstep_step.sh`
  KERNEL=1 模式落地；QEMU 从 bootloader 0x40000000 起逐条锁步。
- 已修复 4 个真 bug：变量移位 LSLV/LSRV/ASRV/RORV、RET Xn（目标为 Rn
  非硬编码 x30）、CPACR_EL1 op2=2（S3_0_C1_C0_2）、并加 hard_ttbr1
  定向测试证明 TTBR1 映射正常。首分叉 33 → 1622 → 1794。
- 当前卡点：seq=1794 `ldr w0,[x0]`（x0=0x42400004）QEMU/DUT 读值不同；
  0x42400000 是内核页表映射的物理页，DTB 应经 memcpy 写入，但协调器
  store 过滤无命中，写源指令尚未定位（见 handoff 040 第 5–6 节）。
- 本轮全部修改未提交（工作区脏，文件清单见 handoff 040 第 8 节）；
  Gate D 上次全量 PASS（06:04 日志）在本轮基建改动前，提交前需重跑。

## P6 内核锁步进展（2026-08-24，713k 全绿，3 个缺口修复）

- DTB 一致性：QEMU `-dtb` FDT 修改非幂等 → 改用 QEMU 生成 FDT
  （`dtb-randomness=off` + `-append`），协调器用 pmemsave 导出版本；
  实证两侧 VA 0x42400000 均映射 PA 0x44000000（翻译一致）。
- 修复 3 个真实指令缺口：LDR/STR 单寄存器 pre/post-index（wb3 写回）、
  DCZID_EL0（S3_3_C0_C0_7，=4）、dc zva（核心维护状态机 8×8B 清零写）。
- 内核锁步从 seq=1794 推进到 **713k 条全绿**（60s 脚本超时截断，非失败）。
- 测试：hard_postpre 定向（70 条，base+cache 全绿）、check-encoders 73
  条、make test P0、M2-4b 全量 base+cache 26 组 PASS；Gate D 全量回归
  提交前重跑中（日志 build/logs/gate_d_p6_postpre_*）。
- 未提交；文档：ROADMAP/PROJECT_STATUS/ISA_SCOPE/handoff 041 已更新。

## P1 批量 trace difftest（2026-08-24，gzip + 切片 + 回放）

- trace 输出改 gzip 压缩，行内补 exc/mon 字段；`tail=N` 只保留末尾
  N 条；read_reg64 复用缓冲（长跑内存/GC 优化）。
- 协调器 `--trace` 离线回放（不跑 QEMU）+ `--skip` 切片快进；新增
  `scripts/trace_slice.py` 切片工具。
- QEMU `tb-size=64` 限制 TCG 缓存：长跑锁步 QEMU RSS 8.4GB → 133MB；
  协调器镜像加载 ~25s，脚本 socket 等待加长到 60s。
- 验证：hard_postpre gzip trace 回放 PASS、切片 [30,80)+--skip 30
  PASS、内核锁步 200k PASS。trace 资产建议 release/LFS 管理 + 大小
  限制（见 handoff 042）。

## 文档维护规则

- 本文在每个 milestone 合并时更新基线提交、阶段表、实跑命令和未关闭风险。
- `ROADMAP.md` 只表达长期阶段门，`DEVELOPMENT_PLAN.md` 记录任务分解，
  `ISA_SCOPE.md` 是唯一 ISA 支持矩阵，`handoffs/` 只保留历史交接，不作为
  当前状态来源。
- “已实现”至少表示 RTL、定向测试和必要文档存在；“Gate 通过”还必须有
  QEMU/参考模型回归、CI 记录和已知限制。实验性实现不得直接标为 Gate 完成。

## 当前快照（2026-08-25，Linux lite 异步线）

- 工作分支为 `feature/p6-system-reg-shim`；主线从
  `build/difftest/linux-timer-irq-3-20260825/diff-999999` 恢复后已额外
  逐指令锁步通过 1,000,000 条；随后从 debug-monitor 初始化前的
  checkpoint 重跑 500,000 条也通过。`MSR DAIF` 解屏蔽后的 IRQ 同拍
  提交已修复，并从该断点前 checkpoint 再通过 500,000 条；最新链位于
  `build/tmp/linux-main-irq-daif-20260825/chain/`。旧 `SMULH` 失败现场
  不计入通过数；
- 新增 Linux lite 构建 fragment、静态 `/init`、独立 Image/initramfs 和
  `INITRD`/boot 地址参数；构建产物优先写 `build/tmp`，主线 `/tmp/Image-t80000`
  不改写；
- lite 已通过 bootloader、MMU enable 和前 **12,500,000** 条逐指令锁步
  （含每 100k 压缩 checkpoint）。差分 checkpoint 模式已改为导出链私有、与
  `memory-backend` machine 完全一致的 FDT，关闭了约 130k 的 DTB 读值假
  分歧。原
  seq=1573 的 `MSR SCTLR_EL1` fault 已定位为 T0SZ/T1SZ=25 时错误地从
  L0 开始 PTW；RTL 现按输入 VA 宽度选择起始级别，并以 TTBR0/TTBR1
  39 位定向锁步验证。Gate E 仍未完成；权威记录见 handoff 085；
- 资源规划器本地 50% 上限实测 5 个可立即使用 slot，main+lite 各占一个后，
  约 3 个 slot 可用于短测试；禁止把单核 QEMU/Verilator 误扩展为多核进程。
- 临时目录策略已统一：Linux lite、trace 反汇编、QEMU patch replay 和探针
  socket 默认使用 `build/tmp`（可通过 `LCVEX_TMP_DIR` 覆盖）；不再新增受限
  `/tmp` 大文件，历史主线输入 `/tmp/Image-t80000` 保持只读兼容。
