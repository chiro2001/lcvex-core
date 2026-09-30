# T-20260831-001 FPGA-G6-PREFLIGHT：A10 执行前只读预检

```text
task=T-20260831-001 state=review
base=fbb5d71e2430dbae3ef43490c14c2b6f5c6cda92 head=55dbd0cf7bf609e76dcfb7341c48af971b44df73
branch=infra/T-20260831-001-a10-execution-preflight worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-001
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-08-31T00:42:34+08:00 received_at=2026-08-31T00:43:39+08:00 reported_at=2026-08-31T01:19:13+08:00
post_reboot_notice_sent_at=2026-08-31T01:05:13+08:00 post_reboot_notice_received_at=2026-08-31T01:05:24+08:00
post_reboot_ssh_restored_at=2026-08-31T01:10:56+08:00 post_reboot_snapshot_at=2026-08-31T01:13:28+08:00
```

## 结论

本任务仅执行本地静态/hash 审计和远端只读 probe。没有启动 Quartus compile、
simulation、fitter、STA、assembler 或 programming；没有停止/暂停/降优先级/抢占
任何进程，没有修改远端文件，没有读取 license 内容。

当前远端没有活动 Quartus/qsys/vsim/questa/java 进程，机器可用于后续受控的小型
reduced/partition 试验；但不能安全运行 T-067 同等级真实 B5 full synthesis：历史
`quartus_syn` private peak 为 75,425–77,060 MB，用户重启后的可用物理内存约
42,515 MB、pagefile 可用约 12,800 MB，理论可提交余量约 55.3 GB，尚须保留系统/
现有进程安全余量。因此 full Analysis & Synthesis 当前 **BLOCKED**。

在输入 provenance 闭合后，只有先验 private peak 不超过约 35 GB、free physical
≥40 GB、pagefile 可用 ≥8 GB 且无其他 EDA 作业时，reduced/partition scope 才能
**GO**；峰值未知或输入 hash 未闭合则 **WAIT**。

## Provenance 与来源边界

- 平台冻结为 Arria 10 `10AX115N4F40E3SG`、Quartus Prime Pro 21.4 Build 67、
  100 MHz→50 MHz 逻辑域、266.667 MHz DDR reference、72-bit DQ/9-bit DQS、
  512-bit Avalon EMIF、EPCQL1024 Active Serial x4；LCVEX 初始 RAM 窗口为
  `0x40000000..0x48000000`。
- 参考仓 `/home/chiro/projects/a10-linux-riscv` clean，HEAD 为锁定的
  `3db828e74651fda377a33d84f2a2ca0e69901d72`。source.lock 共 50 项；逐项比较该
  commit 的 raw blob 后 27 项匹配、23 项不匹配。23 项均为 SFL clk/rst/epcq/顶层
  generated component 文件；不应在执行前默认为仅行尾差异，需平台 owner 重新确认
  生成快照和 hash。
- 本地 `SHA256SUMS` 48/50 通过；QPF 通过，但当前 QSF 与 SDC 的 hash 分别为
  `78032dc5…`、`caf84775…`，清单仍记录 `89ed1bab…`、`9072d02a…`。QSF 漂移含
  后续 B5/Cache 源接线，SDC 漂移含 AUD-04/EXT-03 CDC 约束；在 manifest/
  SHA256SUMS/source.lock 更新并审阅前，provenance gate 不通过。
- 允许借鉴参考仓的 DDR4 Qsys/EMIF、SFL/EPCQ、JTAG-UART、pin/clock/reset/calibration
  结构和 hash 组织；禁止带入 VexRiscv/RV32IMA/Sv32、OpenSBI/CLINT/PLIC、RISC-V
  boot/DTB、`C_ALIAS_ENABLE`/`FLASH_DIAG`/SignalTap、32-bit AXI→Avalon bridge、
  `0x80000000` DDR/`0xF0000000` UART 地址图。LCVEX 保持 AArch64、现有 AXI4/EMIF
  边界和 0x40000000 窗口。

