# FPGA-G6-PREFLIGHT：Catapult A10 执行前只读预检

```text
task=T-20260831-001 state=review
base=fbb5d71e2430dbae3ef43490c14c2b6f5c6cda92
branch=infra/T-20260831-001-a10-execution-preflight
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-001
sent_at=2026-08-31T00:42:34+08:00 received_at=2026-08-31T00:43:39+08:00
model=gpt-5.6-luna reasoning_effort=max
```

## 结论

本预检全程只读：没有启动 Quartus compile/simulation/programming，没有停止、暂停、
降优先级或抢占任何进程，没有修改远端文件，也没有读取 license 内容。

当前机器适合保存证据、校验输入和执行小型 reduced/partition 试验；不具备安全运行
T-067 同等级真实 B5 full synthesis 的资源余量。用户侧重启后的可靠快照显示可用
物理内存约 42,515 MB、pagefile 可用 12,800 MB；理论可提交余量约 55.3 GB，仍
显著低于 T-067 历史 `quartus_syn` private-memory 峰值 75,425–77,060 MB，且还
要扣除系统/现有进程安全余量。因此：

- 真实 B5 full flow（尤其 Analysis & Synthesis）当前为 **BLOCKED**；
- reduced/partition scope 只有在输入 provenance 闭合、且先验峰值不超过约 35 GB 时
  才可 **GO**；未知峰值一律 **WAIT**；
- fit、STA、assembler、simulation、program 和 board-test 必须按阶段单作业、逐阶段
  取证，不能把 T-064/T-030 的旧 SOF/报告当作当前 candidate 结果。

## 1. 输入与 provenance 审计

### 1.1 锁定平台事实

`fpga/catapult_a10/platform_manifest.json`、`source.lock` 和 `SHA256SUMS` 声称的
平台为 Microsoft Catapult v3 / Mg Catapult、Arria 10
`10AX115N4F40E3SG`、Quartus Prime Pro 21.4 Build 67；板级输入 100 MHz，首版逻辑
域 50 MHz，DDR reference 266.667 MHz，72-bit DQ/9-bit DQS，512-bit Avalon EMIF
user interface，EPCQL1024 Active Serial x4，初始 LCVEX 窗口为
`0x40000000..0x48000000`。

Qsys 输入 `Qsys.qsys` 的 system/deviceSpeedGrade 为 2，clock/reset IP 也为 2，
EMIF 与 EPCQ IP 为 3，器件后缀为 E3；manifest 已标记
`speed_grade.status=inconsistent`。该不一致不能通过文本替换解决，必须在精确
Quartus 21.4/device 环境重新生成并用最终 STA 关闭。

### 1.2 source.lock 与锁定参考仓

参考仓 `/home/chiro/projects/a10-linux-riscv` 当前 clean，HEAD 正是
`3db828e74651fda377a33d84f2a2ca0e69901d72`。source.lock 共 50 行，映射覆盖 SFL、
DDR4 Qsys/IP、JTAG-UART 和 Quartus QPF/QSF/SDC。对该 commit 的原始 blob 逐项
SHA-256 核对结果为：27 项 raw hash 匹配，23 项不匹配；不匹配集中在 SFL 的
component/generated HDL（clk、rst、epcq 及顶层 sfl_sys 的若干 `.cmp`、`*_bb`、
`*_inst`、`synth/*.v`），不是简单 LF/CRLF 归一化即可解释。执行 full flow 前必须
由平台 owner 重新确认这些 source.lock 记录的来源快照/生成版本，不能只相信路径和
commit 字段。

当前本地 target `SHA256SUMS` 校验为 48/50 通过：

- `quartus/catapult_a10.qpf` 通过；
- `quartus/catapult_a10.qsf` 当前 SHA-256 为
  `78032dc5634dc08bf15e916fb70e9f2f6ddefd6b2dd5d59600b3c4c3a236f19d`，清单记录为
  `89ed1babd5fdde957497bb1d822cdd980cd8b16ba74ac825f061df1a8576c0fe`；
