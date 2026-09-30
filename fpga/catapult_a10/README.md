# Catapult v3 / Arria 10 平台输入与真实 full flow（B0 / T-064）

本目录是 Microsoft Catapult v3 / Mg Catapult 的最小平台输入包，不是可独立
综合的 LCVEX 工程。它只为后续平台任务提供可审计的 Qsys/IP、Flash、JTAG-
UART、时钟、复位和 DDR 引脚边界。T-20260828-064 在此基础上补齐 SFL/EPCQ
生成输入并完成了真实 Quartus full flow / STA。

## 当前 Linux 启动覆盖层（2026-09-30）

T-20260928-002 的 Quartus 候选保持 100 MHz 板钟经真实四分频得到 25 MHz，
并让 BRAM 从独立的 `boot/build/linux-loader/linux_loader.mif` 启动 AArch64
loader。仿真使用同一构建产生的 `linux_loader.hex`。loader 等待 DDR 校准，
从 EPCQL 只读窗口取回 payload、校验 descriptor/segment CRC，再将内核和 DTB
搬入 DDR。`boot/build/boot.mif` 的旧 B25 monitor 仍保留为历史/恢复构建输入，
但不再是本 Linux candidate 的 Quartus `MIF_FILE`。

loader ELF/BIN/HEX/MIF 由 `boot/build_linux_loader.sh` 生成，产物在 ignored
`boot/build/linux-loader/`；入 fresh GamePC root 时必须复制并哈希这组输出，
并确认 Quartus 消费的 MIF 与 manifest 一致。当前候选已有 128 MiB 完整 SoC
Linux 仿真及 `/init` help/echo 结果；本次选定的 Linux MIF/QSF 尚未完成 fresh
Quartus synthesis/fitter/STA/assembler，也未上板配置或写入 Flash。

## 冻结事实

| 项目 | 输入 |
| --- | --- |
| FPGA | Arria 10 10AX115N4F40E3SG |
| 工具 | Quartus Prime Pro 21.4 Build 67 |
| 时钟 | 板级 100 MHz；B25逻辑域25 MHz；DDR参考/用户域保持266.667 MHz |
| DDR4 | 72-bit DQ、9-bit DQS、512-bit Avalon-MM EMIF 用户口 |
| Flash | EPCQL1024、Active Serial x4、100 MHz |
| 控制台 | Altera Avalon JTAG-UART，经 JTAG 观测 |
| 首轮窗口 | 0x40000000..0x48000000（128 MiB，计划约束） |

Qsys 黑盒快照包含 EMIF 用户时钟、用户复位、local_cal_success、
local_cal_fail 和 512-bit Avalon-MM 端口。B0 不实现 AXI、Cache、SoC 或
任何 CPU/软件接线。

## 白名单和哈希

platform_manifest.json 是平台事实、目标路径和目标 SHA-256 的权威清单。
source.lock 记录一次性来源路径、来源 SHA-256、来源字节数、目标路径和角色。
SHA256SUMS 是在本目录导入完成后重新计算的目标 payload 哈希，不能替代来源
锁，也没有从 sibling 的 golden.sha256 复制。

T-20260831-002 已按 `a10-linux-riscv@3db828e74651fda377a33d84f2a2ca0e69901d72`
重锁 50 个来源 blob，并重新计算当前 50 个 target payload 的 hash/字节数。
来源 hash 是 Git raw blob（不经过工作树换行转换）；因此生成文件的 source
字节数可以与本地导入 target 不同。`check_platform.py` 默认只做离线检查，不会
访问 sibling 参考仓；需要把来源仓纳入 provenance gate 时，必须显式传入 clean
worktree 和完整 commit：

    python3 fpga/catapult_a10/tools/check_platform.py
    python3 fpga/catapult_a10/tools/check_platform.py \
      --strict-source \
      --source-repo /home/chiro/projects/a10-linux-riscv \
      --source-commit 3db828e74651fda377a33d84f2a2ca0e69901d72

strict-source 模式只读执行 `git status`、HEAD/commit 解析和 `git cat-file blob`；
它要求来源仓 clean、HEAD 等于指定 commit，并逐项校验 source.lock/manifest 的
50 个 source hash 与字节数。两种模式都会拒绝重复项、缺失项、绝对路径和 `..`
路径穿越，并闭合 manifest、SHA256SUMS、source.lock 与实际 target 文件集。
详见 [`docs/FPGA_A10_PROVENANCE_RELOCK.md`](../../docs/FPGA_A10_PROVENANCE_RELOCK.md)。

