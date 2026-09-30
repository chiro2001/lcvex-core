# LCVEX Linux 启动计划：仿真、Flash 镜像与真板

日期：2026-09-27。状态：**仅规划，尚未开始本计划的实现、构建或板测**。
基线：B25 CoreMark 集成分支 `batch/T-20260920-039-b25-post-bringup`，
`ffa75333fc709cc0505d8eb7e77dce043a029834`。规划任务：T-20260927-001。

## 1. 目标与执行方式

让我们的 AArch64 CPU 在 Catapult A10 上从 Flash 自启动 Linux，进入用户态，
通过板载 JTAG-UART 输入命令并读到结果。默认保持单核、25 MHz、128 MiB DDR
可见范围，先用已经验证过的 Linux 6.6 lite 软件路线；首次启动不以追频、全功能
发行版、网络、块设备、多核、完整 FP/NEON 或长时间压力测试为前提。

分两次达成有用结果：先在易失 SOF + DDR 镜像下启动并交互，再将相同软件固化到
EPCQL，完成真正断电上电启动。Flash 镜像工具和加载器可与平台接线并行开发；
如果现有 Flash 路径更快，也可直接先跑 Flash 启动，不强制开发两套下载器。

本计划中的地址、任务拆分、超时和执行顺序是默认建议。执行者可按实测调整并在
当次记录中简述理由，不为常规调整再建审批、复审或一串辅助任务。只有出现新的
功能问题才增加对应验证；既有结论不因文档、文件名或包装脚本变化而全部重跑。
本轮只把计划落盘，不派发实施任务。

## 2. 已有成果和真实缺口

| 项目 | 已有事实 | 本轮需要补齐 |
| --- | --- | --- |
| 核心 Linux 能力 | T-20260826-044 在 `b2568a5` 上完成 lite no-FP fresh-root 35M 严格锁步，进入 `/init ready`；main 仅有 early-boot 证据 | 把现有能力带到当前 Catapult 综合顶层；历史锁步不等于当前真板 Linux 已通过 |
| 真板 CPU | T-053：24 项 microbench 与 300 次 CoreMark 通过，25 MHz，64 KiB BRAM | 从 DDR 执行内核，覆盖实际页表、Cache、异常和外设 |
| DDR | T-041：校准稍后完成后，`m` 返回 `DDR-OK` | 有限地址/数据模式、跨缓存行和页边界读写；DDR 取指及 Cache 开启后的读写 |
| Timer/GIC | `tb/sv/lcvex_soc_tb.sv` 已接 GIC 与 Timer；板级 `rtl/lcvex_catapult_soc_top.sv` 的核心 `.irq(1'b0)` | 在可综合板级 SoC 接 GIC、PPI 和 UART SPI；复用现有 RTL |
| 硬件时间 | `rtl/lcvex_core.sv` 的计数以退休指令和 WFI 仿真推进；`lcvex_pkg.sv` 报告 1 GHz | 板级改用持续运行的真实时钟计数，CNTFRQ 与频率匹配；保留锁步模式 |
| UART | 板级 `0x09000000/+4` 是 Altera JTAG-UART，已有收发和背压修复；历史 Linux-lite 是 PL011 | 使用匹配的内核驱动、DTB、early console 和 RX 中断，不能把同一地址误认成 PL011 |
| Flash | EPCQL1024 IP/CSR 已在工程；MEM 仅保留 4 KiB 地址名，未路由，顶层 `epcq_avl_mem_read=0` | 接完整 Flash 只读数据窗口、AArch64 BRAM loader、镜像布局与 JIC 打包 |
| 用户态 | `baremetal/linux-lite/init.S` 只输出标记并循环等待 | 加整数指令版本的交互 `/init`，随后视 ABI 支持加入静态 BusyBox |

参考工程 `/home/chiro/projects/mycpu/a10-linux-riscv` 当前为 `b2ffcc9`；其 README
记录 Flash → DDR → OpenSBI → Linux → BusyBox shell 成功。既有 GamePC 调查已定位
`D:\Projects\fpga-altra\a10-linux-riscv\build\console_probe.txt`、`console_tx.txt`
等成功串口记录。本轮未重新连接 GamePC，也未重新验证参考板卡。