- `quartus/catapult_a10.sdc` 当前 SHA-256 为
  `caf847755a8c42f2e88ea09e434888938ad4382193400593ddcc986f26154a8c`，清单记录为
  `9072d02a79580f9344563b69a8eb36fd204834d73e73b3427b306e668a6aba87`；
- Qsys、SFL target payload 和 JTAG-UART 其余项目通过。

QSF 漂移可追溯到后续 B5/Cache 接线（当前 QSF 增加 LCVEX 源与
`lcvex_cache_data_ram.sv`）；SDC 漂移来自 AUD-04/EXT-03 CDC 约束。它们可能是
有意修改，但 manifest/SHA256SUMS 尚未同步，所以 provenance gate 当前不通过。

### 1.3 可借鉴与禁止带入的参考资产

允许借鉴锁定参考仓的：

- `hw/ip/ddr4_bot/Qsys.qsys`、EMIF IP 及其生成接口/QIP 的端口、时钟、复位、校准
  信号和哈希/provenance 组织；
- `hw/ip/sfl` 的 EPCQ/SFL QIP、clk/rst/epcq 生成源（仅在来源 hash 闭合后使用）；
- `hw/ip/jtag_uart` 生成 wrapper、Catapult pin assignments、100→50 MHz divider、
  EMIF user-clock CDC/reset gate 的设计思路；
- `hw/quartus/vex_soc_ddr/vex_soc_ddr.qsf/.sdc` 的器件/pin/时钟约束结构，作为
  对照而非直接覆盖 LCVEX 文件。

禁止带入 LCVEX 的：

- `VexRiscvAxi4Linux`/`vex_riscv_axi`、RV32IMA/Sv32、CLINT/PLIC、OpenSBI、RISC-V
  DTB、RISC-V boot/linker，以及 `C_ALIAS_ENABLE`、`FLASH_DIAG`、SignalTap 临时
  诊断宏；
- 参考仓 32-bit AXI→32-bit Avalon `axi4_to_avalon_mm`、RV32 地址 decode/boot RAM
  语义、0x80000000 DDR/0xF0000000 UART 地址图；
- 参考仓的 `async_fifo.v` mailbox/DCFIFO 选择、VexRiscv Qsys component 和
  旧调试/Flash payload。LCVEX 必须保持 AArch64、0x40000000 初始窗口、现有
  128-bit AXI4→512-bit Avalon adapter、core/L1/L2/EMIF 接口契约。

## 2. 坑点矩阵

