# Handoff T-20260905-008：R16 full-FP Quartus physical

```text
task=T-20260905-008
state=accepted_blocked
source_sha=bab301e04f69cda154a8c9bb44f77af286ff579a
validated_source_sha=6a1c5539515a777382917451590c1ca89a626576
dispatch_head=322fb40d80f9c0c55f1534b5d4bd65bfacf619ec
documentation_base=1358da23b8b801f664a621099ef8b3a9b0ab567d
documentation_tip=final docs-only commit reported separately below
branch=verify/T-20260905-008-r16-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-008
task_created_at=2026-09-05T06:10:00+08:00
reported_at=2026-09-05T09:03:00+08:00
```

## 结论

T-008 retry3 在固定远端 `192.168.101.5`/`GAMEPC` 的新 probe
`D:\Projects\fpga-altra\lcvex\build\T-20260905-008-retry-probe\real_a10_full_fp`
上完成了输入等价核对、52-file sync、canonical IP 核对、synthesis、fitter、
signoff STA、定向 STA 和 `sys_clk_50` setup top-50 提取。synthesis 与 fitter
分别为 **0 errors / 233 warnings**、**0 errors / 11 warnings**；signoff STA
工具为 **0 errors / 3 warnings**，但 Timing Closure 为 **Fail**，唯一门禁失败为
`sys_clk_50` setup：**−4.797 ns / TNS −34241.243 ns / 20559 failing
endpoints**（Slow 900mV 100C）。

其余 hold、recovery、removal、minimum-pulse、DDR 和 Metastability 均通过。
因此本任务状态为 `accepted_blocked`，不能称为 timing closure 或
assembler-ready；未运行 assembler、未生成板级文件，也未进行 JTAG、烧写、上电或
上板。retry3 的 physical 结果有效；此前 attempt1/attempt2 仅是旧 probe 上的
资源 guard 停止，不与 retry3 结果混用。

## 输入与 provenance

- `git diff --quiet 6a1c5539515a777382917451590c1ca89a626576..bab301e04f69cda154a8c9bb44f77af286ff579a -- rtl Makefile scripts/test_registry.json tb sim`
  返回 clean。formal RTL 47 个文件、平台 RTL 2 个文件，连同 QPF/QSF/SDC 共
  52 项同步。
- retry3 physical input hashes：QPF
  `20d005d115c3bf2062125e862288e17300f5a55335eb50fca74b2d27ab6f3ca6`，QSF
  `a64ea972ea23257fb872e8487cdf50cccfb323e31492d5aada045243c8f2dfa4`，SDC
  `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`。
  retry3 QSF 仅将 project path 指向 retry3 probe；此前 partial probe 的 QSF
  hash `a7f28ed986e26a3c62e700400b76bbe844f6203f93ff1447cc9bc15dd7733e50` 不作为
  retry3 physical 输入。
- final remote manifest 为 `52/52`，missing/extra/bad 均为 0；retry3
  `manifest_retry3.json` hash 为
  `38678ca076602c6b46920357bdb4b7758fa2bd9d9aa046441bd1d19f374c1fa7`，
  postphysical remote manifest hash 为
  `f0a0294db4b3d9afd190a39771ddfde48036c53497379863519b45c5321f9c3a`。
- canonical EMIF/SFL/JTAG manifest 与 T-058 final manifest 逐项相同，实际脚本
  输出为 19 行（T-058 prose 写作 18，差异是包含 `qsys/Qsys.qsys` 的计数口径），
  missing/extra/bad 均为 0，当前 manifest hash 为
  `2cebdd21df338313958dc32d58db46d54bb26f583159285bf667eccd8ae35a06`。
- formal `rtl/lcvex_fp_scalar.sv` hash 为
  `24deb9f7ad1f2ed23fc6f88f6dcb93bc758eb2d357d69ad11e092c043d945cdc`。远端隔离
  副本仅移除 `iter_kill/iter_pause` 和 divider `kill/pause` 端口默认值，patched
  hash 为 `cace114c7bceb790594343933d0e34ac6094b46f182a966922d30b56f11088f7`；
  formal source 未修改。
- provenance discrepancy 保留记录：仓内 `fpga/catapult_a10/SHA256SUMS`
  与旧文档将 SDC 写为 `caf847755a8c42f2e88ea09e434888938ad4382193400593ddcc986f26154a8c`，
  实际 Git、T-058 source blob 和 T-008 remote sync 均为
  `2fad1663e7e10d282b1f8ee968ec224d8ddc7985bb0f54c130e524e8f6cfb2da`；未修改
  manifest。

## 远端配置、stage 与 guard

- Quartus Prime Pro `21.4.0 Build 67`，device `10AX115N4F40E3SG`，project
  `real_a10_full_fp`。