## 3. 最小 Linux 板级平台

### 3.1 内存、加载位置与 ARM64 入口

继续使用 BRAM `[0, 0x10000)` 和 DDR `[0x40000000, 0x48000000)`。
首版保留内嵌 initramfs，减少独立搬运段；DTB 可先放 `0x47000000` 附近的独立
对齐空间，最终按镜像尺寸检查。内核加载地址读取 ARM64 Image 头部的 `text_offset`、
`image_size` 和标志后确定；T-044 lite 曾使用 `0x40200000`，旧 main 则用
`0x40080000`，不能混用或继续靠手改 Image 头部凑地址。

BRAM loader 负责等待真实 `cal_ready`、复制镜像、检查复制结果并跳转。等待上限按
真实时钟计时且可配置，校准失败或超时保留诊断入口；现有 256 次状态轮询不足以
作为 Linux DDR 就绪判据。旧 `DDR-FAIL` 字符串不替代当前校准状态和实际读写结果。

按所用内核 `Documentation/arch/arm64/booting.rst` 实现入口：非安全 EL1、MMU
关闭、D-cache 状态符合入口要求，写入的代码对 I-cache 可见；必要的 clean/invalidate、
DSB/ISB 完成后，`x0=DTB`、`x1=x2=x3=0`，屏蔽中断并跳至 Image 入口。
Image、DTB、可选外置 initramfs、loader 工作区及保留区必须不重叠。不能把 initramfs
仅拷到任意 DDR 地址却漏掉 DTB 的 initrd 描述。

不引入 OpenSBI。单核首启可直接进入 EL1，不把 U-Boot、TF-A、EL2/EL3 或完整 PSCI
设为前置条件；板级 DTB 不声明不存在的 PSCI HVC 服务。关机/重启服务可后补。

### 3.2 Timer、GIC 与 UART

- 增加显式板级计时模式/参数：25 MHz 域每拍推进 64 位计数，访存停顿及 WFI 期间
  继续计时，`CNTFRQ_EL0=25000000`；若选独立分频计数域，按实际频率报告。
  不只修改频率常量而保留退休计数。已有 QEMU `-icount` 模式继续供严格锁步使用。
  计数器是自主硬件时间；TVAL/CVAL/CTL 等软件状态仍在 commit 更新，说明 reset、
  访问权限和中断触发时机。
- 在板级接现有 `lcvex_gic`，复用 GICD `0x08000000`、GICC `0x08010000`；物理
  Timer 接 INTID 30、虚拟 Timer 接 INTID 27。DTS 的 PPI 编号相对 16，不能直接把
  INTID 填入 PPI 字段。板上以实际 EL1 内核选择的 Timer 通路为准。
- 现有 GIC 只有两个 `level_ppi` 输入；补一个最小可扩展 SPI 电平入口，把 JTAG-UART
  IRQ 接入，例如 INTID 33（DTS SPI 1，最终统一约定）。验证确认/EOI 后仍有数据时
  会再次触发，避免 shell 能显示却收不到输入。
- 首选保留现有 JTAG-UART 硬件，Linux 启用 `CONFIG_SERIAL_ALTERA_JTAGUART` 与
  console，DT 使用该内核支持的 compatible、DATA `+0`/CONTROL `+4`、正确 IRQ，
  `console=ttyJ0`。按 Linux 6.6 驱动源码确认 earlycon 支持；若缺少，补最小 polling
  earlycon。初期可保留 `keep_bootcon` 诊断切换，最终确认正式 tty 收发后再去掉。
- `lcvex_pl011` 桥接 JTAG 字节流作为备选，只在复用旧软件确实更省工作时选择，
  不同时维护两个板级控制台架构。无论选哪条，DTS、软件和 RTL 寄存器语义必须一致。

### 3.3 DTB、内核与 no-FP 边界