| 项目 | 观察/历史证据 | 执行前要求 | 当前判定 |
|---|---|---|---|
| SFL 输入 | T-063 首次包缺 `flash/sfl/sfl_sys.qsys`；T-064 采用参考仓完整 39-file 生成目录；重建 qsys 曾因 EPCQ 最大输入时钟 25 MHz 校验失败 | 明确 authoritative SFL 39-file 来源、版本与 hash；QIP 和显式 generated HDL 不与同名 QSYS_FILE 混用 | WAIT |
| qsys-generate/ip-generate | 远端 `qsys-generate.exe` 可见但 `--version` 不是合法开关（exit 1）；`ip-generate.exe --version` 受 Pro `acdstest` 限制（exit 3）；历史 T-063 用 `quartus_ipgenerate.exe` | 用固定 21.4 `quartus_ipgenerate.exe`/`qsys-generate.exe` 命令并记录 exit/log/hash；不要用受限 `ip-generate` 冒充成功 | WAIT |
| 生成输入混用 | T-064 compile1 因同名 `sfl_sys` 的 QIP_FILE+QSYS_FILE 冲突失败；Qsys QIP 不是自包含 | 选择 QSYS_FILE+component IP，或 QIP_FILE+完整显式 HDL 的唯一方案；禁止同名双引用 | BLOCKED until plan |
| `alt_sld_fab`/debug fabric | T-016/T-020 fresh B5 top synthesis 在 alt_sld_fab_0 生成处 >20 min、约 21.4 GB；T-020 拷 DB 也无法 fitter | 先隔离 IP generation、关闭/固定 debug fabric 方案并留证；不复用 stale DB 绕过 elaboration | WAIT |
| 顶层/glue elaboration | T-016 SoC-only blackbox 仍在 85 s 达 31.3 GB；T-067 B5 synthesis 三次约 75–77 GB OOM | 先跑 reduced/partition top；验证 TOP_LEVEL_ENTITY、实例层级、QSF 源闭包和参数；禁止 full flow 直接试错 | BLOCKED |
| EMIF calibration/reset | Qsys 输出 `local_cal_success/fail`、`emif_usr_clk/reset_n`；平台 reset gate 为 3-stage sync + sticky fail + `ddr_en` | 先验证 cal 未完成时 CPU/请求保持 reset/block；验证 fail sticky、user reset 和 CDC recovery/removal | WAIT |
| PLL/SDC clocks | 100 MHz→50 MHz `sys_clk_div2`，DDR ref 3.750 ns；T-064 曾有 EMIF clock group 不可解析，修为 register-level false path 后正 slack | 每次生成后核对真实 hierarchy/clock names；post-fit TimeQuest 复核 guarded SDC，不能把旧 STA 数字外推 | WAIT |
| 相对路径 | QSF/SDC 使用 `../rtl`、`../../rtl`、`../qsys`、`../flash`；不同 cwd 会改变解析 | 从 QPF 所在工程目录调用；保存 resolved source list；禁止依赖 shell 当前目录偶然正确 | WAIT |
| stale db/output_files | 远端 build 现存 536 个 log/rpt/summary/SOF 类产物，T-064/T-030/T-038 混杂 | 每个 staged task 使用独立 `build/<task-id>/<stage>`；开始前列 hash/time，禁止把旧 output 当新结果 | BLOCKED until new root |
| blackbox→QDB | T-008 证明先 blackbox synth、再 `quartus_cdb --import_partition`、最后 fitter-only 可跳过 child re-synthesis；直接拷 DB 绑定原工程路径会失败 | 固定 partition 名、module signature、source/tool/device hash；导入后检查 log 无 child re-synthesis | GO only reduced |
| RISC-V/VexRiscv | 参考 top/QSF/boot 是 RV32 Linux 设计，含 CLINT/PLIC/OpenSBI/C_ALIAS | 只收编平台 IP/pin/clock/reset 证据；禁止把 CPU、软件、地址图、32-bit bridge 带入 LCVEX | HARD BLOCK |
| device identity | `jtagconfig` 当前可见设备字符串为 `10AT115S(1|2)`，而 QSF DEVICE 为 `10AX115N4F40E3SG` | programming 前必须人工确认 cable/device/package 对应关系，冻结 chain 文本/hash | WAIT |

## 3. 远端只读快照（2026-08-31）

### 3.1 主机、资源和进程

远端 `192.168.101.5`（hostname `GamePC`）只读快照：

- OS boot：`2026-08-28T19:18:29.5000000`（主机本地时区）；AMD Ryzen 9 9900X
  12-Core Processor，12 cores/24 logical processors，采样 load `71%`；
- physical memory：total 63,092.3 MB（约 61.6 GiB），free 43,121.0 MB；
- pagefile：`C:\pagefile.sys` allocated 9,216 MB，current 792 MB，peak 7,197 MB，
  当前可用约 8,424 MB；
- D: volume：675.26 GB，总可用 102.68 GB，已用 572.58 GB；
- `quartus*`/`qsys*`/`vsim*`/`questa*`/`java*` 进程数为 **0**，因此未检测到正在
  执行的 compile/simulation/programming；没有任何进程被改变；
- 高内存进程前列：`vmmemWSL` PID 45176，working set 2,917.3 MB/private
  2,923.4 MB；其余最高为 Memory Compression 529.3 MB、QQ 481.1 MB、
  steamwebhelper 430 MB。高内存进程采样共 20 项，未发现 EDA 进程。