- synthesis/fitter/STA monitor 均使用 `MaxRunSeconds=43200`、
  `MinFreeMb=16384`；每个 stage 启动前 `EDA_COUNT=0`，所有 post guard 均确认
  `EDA_COUNT=0`，`jtagserver.exe` PID `5476` 全程保持运行。

| stage | 远端时间 | 结果 | monitor / 资源摘要 |
| --- | --- | --- | --- |
| synthesis | `07:41:29.5551460`–`08:11:48.7830334`，1819.228 s | Quartus 0/233，成功 | exit 0，safety_stopped=false；peak private/working `10968.9/10308.5 MB`，min free `36011.5 MB` |
| fitter | `08:13:56.2210835`–`08:41:58.6586941`，1682.438 s | Quartus 0/11，成功 | exit 0，safety_stopped=false；peak private/working `11617.3/11514.8 MB`，min free `33668.5 MB` |
| signoff STA | `08:43:30.1833692`–`08:44:07.9908659`，37.807 s | 工具 0/3，Timing Closure Fail | exit 0，safety_stopped=false；peak private/working `6344.7/6317.2 MB`，min free `38918.1 MB` |
| custom top-10 STA | `08:47:47`–`08:48:10`，约 23 s | Quartus 0/2，成功 | setup/hold/recovery/removal top-10 已保存 |
| custom EMIF/target STA | `08:49:03`–`08:49:27`，约 24 s | Quartus 0/2，成功 | EMIF directional/cross 与旧 target query 已保存 |
| setup top-50 STA | `08:50:15`–`08:50:35`，约 20 s | Quartus 0/2，成功 | final snapshot，50/50 violated |

阶段 guard 的精确 capture 时间如下；每个 capture 的 hash 记录在 evidence JSON
和 retry3 `evidence/artifact_hashes.txt` 中。

| guard | capture time | free physical / 结果 |
| --- | --- | --- |
| admission | `07:38:56.5780867` | `47423280 KB`，probe 不存在，EDA=0 |
| probe create/layout | capture 未输出时间 | `PROBE_CREATED`，layout ready，EDA=0 |
| pre-synthesis | `07:40:54.1960451` | `47435720 KB`，EDA=0 |
| post-synthesis | `08:13:14.9427709` | `44866.9 MB`，EDA=0 |
| pre-fitter | `08:13:38.9795022` | `45967008 KB`，EDA=0 |
| post-fitter | `08:42:20.1816790` | `46470.9 MB`，EDA=0 |
| pre-STA | `08:43:10.9423988` | `45959036 KB`，EDA=0 |
| post-STA | `08:44:22.2796922` | `46535.2 MB`，EDA=0 |
| pre-custom top | `08:47:44.7330810` | `47661564 KB`，EDA=0 |
| post-custom top | `08:48:24.9536351` | `45033.9 MB`，EDA=0 |
| pre-custom EMIF | `08:48:59.6927158` | `46283444 KB`，EDA=0 |
| post-custom EMIF | `08:49:41.7142708` | `46538.3 MB`，EDA=0 |
| pre-top-50 | `08:50:12.1346874` | `47673312 KB`，EDA=0 |
| post-top-50 | `08:50:51.1843005` | `46540.6 MB`，EDA=0 |
| final postflight | `08:54:01.2346655` | `45215.7 MB`，EDA=0，assembler artifact count=0 |

只读内存审计显示非 EDA `vmmemWSL` 常驻约 18 GB；本任务未停止任何非 EDA
进程，也未降低 16 GB guard。

## retry3 资源结果

| 项目 | synthesis estimate | fitter final |
| --- | ---: | ---: |
| ALM | 149769 | 149558 / 427200 (35%) |
| ALUT | 196617 | 197051 |
| registers | 91388 | 94107 |
| I/O | 144 | 141 / 826 (17%) |
| block memory bits | 247272 | 245608 / 55562240 (<1%) |
| RAM/M20K | — | 121 / 2713 (4%) |
| DSP | 186 | 186 / 1518 (12%) |
| PLL/IOPLL | 1 | 3 / 112 PLL (3%), 3 / 16 IOPLL |
| peak interconnect | — | 83.1% total / 84.1% horizontal / 81.8% vertical |
| maximum fanout | 83751 | 86384（highest non-global 7925） |
| total fanout | 1331426 | 1345668 |

## signoff STA、DDR 与 Metastability

| check | retry3 result |
| --- | --- |
| `sys_clk_50` setup | **−4.797 ns**, TNS **−34241.243 ns**, **20559** failing endpoints，Slow 900mV 100C |
| EMIF user setup | **+0.263 ns**, TNS 0，0 failing endpoints |
| worst hold | **+0.014 ns**，0 failing endpoints，Fast 900mV 0C |
| worst recovery | **+0.501 ns**，0 failing endpoints，Slow 900mV 100C |
| worst removal | **+0.154 ns**，0 failing endpoints，Fast 900mV 0C |
| worst minimum pulse | **+0.120 ns**，0 failing endpoints，Slow 900mV 0C |