板级 DTS 只描述 CPU0、实际 DDR、GIC、Timer、JTAG-UART 和 `/chosen`；去掉仅存在
于 QEMU/C++ 模型的 PL031、fw_cfg、virtio、PCI 等设备。采用内核已有稳定源码和
配置构建入口，新增板级 fragment/DTS，不在 bring-up 中顺便升级工具链或内核。

第一步沿用可运行 no-FP 内核与无 libc `/init`；把 `/init` 扩成仅用 syscalls 的
小交互程序，至少支持 `help`、`echo`、计时/休眠检查，并正确打开控制台和处理换行。
这已经满足 Linux 用户态串口交互目标。它与 BusyBox shell 分别记录。

若要 BusyBox，先核实实际 AArch64 工具链、libc、启动代码和汇编实现是否依赖
FP/ASIMD；仅给应用加 `-mgeneral-regs-only` 不能保证链接后所有代码无 SIMD。
可构建匹配的整数用户态，或转到 full-FP profile 后再运行常规静态 BusyBox。
不把“移植 soft-float libc”作为默认新项目，也不以 no-FP 板测宣称完整 ARM64 ABI。

## 4. 分阶段推进与最低完成判据

| 阶段 | 工作与产物 | 足够继续推进的结果 |
| --- | --- | --- |
| L1 软件与板级接口 | lite Image、板级 DTS/DTB、交互 init、地址/计时/IRQ 配置；平台接线并行推进 | 镜像布局成立；可用 QEMU 验证用户态逻辑，板级 UART 差异明确 |
| L2 板级 SoC 仿真 | 可综合 Catapult 顶层 + DDR/Flash/JTAG-UART 行为模型；从 BRAM reset 开始 | 内核日志 → MMU/IRQ → `Run /init` → 用户态标记，注入命令收到确定回复 |
| L3 易失真板启动 | 一版 25 MHz SOF；小 DDR 诊断，然后加载同一 Image/DTB | 真板串口到 `/init` 并完成命令收发；一次 `sleep`/计时操作后仍能交互 |
| L4 Flash 镜像与启动 | BRAM Flash loader、payload、relative HEX、COF、JIC、简短 manifest | Flash 复制到 DDR 后启动同一内核；Flash 读回/复制校验无错 |
| L5 冷启动收口 | 保存恢复用参考 JIC/软件后写目标 Flash，完成真实断电再上电 | 没有主机下载内核/SOF仍启动 LCVEX Linux，JTAG 仅充当终端，用户态交互通过 |

L1 的软件构建和 L4 的打包工具可以前置并行；L2 允许先预装 DDR 缩短首启定位，
随后补一个从 BRAM loader 经 Flash 模型完整复制的启动。两者可共享同一 testbench，
不要求每次修改都跑两轮完整 Linux。成功日志作为日后最短复现入口。

### 4.1 仿真怎么跑，怎么避免长跑变成前置障碍

复用 `scripts/build-linux-lite.sh`、已有 no-FP 锁步入口和 SoC testbench。现有 lite
构建脚本固定使用 `baremetal/linux-lite/init.S`，实现时为板级 init/fragment 增加实际
接线的参数或独立入口，不能设置未接线环境变量后声称已经换了用户态。

以板级 SoC 的 Verilator 自由运行作为启动主验证，DDR 使用行为模型模拟真实握手、
延迟和实际 Cache/AXI 路径；不仿真完整 DDR PHY。UART 使用已修正的厂商时序等价
模型与有限 FIFO 背压。检查 DUT 串口、异常和必要的 commit 观察点，不拿 QEMU
日志代替 DUT 已启动。QEMU virt 的 PL011 镜像可以验证软件逻辑，但不能证明板级
JTAG-UART、Flash、EMIF 或 IRQ 接线正确。

架构/指令问题用已有定向 QEMU 锁步缩小失败点；只有修改了相关语义才复跑受影响
项目。板级真实时钟模式与 `-icount` 时间不同，不强行要求全程 Timer 数值逐条相等，
也不关闭已有严格锁步比较来制造通过。可保留有价值的失败附近 checkpoint，
不默认每 500k 指令生成整套 RAM/trace。