重启前快照为 physical free 43,121.0 MB/pagefile available 8,424 MB；用户重启后
快照为 physical free 42,514.7 MB/pagefile available 12,800 MB。后者理论可提交约
55.3 GB，但不能把它全部分配给 Quartus；现有进程和 OS 至少保留 8 GB 是本预检的
安全假设，仍明显低于 T-067 的 75–77 GB 峰值。

### 3.2 工具、工程和链路

只读工具探测结果：

- `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_sh.exe`、`quartus_syn`、
  `quartus_fit`、`quartus_sta`、`quartus_asm`、`quartus_ipgenerate`、`jtagconfig`
  和 `quartus_pgm` 文件存在；`quartus_sh --version` exit 0，
  `Quartus Prime Shell Version 21.4.0 Build 67 12/06/2021 SC Pro Edition`；
- `D:\Software\intelFPGA_pro\21.4\qsys\bin\qsys-generate.exe` 与
  `ip-generate.exe` 存在；qsys `--version` exit 1（不支持该开关），ip-generate
  `--version` exit 3（仅 acdstest resource）；历史证据确认应使用
  `quartus_ipgenerate.exe`；
- `D:\Projects\fpga-altra\lcvex` 存在，license path 仅 `Test-Path` 为 true，未读
  内容；远端 `skeleton_manifest.json` 缺失；
- 远端平台 key hash：QSF=`89ed1bab…`、SDC=`9072d02a…`、Qsys_bb=`083b56d5…`、
  SFL `epcq.ip`=`efa07224…`、`sfl/synth/sfl_sys.v`=`240749e1…`，与当前本地
  candidate（QSF=`78032dc5…`、SDC=`caf84775…`、Qsys_bb=`91076193…`、
  epcq=`63e8f8b0…`、sfl synth=`904f53f0…`）不一致；远端工程不能直接作为
  当前 candidate 编译输入；
- `jtagconfig` exit 0，枚举到：
  `1) JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]`、
  `2) Microsoft Catapult (64) [USB-0]`，两条链均报告 `02E060DD 10AT115S(1|2)`。
  未调用 `quartus_pgm`，未复位/擦写 flash/EPCQ，未改变板卡状态。

### 3.3 现有构建现场

对远端 `D:\Projects\fpga-altra\lcvex\build` 只读枚举 `.log/.rpt/.summary/.sof`：

| 目录 | 文件总数 | 报告/日志类 | SOF | 判定 |
|---|---:|---:|---:|---|
| T-20260828-063 | 289 | 23 | 1 | 旧 Qsys smoke |
| T-20260828-064 | 209 | 57 | 2 | 旧 full flow/STA（非当前 candidate） |
| T-20260828-067 | 13 | 12 | 0 | 三次/后续 OOM 日志，`serv_req_info.txt` 存在 |
| T-20260830-008 | 818 | 69 | 0 | 旧 partition/QDB 现场 |
| T-20260830-016 | 271 | 16 | 0 | 旧 blackbox/glue blocked 现场 |
| T-20260830-020 | 754 | 43 | 1 | 旧替代路径现场，SOF 不可复用 |
| T-20260830-029/030/032 | 1,533 | 90 | 1 | 旧 BRAM/平台实验 |
| T-20260830-038 | 188 | 12 | 0 | L1D/L2 standalone synthesis |

全部 build 下共 536 个报告/日志类文件。T-067 的 `serv_req_info.txt` 当前存在，
最近 hash 为 `418c93bb…`；历史 evidence 已记录 75,425/74,962/76,291 MB OOM。
T-064 compile6 的旧 SOF 为 `04130f9d…`，仅能作为历史 provenance 参考，不能视为
本次 AArch64/当前 QSF/当前 cache candidate 的结果。

### 3.4 用户重启后的可靠 post-reboot snapshot