## 远端只读快照

快照时间均为 Asia/Shanghai（Windows 文件时间以 UTC `Z` 输出并在 evidence 保留）：

- 主机 `192.168.101.5` / `GamePC`：OS boot `2026-08-28T19:18:29.5000000+08:00`；
  AMD Ryzen 9 9900X 12-Core，12 cores/24 logical，采样 load 71%。
- 初次快照物理内存 total 63,092.3 MB（约 61.6 GiB），free 43,121.0 MB；用户重启
  后可靠快照 free 42,514.7 MB。
- 初次快照 `C:\pagefile.sys` allocated 9,216 MB/current 792 MB/available 8,424 MB；
  重启后 allocated 12,800 MB/current 0 MB/available 12,800 MB；D: 初次 free
  102.68 GB，重启后 free 104.2 GB。
- EDA 进程筛选 `quartus|qsys|vsim|questa|java` 共 0；未检测到 compile/sim/
  programming。高内存进程共 20，前列为 `vmmemWSL` PID 45176（WS 2,917.3 MB、
  private 2,923.4 MB）、Memory Compression 529.3 MB、QQ 481.1 MB；未改变任何进程。
- `quartus_sh.exe --version` exit 0，版本 `21.4.0 Build 67 12/06/2021 SC Pro`。
  `qsys-generate.exe` 存在但 `--version` exit 1（不支持该开关），`ip-generate.exe`
  存在但 exit 3（Pro 仅 acdstest resource）；历史可用入口是
  `quartus_ipgenerate.exe`，不能以受限 `ip-generate` 结果替代。
- `D:\Projects\fpga-altra\lcvex` 存在，license path 只做 `Test-Path=true`，未读
  内容；远端 `skeleton_manifest.json` 缺失。
- `jtagconfig` exit 0，看到两条 cable：`JTAG-MPSSE-Blaster [00 Single RS232-HS
  (0403:6014)]` 和 `Microsoft Catapult (64) [USB-0]`；两条都返回
  `02E060DD 10AT115S(1|2)`。这与 QSF `10AX115N4F40E3SG` 字符串不一致，编程前
  必须人工确认真实 package/device/chain。

远端平台 key hash 仍是旧 candidate：QSF `89ed1bab…`、SDC `9072d02a…`、
Qsys_bb `083b56d5…`、SFL epcq `efa07224…`、SFL synth `240749e1…`；当前本地
candidate 为 QSF `78032dc5…`、SDC `caf84775…`、Qsys_bb `91076193…`、epcq
`63e8f8b0…`、SFL synth `904f53f0…`。远端不能直接用于当前 candidate。

远端 `build` 下只读统计得到 536 个 `.log/.rpt/.summary/.sof` 文件；T-064/T-030
旧 SOF、T-067 OOM 日志、T-038 standalone 报告并存。T-067 `serv_req_info.txt`
仍存在（hash `418c93bb…`），T-064 compile6 旧 SOF hash `04130f9d…`；这些都是
历史 provenance，不能作为当前 AArch64/full-flow 结果。T-20260830-038 仅有 12 个
报告/日志类文件、无 SOF。

用户于 `2026-08-31T01:05:13+08:00` 通知并发起 Windows 重启；Agent 未停止、
暂停、调整优先级或抢占任何进程。外部等待窗口为 `01:05:43..01:10:43`，首次
SSH 于 `01:10:56+08:00` 恢复。post-reboot 只读快照确认 OS boot
`2026-08-31T01:08:13.5000000+08:00`、CPU load 57%、EDA process count 0、
physical free 42,514.7 MB、pagefile 12,800 MB free、D 盘 free 104.2 GB；
工程/hash、T-067/T-038 artifact 计数和 JTAG chain 与重启前结论一致（key/artifact
细节见 evidence）。

## 坑点与 staged gate