默认关闭全量波形和逐指令日志，保留阶段标记、最近提交环和首次异常。超时根据
模拟周期与已测吞吐设置；25 MHz 真板启动慢，不能沿用裸机几秒钟的超时。阶段推进
就继续运行，长时间无新标记时读取 PC/异常/Timer/IRQ 状态，避免每次从头重跑。

### 4.2 首板 DDR 加载与快速迭代

优先给 BRAM monitor 增加简单的分块 DDR 下载命令：地址、长度、序号、CRC 与 ACK，
复用 JTAG-UART，保持 WSPACE 背压。先传小段测量吞吐，再决定是否用它搬运几 MiB
内核；下载耗时不合适就改用已存在且实测可用的 JTAG-to-Avalon 通道，或提前使用
Flash payload。不能假设当前工程已经有任意 JTAG 内存写功能。

首板只做足以支撑 Linux 的 DDR 检查：覆盖将要放 Image/DTB 的区域，跨行/页地址
模式，先 uncached 再 Cache，最后从 DDR 执行小段代码。无需先完成整片 DDR March
压力和长跑。镜像搬入 DDR 后做长度/CRC 校验和必要缓存维护，再跳内核。

RTL 接线稳定后一次生成 SOF；软件/DTB 改动优先重新下载 DDR，避免整套 Quartus。
若仅变更 BRAM MIF，工具和当前数据库确实支持时可采用 memory-update + assembler，
并确认生成 SOF 含新 payload；否则正常重新构建，不复用身份不明的旧数据库。

## 5. Flash 方案

目标链：`EPCQL 配置区 → FPGA 配置/BRAM loader → 等 DDR 校准 → Flash 复制
Image/DTB → EL1 Linux → initramfs /init → JTAG-UART 交互`。

### 5.1 数据通路与镜像格式

复用现有 EPCQL1024 IP。新增 CPU 可读 Flash aperture；建议初值为
`[0x10000000, 0x18000000)`，映射 128 MiB Flash，避开 DDR/GIC/已有外设。
这是待实现的板级地址选择，不是已有接口；实现时同时更新路由、MMU/MMIO 分类、
Cache bypass 和 loader 常量。当前 `0x09002000` 的 4 KiB 占位窗口不能直接装下
内核。也可选择 CSR 分页窗口，但只有它确实减少工作时采用。

桥处理 CPU 字节地址到 EPCQ 32 位 word 地址转换，正确保持 waitrequest 请求并
等待 readdatavalid；关注末尾不足整 word、读返回通道和 timeout。首版运行时只读，
Flash 擦写由 Quartus Programmer 完成，避免增加 Linux MTD 驱动依赖。

采用一个小 descriptor：magic/version、段数、内核 entry、DTB 地址、每段
`flash_offset / load_address / length / CRC32`。内存地址和入口建议用 64 位字段；
版本与字段宽度明确，不直接执行 RISC-V 的 32 位 descriptor/boot 汇编。
同一布局文件生成 loader 常量和主机打包数据，生成器检查范围、溢出、对齐、段重叠
与容量；loader 检查格式、目标 DDR 范围和 CRC，失败留在 monitor。

### 5.2 SOF / payload / HEX / JIC

产物只需以下集合：

| 产物 | 用途 |
| --- | --- |
| `boot.elf/bin/mif` 与 `lcvex_linux.sof` | BRAM loader 和 FPGA 配置 |
| `Image`、板级 `*.dtb`、可选 `initramfs` | AArch64 Linux 软件输入 |
| `flash_data.bin`、`flash_data.hex` | descriptor + 软件段；HEX 使用 blob-relative 地址 |
| `linux_flash.cof`、`lcvex_linux.jic`、conversion map | EPCQL1024、10AX115N4 的编程包和实际地址分布 |
| `manifest.json` | source SHA、工具版本、构建参数、各段地址/长度及文件 SHA-256 |

参考流程是 `gen_flash_data.py → bin2ihex.py → quartus_cpf -c <cof>`；我们实现
AArch64 版本并复用机制。约定：descriptor 内源位置为 **Flash 绝对字节偏移**；
BIN/HEX 内位置相对 payload 起点；COF 对 relative HEX **只加一次** payload 偏移。
CPU Flash aperture 地址、Flash 芯片偏移、BIN 内偏移、DDR 目的地址分开记录。