收编范围：

- quartus/：无顶层实体和设计 RTL 的器件、配置、时钟/DDR 引脚约束片段；
- qsys/ddr4_bot/：Qsys 设计、四个 .ip 输入和 Qsys 接口黑盒快照；
- flash/sfl/：SFL QIP、接口快照、EPCQ/clk/rst 组件输入与完整生成源；
- jtag_uart/：JTAG-UART wrapper 与 21.4 生成实现。

PoC 的 CPU、RISC-V 软件、SoC 顶层、通用总线/缓存、32-to-512 bridge、
Linux/OpenSBI、Quartus 数据库、SOF/JIC、Flash payload 和板测日志均未收编。
生成黑盒/QIP 是平台输入快照；T-064 已用真实 full flow 验证其可编译，
但本目录本身不包含编译数据库或 SOF。

## speed grade 不一致

原始输入必须保留以下矛盾，不能在 B0 中靠文本替换“修正”：

| 输入 | 字段 | 值 |
| --- | --- | --- |
| qsys/ddr4_bot/Qsys.qsys | Qsys system deviceSpeedGrade | 2 |
| qsys/ddr4_bot/ip/Qsys/Qsys_clk_*.ip | clock IP deviceSpeedGrade | 2 |
| qsys/ddr4_bot/ip/Qsys/Qsys_emif_bot.ip | EMIF deviceSpeedGrade 与 SYS_INFO_DEVICE_SPEEDGRADE | 3 |
| flash/sfl/ip/sfl_sys/epcq.ip | EPCQ deviceSpeedGrade | 3 |
| quartus/catapult_a10.qsf | 实际器件 | 10AX115N4F40E3SG（E3） |

Qsys/clock/reset 中的 2 是组件生成上下文元数据，EMIF/EPCQ 中的 3 是其
器件/PHY 元数据；它们不是可直接等同的 STA 结论。最终有效器件由 Quartus
DEVICE 选择，EMIF PHY/校准又依赖 IP 参数。因此 manifest 将此项标记为
inconsistent；必须在精确的 Quartus 21.4 环境重新生成并由后续 STA 关闭
风险，B0 不宣称时序通过。

## EPCQ 与 JTAG-UART 追溯

EPCQ 的具体输入是 flash/sfl/ip/sfl_sys/epcq.ip，其中保留
FLASH_TYPE=EPCQL1024、IO_MODE=QUAD、Arria 10 和生成版本；其生成系统由
flash/sfl/sfl_sys.qip 固化，QSF 通过 QIP_FILE 并逐项列出
flash/sfl/ip/sfl_sys/ 下 clk/rst/epcq 的生成 HDL。JTAG-UART 的具体输入是
jtag_uart_std.v 及其生成实现，QSF 逐项列出两个文件。物理 UART 引脚尚未
从输入确认，留给后续板级任务。

为 Linux `ttyJ0` 交互，本仓库对生成的 JTAG-UART HDL 保留一个有意的本地
配置差异：`fifo_AF` 的 RX IRQ 空槽阈值从上游默认 8 调为 63（64 项 FIFO），
使首个 RX 字节即可唤醒阻塞的 Linux TTY read。没有该差异时，短行 `help\r`
只有 5 字节，IRQ 要等到至少 56 字节入队才触发，导致 `/init` 虽能发送 banner
却无法接收交互命令。上游源哈希保留在 `platform_manifest.json` / `source.lock`；
目标 HDL 的新哈希、差异目的和直接回归记录在同一 manifest，并由
`check_platform.py` 与 `run_jtag_uart_vendor_timing_test.sh --focused-only` 检查。
若从 Quartus 重新生成该 IP，必须重新应用此 RX IRQ 阈值差异并复跑直接 RTL 与
Linux 集成测试。

## 来源、许可证和工具限制

一次性只读来源为 /home/chiro/projects/a10-linux-riscv，来源 commit、路径、
哈希和角色见 source.lock。目标工程的运行时和检查脚本不得读取该路径。
Intel/Altera .ip、.qsys、.qip 和生成 HDL 保留原始 Program License / FPGA
IP License 注释；使用者必须具备对应 Quartus/IP 许可。