用户通知 `sent_at=2026-08-31T01:05:13+08:00`，Agent 接收约为
`2026-08-31T01:05:24+08:00`；Agent 未停止、暂停、改优先级或抢占任何进程。等待
外部恢复窗口为 `01:05:43..01:10:43`，首次恢复 SSH 为
`2026-08-31T01:10:56+08:00`，可靠快照查询为 `01:13:28..01:14:54+08:00`。

- OS boot `2026-08-31T01:08:13.5000000+08:00`；CPU load 57%；physical total
  63,092.3 MB、free 42,514.7 MB；
- `C:\pagefile.sys` allocated 12,800 MB、current 0 MB、peak 0 MB、available
  12,800 MB；D: free 104.2 GB；
- EDA 进程（quartus/qsys/vsim/questa/java）仍为 0；高内存进程前列为
  `VRChat` PID 5340（working set 3,348.6 MB/private 8,375.3 MB）、
  `steamwebhelper` PID 27408（753.9/762.9 MB）、`OVR Toolkit` PID 39400
  （682.3/1,186.0 MB）；未改变任何进程；
- Quartus 21.4.0 Build 67 版本查询 exit 0；qsys/ip-generate 可执行文件存在；
  `jtagconfig` exit 0，仍为两条 cable、两次 `02E060DD 10AT115S(1|2)`，与
  QSF `10AX115N4F40E3SG` 的身份差异未解决；
- 工程存在、远端 skeleton_manifest 缺失；QSF/SDC、Qsys、SFL key hashes 与重启前
  相同，T-067/T-038 artifact 计数仍分别为 13/188（报告类 12/12，SOF 0/0），
  `serv_req_info.txt` 仍存在且 hash 不变。

## 4. 分阶段资源门与执行顺序

所有阶段均使用新的 `build/<task-id>/<stage>` 输出根，开始前保存输入 manifest、
source.lock、QPF/QSF/SDC/Qsys/QIP、工具版本、JTAG chain 的 hash；每个阶段只运行
一个作业。`NUM_PARALLEL_PROCESSORS=1` 只能表示串行，不是内存硬上限。

| 阶段 | GO 条件 | WAIT 条件 | BLOCKED 条件 | 建议采样 |
|---|---|---|---|---|
| manifest/Qsys/SFL preflight | target/source/remote hashes 闭合；QIP/QSYS 选型唯一；无 stale root | 任一 hash/来源待确认 | 无法证明输入来自锁定 commit | 仅开始/结束 |
| reduced Analysis & Synthesis | 独立输出根；先验 private peak ≤35 GB；free physical ≥40 GB 且 pagefile 可用 ≥8 GB；现有 EDA=0 | 峰值未知、free physical 低于阈值或有 EDA 作业 | 预计接近 T-067 75 GB 峰值 | 15 s |
| partition/QDB synth/import | module signature、device/tool/source hash 完全一致；blackbox 先 synth，再 import | QDB 路径绑定/partition 名不一致 | 需要跨工程直接拷 stale DB 或 child 重新综合 | 15 s |
| full Analysis & Synthesis | 只有在实测资源余量覆盖峰值并保留 OS/现有进程安全裕量时 | 资源快照或输入 provenance 未闭合 | 当前 51.5 GB 理论余量无法覆盖历史 75–77 GB；当前 **BLOCKED** | 15 s |
| fitter | synthesis 成功、syn DB/hash 为当前 candidate、无 stale output；峰值估计在可提交余量内 | synthesis 仅局部通过、资源估计缺失 | 将 fit 当作绕过 synthesis 的手段或复用绑定旧 DB | 15 s |
| STA/TimeQuest | fit 完成；真实生成 clock/hierarchy 可解析；setup/hold/recovery/removal 均有报告 | guarded SDC 尚未在 post-fit 验证；clock 名不稳定 | 任一负 slack、CDC/reset 约束未闭合 | 30 s |
| assembler/SOF | fit+STA 全绿；QSF/device/input hash 冻结 | 警告/生成目录与 candidate 不一致 | 任何负 slack 或 SOF provenance 缺失 | 30 s |
| RTL/EDA simulation | 生成仿真 HDL/Qsys/SFL hash 闭合；独立 sim root；无 vsim/questa 进程 | model/Qsys 生成物缺失或版本不明 | 需要读取/改写 license 或借用 stale sim DB | 30 s |
| program | SOF/JIC hash 与冻结输入匹配；确认 cable 与 device identity；另有精确编程授权 | 当前 `10AT115S` 与 QSF `10AX115N4F40E3SG` 尚未解释 | chain/device 不匹配或目标不明确 | 5 s |
| board-test | program 成功；冷启动/复位/串口/DDR 校准恢复步骤可执行；先 SRAM→DDR→Cache/MMU | 缺板卡、电源/串口/DDR 观察条件 | 任何可能覆盖 EPCQ/flash 的动作没有单独任务/目标确认 | 5 s |