参考 COF 的 `hex_offset=0x00100000` 不能照抄。先为 FPGA 配置预留保守空间，
选择扇区对齐 payload 起点（例如 `0x04000000` 仅作为候选）；按本次 conversion map
核实配置实际范围、payload 大小与 128 MiB 总容量。SOF 文件大小也不能直接当作配置
在 Flash 中的长度。若不容纳就调整布局/镜像大小，重新生成相关 loader 与包。
生成器以实际打开的 Image 路径为准；参考脚本 `FLASH_IMAGE_NAME` 仅参与打印而
读文件仍写死的做法不继承。保留有效的字节序转换和校验，不盲拷 COF 的 ignore-ID/
ignore-CONF_DONE 选项；如果器件确有需要，依据实际 programmer 情况设置。

### 5.3 烧录与冷启动

已有成功编程路径是 GamePC Quartus 21.4、自包含的自建 15 MHz server、端口 1310，
programmer cable 为 `MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310`。
参考 EPCQL 步骤为所需 helper SFL → JIC 写入/校验；按实际 Programmer 链确定 helper
是否由工具自动加载。烧写完成后释放本任务占用的 server，再打开标准 MPSSE 终端：

```powershell
& 'D:\Software\intelFPGA_pro\21.4\quartus\bin64\nios2-terminal.exe' -c 'JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]' -d 1 -i 0
```

先用 SOF 启动 loader 读取刚写入 payload，可以定位 Flash 数据问题；这只证明热启动
路径。最终需真实断电上电，让配置与软件均来自 Flash，再读取独特的 LCVEX build ID、
内核日志和命令回复。JIC 写入成功和重新下载 SOF成功均不能替代此步。

当前 Flash 中是可工作的 VexRiscv 参考。首次覆盖前保留能够恢复其配置及软件区的
参考 JIC/完整包和哈希；只有 golden SOF 无法恢复被覆盖的 Linux payload。准备好
具体新镜像、布局、恢复包后，在真正需要 Flash 写擦/断电操作时一次性确认尚未覆盖的
操作授权；历史 Quartus/JTAG 易失配置授权继续有效，不重新逐步索要。
本次“仅规划”不触发任何烧录或授权询问。

## 6. 并行分工与精简验证

开始实施时按当时资源登记 2–3 个完整任务包即可，不预先登记大量等待任务：

| 工作包 | 主要职责/写集 | 汇合依赖 |
| --- | --- | --- |
| A 平台启动 | Timer 双模式、GIC/PPI/SPI、板级路由、DDR/IRQ 定向用例；核心/公共顶层由此 owner 串行处理 | 与 B 约定地址/频率/IRQ，与 C 约定 Flash 接口 |
| B 软件和仿真 | 内核 fragment、DTS、用户态、板级 Linux testbench/运行入口 | 可先做镜像与用户态，待 A 接线后联合启动 |
| C 加载和 Flash | BRAM loader、DDR 下载、Flash descriptor/打包/COF；不与 A 并行写共享顶层 | 包装工具先做，Flash RTL 接线由 A 集成 |

本地联合仿真与 GamePC Quartus 为两个资源槽，输入冻结后可重叠；等待时继续软件和
下一步诊断准备。所有 heavy 作业使用 `/home/chiro/projects/.resource-locks/resource-lock`
取得对应 `local` 或 `gamepc`；拿锁后按实际可用资源选并行度，不沿用固定 16 GiB/
50% 上限。耗时任务由事件报告完成，外部进度按约定低频查看，避免密集轮询。
未来如派子 Agent，省略模型名，不使用 Sol；当前任务由主 Agent 完成。

验证收敛为“受影响定向用例 + 一次合并后的启动”，Quartus 对同一个候选统一完成
synthesis/fit/STA/assembler，不人为拆成多个审批任务。真实 25 MHz 及 DDR/CDC 时序
仍需成立；核心架构修改保留受影响的严格差分；正式进入 main 仍遵守仓库 Gate D
规则，但不把每次软件/DTB 调整都变成完整 Gate D/35M 锁步/多轮审查。