离线检查：

    python3 fpga/catapult_a10/tools/check_platform.py
    python3 fpga/catapult_a10/tools/check_skeleton.py
    bash fpga/catapult_a10/tools/lint_platform.sh

真实再生成入口：

    fpga/catapult_a10/tools/regenerate_qsys.sh

该入口会调用 ip-generate/qsys-generate、重新写出生成文件哈希并比较 Qsys
黑盒；如果命令不存在则以 127 退出并打印缺失工具。T-064 已在远端 Windows
Quartus 21.4 主机完成真实 full flow（见下节），但 DDR March 与板测仍不在
本任务范围内。

## B0+ 可重生成工程骨架（T-20260827-062）

在 T-052 的 15-file 输入包之上，本目录新增一个可独立审计的 Quartus/Qsys
工程骨架。QPF/QSF/SDC 仍保持器件、配置、时钟和 DDR 引脚边界不变，QSF 现在
显式声明顶层实体：

- `lcvex_catapult_a10_top`（`rtl/lcvex_catapult_a10_top.sv`）：100 MHz ->
  50 MHz 逻辑域分频（SDC 锚点 `sys_clk_div2|q`）、Qsys EMIF 黑盒实例
  `emif`、JTAG-UART 与 EPCQ/SFL Avalon 从口边界（B5 接线前为 idle
  tie-off）、状态 LED 输出；
- `lcvex_catapult_a10_reset_gate`（`rtl/lcvex_catapult_a10_reset_gate.sv`）：
  逻辑域上电复位、EMIF user reset 直通、cal_success/cal_fail 三拍同步与
  sticky fail、`ddr_en` 校准门；
- `tb/sv/lcvex_catapult_a10_stub.sv`：仅离线 lint 用空接口桩，不进入 QSF；
- `tools/check_skeleton.py`：校验骨架文件哈希、QSF/SDC/顶层锚点和 Quartus
  工具缺失时的可恢复报告（默认缺工具不视为失败；`--require-quartus` 时以
  127 表示 blocked）；
- `tools/lint_platform.sh`：Verilator lint-only 入口（Verilator 缺失时以
  127 退出并打印恢复说明）；
- `skeleton_manifest.json`：骨架文件、接口边界、锚点和已知限制的权威清单。

`check_platform.py` 仍校验 T-052 包闭包；QSF/SDC 因骨架扩展改变后，其
target 哈希与 `SHA256SUMS` 已同步更新，来源锁新增 SFL 生成源条目。SFL
QIP 引用的生成源文件已随 T-064 收编为 39 个目标文件（本地 LF 规范，
远端编译使用同源 CRLF 生成物）。

## T-20260828-064 真实 full flow / STA

远端 Windows 主机（Quartus Prime Pro 21.4 Build 67）执行：

    quartus_sh --flow compile catapult_a10 -c catapult_a10

最终结果（`compile6`，2026-08-28 02:02–02:10）：

- Full Compilation: 成功，退出码 0，0 errors / 68 warnings；
- Fitter: 4,468 ALMs / 8,641 registers / 141 pins / 27 RAM blocks / 3 PLL；
- STA: 0 errors；最差 setup slack +0.220 ns（EMIF core user clock，
  Slow 900mV 100C）；最差 hold slack +0.017 ns（sys_clk_50，Fast 900mV
  0C）；recovery/removal/min-pulse 均为正；
- Fmax: sys_clk_50 213.49 MHz，clk_y3 499.25 MHz，EMIF core user clock
  283.29 MHz（Slow corner）；
- DDR report: Address/Command、DQS Gating、Read Capture、Write、
  Write Levelling 均正；Core setup +1.772 ns（Fast 900mV 0C）；
- SOF: `catapult_a10.sof`（36,842,105 B），SHA-256
  `04130f9d0cf8b42afe1fe56a428d6a6af0bdc9b510bf72fd00eccabe60896028`。

STA 备注：SDC 的用户约束先于 EMIF 生成时钟读取，不能再用
`set_clock_groups` 命名 EMIF 时钟；T-064 改为对 reset_gate 两条 CDC
同步器输入（`cal_success`、源域 sticky `cal_fail`）做寄存器级
`set_false_path`，并由真实 STA 确认时序全正。剩余 Critical Warning 均为
非时序项：CLKUSR 自动保留（100 MHz 满足 100–125 MHz 要求）、9 个无精确
位置引脚、48 个未使用 HSSI RX/TX 通道。