主要 Fmax：`sys_clk_50` **40.33 MHz**；EMIF cal master/user/cal slave
**212.09/286.78/357.78 MHz**；`clk_y3` **522.47 MHz**；受 hold check 限制的
VCO restricted Fmax 为 **259.34/248.51/250.94 MHz**。

Metastability 为 **Pass**：24 synchronizer chains，最短 2 registers，timing
violation chains 0，excluded 20，worst MTBF `1e+09 years`；四个 corner 的
worst available settling time（slow100/slow0/fast100/fast0）为
**3.639/3.788/5.021/5.417 ns**。DDR 为 **Pass**；summary margins
Read/Write/Address-Command/DQS Gating/Write-Levelling 为
**+0.014/+0.031/+0.184/+0.588/+0.110 ns**，detailed final margins 为
**+0.027/+0.063/+0.368/+1.177/+0.220 ns**。

## setup top-N 与 Round15 对照

custom setup top-10 最差为 `−4.797 ns`；hold/recovery/removal top-1 分别为
`+0.014/+0.501/+0.154 ns`。EMIF→user、user→EMIF、EMIF cross setup 均为
`+0.263 ns`。旧 T-053/T-058 目标 `add_align_hi -> pp_pre_hi` 独立查询返回
`Nothing to report`。

setup top-50 报告声明 **50/50 violated**，每条路径均为
`No SDC Exception on Path`。解析后聚类为：

| cone | paths | slack range | logic levels |
| --- | ---: | ---: | ---: |
| `fp_exec.scalar_unit.g_iter.pp_pre -> fp_exec.scalar_unit.g_iter.pack_mid` | 26 | `−4.797..−4.683 ns` | 65 |
| `core.exmem_valid -> fp_exec.acc` | 18 | `−4.767..−4.685 ns` | 27 |
| `core.memwb_wb_rd -> fp_exec.acc` | 3 | `−4.706..−4.706 ns` | 27 |
| `core.exmem_wb_rd -> fp_exec.acc` | 3 | `−4.698..−4.698 ns` | 27 |

相对 T-058 的 `pp_pre -> slot_result_r`（28 paths、54 levels、
`−2.675..−2.633 ns`），旧 direct target 已消失，但新的
`pp_pre -> pack_mid` 仍占 top-50（26 paths、65 levels，最差 `−4.797 ns`）。
因 setup 仍为负，不能宣称 timing closure 或 assembler-ready。

## 旧 partial attempts

| attempt | 远端时间 | monitor 结果 | 峰值 / final free | 结论 |
| --- | --- | --- | --- | --- |
| attempt1 | `06:28:06.6351734`–`06:31:14.2635854`，187.628 s | exit 124，safety_stopped=true | private/working `7449.0/7669.8 MB`，final free `15343.4 MB` | `build/agents/T-20260905-008/quartus/synthesis/attempt1/`，未完成 synthesis |
| attempt2/retry | `06:33:01.0282064`–`06:34:23.8582508`，82.830 s | exit 124，safety_stopped=true | private/working `3773.6/3794.4 MB`，final free `16195.3 MB` | `build/agents/T-20260905-008/quartus/synthesis/attempt2/`，仍低于 16384 MB |

两次旧 monitor 均为资源 guard 停止，`timeout=false`，Quartus root 被安全回收；
它们没有完成 database/report，不能当作 retry3 的 physical 结果。

## 门禁、artifact 与下一步

- retry3 最终 postflight：EDA_COUNT=0，jtagserver PID=5476 保持运行，exact
  extension scan 的 `.sof/.jic/.rbf/.pof/.jbc/.svf/.jam` artifact count=0。
- assembler、SOF/JIC/RBF/POF/JBC/SVF/JAM、JTAG programming、烧写、上电和上板
  均未运行；formal RTL、QSF、SDC、QEMU source 均未修改，未添加 false path。
- retry3 全量 artifact hash 清单为
  `build/agents/T-20260905-008/retry3/evidence/artifact_hashes.txt`（168 entries）。
  关键 report、monitor、custom STA、top-50 raw/parsed hash 与精确命令见
  [`docs/tasks/evidence/T-20260905-008.json`](../tasks/evidence/T-20260905-008.json)。
- blocker：`sys_clk_50` setup 为 −4.797 ns。下一轮需要针对新的
  `pp_pre -> pack_mid` / `exmem_valid -> fp_exec.acc` cones 做结构化切级或寄存器
  切分，保持同一 QSF/SDC/CDC policy，禁止 false path；修复后必须用新 probe
  重跑 synthesis→fitter→signoff STA，再决定 assembler 门禁。