现有 `board_runner` 针对一次 candidate/terminal/golden 并且拒绝 JIC，不能直接用于
本路线。实施时复用其中已验证的编程/终端传输，增加简单 Linux session/Flash 入口，
保留实际错误返回。允许一个调试窗口内多条命令、多个软件镜像；只在错误、资源
交还要求或用户指定时恢复参考配置，不再每次成功命令后强制 golden 切换。
原 T-053 的固定合同和证据保持原义，新计划不通过伪装 task ID 绕过旧校验器。

每个里程碑保留一份简短结果、确切命令、source/镜像哈希、原始串口日志和失败原因。
不需要独立“预审→复审→审计→再复验”链、全部历史 warning 清零或与历史 SOF/JIC
字节相同。软件确定性产物可比较哈希，重新布局的 FPGA 镜像按输入、时序和功能判断。

## 7. 历史坑的直接用法

- `data==ctrl`、`bootconsole disabled`：先对照实际寄存器访问和 IRQ，再看内核 tty
  名字与 DTB。保留 DATA/CONTROL 地址分离测试；不照搬 RISC-V `[13]` workaround，
  也不靠强行忽略 WSPACE 掩盖错误。早期日志出现不代表正式 tty 已可交互。
- 本项目已经修复 M20K 同步读取错拍、UART RX 时序、logical-immediate 综合分歧与
  TX 背压。复用修复后的源和测试；底层协议变化才增加相应回归。
- 旧参考 `Loading final database` 曾让改动没有进入实际镜像。每个 RTL 候选使用
  清楚的构建目录和输入，保留 build ID/MIF；确认是旧镜像时重建相应候选即可。
- 编程与 console 使用不同 cable 路径；`Can't find JTAG Server` 先查配置/工作目录/
  端口，别先重烧 Flash。只结束自己启动的 server，不使用参考脚本按名称杀全部进程。
- JIC 历史写入约 16–17 分钟，SOF约几十秒；时间是估计，不是固定超时合同。
  软件迭代尽量走 DDR 下载，避免把每次诊断都变成 Flash 擦写。
- Windows ConHost 的第 120 列 CSI 重绘曾导致完整 CoreMark 输出被外层误判超时。
  Linux 终端保留原始流，解析可处理已知控制序列；先看原始输出再判断 CPU 挂死。
- 参考 `docs/67–69` 记录的是中间失败假说，后续 README/修复提交和成功串口更晚。
  参考方案的成功不能替代 AArch64 平台验证，也不能把中间假说当作当前硬件定论。

首个执行波次建议只做：**A 的 Timer/GIC/UART 接线、B 的最小板级 Linux/交互 init、
C 的 loader/镜像打包**。共同目标是可综合 SoC 仿真到交互用户态，随后进入真板调试；
不在这些工作之前另开一轮广泛审核。

## 8. 定位资料

- 当前成功板测：[T-053 handoff](handoffs/T-20260920-053-b25-coremark-uart-board-result.md)、
  [T-041 DDR](handoffs/T-20260920-041-b25-ddr-m-control.md)。
- Linux 历史事实：[T-20260826-044 evidence](tasks/evidence/T-20260826-044.json)、
  [Linux 架构计划](LINUX_PLAN.md)（保留的历史地址/平台不能直接当板级配置）。
- 平台来源及真板参考日志位置：[B25 计划 §5](BRINGUP_25MHZ_PLAN.md)。
- 本机参考：`../a10-linux-riscv/README.md`、`docs/04-交接-软件链QEMU门全绿与cleanroom软件复现-20260826.md`、
  `docs/67–69`、`scripts/gen_flash_data.py`、`scripts/bin2ihex.py`、
  `hw/quartus/vex_soc_ddr/output_file.cof`、`sw/boot/boot_flash.S`。
- GamePC 参考：`D:\Projects\fpga-altra\a10-linux-riscv`；实施时只取与当前问题有关的
  成功日志/脚本，不重新审查整个参考工程。