推荐顺序：`hash/Qsys/SFL` → `reduced/partition synthesis` → 资源复核 → `fitter`
→ `STA` → `assembler` → 独立 simulation → 明确 chain 后 `program` → 不写 Flash 的
初次 SRAM 配置 smoke → DDR/Cache/MMU → Linux。每步失败保留现场并停止后续阶段；
不通过清理他人进程、扩 pagefile 或修改系统配置来“恢复”资源。

## 5. 上板前可恢复测试顺序

1. 冻结当前 candidate commit、平台输入/QSF/SDC/Qsys/SFL/JTAG chain 和工具版本的
   SHA-256；确认远端工程已同步，清楚区分旧 T-064/T-030 SOF。
2. 先用不接 DDR 的 SRAM/BRAM boot smoke 验证 reset、JTAG-UART marker 和 AArch64
   地址图；记录复位后状态和串口/JTAG 输出。
3. 再做 EMIF calibration-only、DDR 地址线/byte-enable/March；cal 未完成或 sticky
   fail 时 CPU/request 必须保持 reset/block。
4. 再启用 Cache/MMU、dirty/refill/fault/checkpoint 和 Timer/GIC/JTAG-UART；保存
   每阶段日志、SOF、输入 hash 与板卡 chain。
5. 最后才执行 Linux `/init`；任何 debug/SignalTap 需要独立授权和独立 output root。

本预检不包含、也不暗示 EPCQ/Flash 写入。任何 `quartus_pgm`、JIC、EPCQ 擦写或
覆盖配置区动作必须另立精确任务，确认目标 cable/device、文件 hash、恢复方式和
人工批准；初次 smoke 仅允许 SRAM/不写 Flash 路径。

## 6. 风险与下一步

- **主要阻断**：当前 full synthesis 资源不足；T-067 75–77 GB 历史峰值不能由当前
  物理+pagefile 余量安全覆盖。
- **输入阻断**：source.lock 23 项参考源 hash 不匹配，当前本地 QSF/SDC 与清单漂移，
  远端工程仍是旧 hash，必须由平台 owner 重新锁定/同步；本任务不改这些文件。
- **链路风险**：JTAG device identity 与 QSF DEVICE 字符串不同，编程前必须人工确认。
- **生成风险**：qsys-generate/ip-generate 的路径/开关差异、SFL QIP/QSYS 双引用和
  alt_sld_fab 生成历史问题仍需在独立 staged task 中验证。
- **边界**：本任务未启动任何 Quartus/仿真/编程，未改远端文件，未停止任何进程，未
  读取 license；T-064/T-030 的旧 fit/STA/SOF 仅作历史参考。

建议集成者先登记一个只同步/校验 manifest+source.lock+Qsys/SFL 输入的任务；在
provenance gate 通过前不要申请 full flow。若资源不变，优先走 35 GB 以内的
reduced/partition scope，并在每个阶段完成后重新采样，而不是尝试完整 B5。