| 阶段 | GO | WAIT | BLOCKED/当前结论 |
|---|---|---|---|
| manifest/Qsys/SFL | target/source/remote hash 闭合、QIP/QSYS 唯一 | 任一来源/hash 待确认 | 当前 QSF/SDC/source.lock 漂移，先修复 provenance |
| reduced/partition synthesis | 先验 private peak ≤35 GB，free physical ≥40 GB，pagefile ≥8 GB，EDA=0，独立输出根 | 峰值未知、资源快照不足、已有 EDA | 不满足即 WAIT；历史 full 级别直接 BLOCKED |
| full Analysis & Synthesis | 可提交余量覆盖历史峰值且保留 ≥8 GB 系统余量 | 仅有理论余量或生成输入未冻结 | 当前 55.3 GB 理论余量 <75–77 GB 历史峰值，**BLOCKED** |
| blackbox/QDB import | 同一 device/tool/source/module signature；blackbox synth→import→fitter-only | partition 名/路径/hash 不一致 | 禁止跨工程直接拷 stale DB；T-008 方案只适用于签名一致的 reduced scope |
| fitter | 当前 synthesis DB/hash 新鲜、资源估计可覆盖 | synthesis 只有局部结果或 output stale | 不得以 fitter 绕过 full elaboration |
| STA/TimeQuest | fit 完成，真实 generated-clock/hierarchy 可解析，setup/hold/recovery/removal 全正 | guarded SDC 尚未 post-fit 复核 | 任一负 slack/CDC reset 未闭合则 BLOCKED |
| assembler/SOF | fit+STA 全绿，QSF/device/input hash 冻结 | warning/生成目录未分类 | 禁止复用 T-064/T-030 SOF |
| simulation | 生成 HDL/Qsys/SFL hash 闭合，独立 sim root，无 vsim/questa | model 缺失或版本不明 | 不得借用 stale sim DB/license |
| program | SOF/JIC hash 匹配，cable/device identity 已确认，精确授权 | 当前 `10AT115S` vs QSF `10AX115` 未解释 | 当前 **WAIT**；本任务未调用 quartus_pgm |
| board-test | program 成功，reset/power/serial/DDR 恢复步骤冻结 | 缺板卡观察条件 | 任何 EPCQ/Flash 写入必须另立精确任务；初次仅 SRAM smoke |

所有阶段一次一个作业：synthesis/fit 15 s 采样，STA/assembler/simulation 30 s，
program/board 5 s。`NUM_PARALLEL_PROCESSORS=1` 只表示串行，不是内存硬上限；资源
不足时应 WAIT/BLOCKED，不能停止现有进程、调 pagefile 或改系统优先级。

## 上板恢复顺序

冻结同一 candidate 的 commit、manifest/source.lock/SHA256SUMS、QPF/QSF/SDC/Qsys/
SFL、Quartus 版本和 cable/device chain hash；先做不写 Flash 的 SRAM/BRAM boot
marker，再做 EMIF calibration-only 和 DDR March/地址线/byte-enable，随后启用
Cache/MMU/Timer/GIC/JTAG-UART，最后 Linux `/init`。cal 未完成或 sticky fail 时
CPU/request 必须保持 reset/block。`quartus_pgm`、JIC、EPCQ 擦写/覆盖配置区必须
另立任务，明确目标、hash、恢复方式和人工批准。

## 边界与下一步

- 本预检没有 Quartus compile/simulation/programming，没有远端写入，没有停止或改变
  进程，没有 license 内容读取。
- 主要 blocker 是 full synthesis 资源和输入 provenance；其次是 JTAG device identity。
- 集成者应先登记输入同步/重锁定任务，再登记 ≤35 GB 的 reduced/partition synthesis；
  provenance gate 和资源门均通过后，才可申请 fitter/STA/assembler。

精确命令、退出码、时间、hash、资源/进程/pagefile/disk/JTAG 快照见
[`docs/tasks/evidence/T-20260831-001.json`](../tasks/evidence/T-20260831-001.json)。
