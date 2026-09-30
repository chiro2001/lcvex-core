# T-20260909-002：B25 physical selector rerun 交接

```text
task=T-20260909-002
label=B25-PHYSICAL-SELECTOR-RERUN
state=blocked-timing-hold-and-t045-max-delay
acceptance_status=synthesis-fitter-sta-complete; physical-signoff-not-accepted
base_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
head_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
branch=verify/T-20260909-002-b25-physical-selector-rerun
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-002
original_dispatch_sent_at=2026-09-09T01:21:51+08:00
recovery_received_at=2026-09-09T01:46:47+08:00
reported_at=2026-09-09T10:14:28+08:00
remote_probe=D:/Projects/fpga-altra/lcvex/build/T-20260909-002-b25-physical
quartus=Quartus Prime Pro 21.4.0 Build 67
device=10AX115N4F40E3SG
evidence=docs/tasks/evidence/T-20260909-002.json
```

## 结论

本轮严格使用 candidate/source `702bd8ee5295efe8a2ad9e094d6c12471a1d3089` 和一次
fresh probe。`ipgenerate+synthesis`、fitter、signoff STA 工具均成功退出，且
selector/MIF/M20K、资源、DDR 和 metastability 证据已经生成；但整体 physical
signoff 保持 BLOCKED：

- `sys_clk_25` hold WNS=`-10.338 ns`、TNS=`-94.491 ns`、10 个 failing endpoints；
  custom top-50 为 50/50 violated。首个路径是
  `soc|emif_adapter|response_fifo|mem~514 -> soc|emif_adapter|txn_local_q`，报告为
  `No SDC Exception on Path`。
- T-045 三个 target/source collection 均实际 resolve，三个 false-path exception
  均为 `Complete` 且不在 `-ignored`；但
  `emif_poisoned_cpu_meta_q` 的 `set_max_delay 2.000` 为 `Fully overridden`，不能
  声称 max-delay 已应用。
- `altera_reserved_tck` 与 `soc|emif_adapter|emif_rst_sync1_n` 仍出现在
  unconstrained clock report；保留为后续约束/CDC 风险。

因此没有运行 assembler、没有生成 SOF/JIC/RBF/POF/JBC/SVF/JAM，也没有进行
quartus_pgm、nios2-terminal、JTAG、板卡 reset/power 或 Flash/EPCQ 写入。

## 输入与静态闭包

- Git tree=`de10feb8eaf0d0de5bf9ed91fa462242d7b09347`，candidate manifest 的 tree
  与 HEAD 一致；canonical=53（47 root RTL+2 platform RTL+3 project+1 MIF），QSF
  relative alias=47。
- `platform_payload_manifest`=78，其中平台契约=75，另 3 个是 task-local
  `run_*` 测试入口；QSF refs=49，stage file=174。candidate/platform manifest 与
  sidecar 分别为 `994843af...584bec6`、`903a502f...02ff5470`，remote source
  verifier 为 0 missing/extra/hash mismatch。
- `check_platform.py` 50/50、`check_skeleton.py --require-boot-image` 6/6、
  selector checker、`SHA256SUMS` 50/50 均通过。完整命令、日志和 hash 见 evidence。
- boot ELF/BIN/HEX/MIF 重建及独立 ELF-derived oracle emit/check 通过：ELF 68832 B，
  BIN 957 B，HEX 2871 B，MIF 204942 B，MIF `WIDTH=64 DEPTH=8192` 且 8192 records；
  MIF SHA=`614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7`，
  expected decoded SHA=`7889fff7ca07867da8827cede9d0444ed306b7a2be42e2b2f934ec66be9b643b`。

## 远端阶段

每一项远端写入、Quartus 作业、报告查询和回读都经过
`/home/chiro/projects/.resource-locks/resource-lock run gamepc`；每阶段只有一个
Quartus。准入阈值为 16384 MiB，runner 在低于 14336 MiB 时安全停止；本轮各阶段
均未触发安全停止。远端仅观察到既有 jtagserver PID 5688，未停止或连接。

| 阶段 | 精确 Quartus 命令 | 时间 / exit | runner 资源摘要 |
| --- | --- | --- | --- |
| synthesis | `quartus_sh --flow compile catapult_a10 -c catapult_a10 -start ipgenerate -end synthesis` | 02:02:11.767–08:53:30.571 / 0 | pre 47342.1 MiB，min 27624.4，post 43617，samples 4730，PID 33748 |
| fitter | `quartus_sh --flow compile catapult_a10 -c catapult_a10 -start fitter -end fitter` | 08:56:08.347–09:23:26.935 / 0 | pre 45239.6 MiB，min 32125.9，post 44916，samples 316，PID 17324 |
| sta_signoff | `quartus_sh --flow compile catapult_a10 -c catapult_a10 -start sta_signoff -end sta_signoff` | 09:25:47.053–09:26:28.675 / 0 | pre 45026.5 MiB，min 36339，post 43302.2，samples 8，PID 41436 |
| custom reports | `quartus_sta -t custom_sta_reports.tcl` | 09:39:08.906–09:39:40.062 / 0 | pre 45018.8 MiB，min 39487.6，post 44990，samples 6，PID 38392 |
| T-045/EMIF queries | `quartus_sta -t custom_acceptance_queries.tcl` | 09:57:41.071–09:58:07.038 / 0 | pre 44938.3 MiB，min 39371.3，post 44922.4，samples 5，PID 39280 |
| T-045 ignored query | `quartus_sta -t t045_ignored.tcl` | 10:04:31.414–10:04:57.439 / 0 | pre 44992 MiB，min 39221.6，post 44949.7，samples 5，PID 49344 |

阶段 wrapper 日志 SHA、远端 report SHA、完整 lock command 均在
[`T-20260909-002.json`](../tasks/evidence/T-20260909-002.json) 的 `stage_runs` 和
`postflight` 字段中。synthesis flow 明确记录 IP Generation 0 errors/6 warnings、
Analysis & Synthesis 0 errors/235 warnings、full flow 0 errors/241 warnings；fitter
报告为 0 errors/12 warnings，STA 为 0 errors/3 warnings。

## Selector、MIF、时钟和资源

- synthesis report 中 `Error 19544`、`Error 16186` 均不存在；行为
  `lcvex_bram_boot_behav` 不在 physical report，实际分支为
  `lcvex_bram_boot_altsyncram -> altera_syncram`。
- synthesis input table 将 `../boot/build/boot.mif` 识别为 User-Specified Memory
  Initialization File。fit RAM summary 进一步给出
  `soc|bram|u_impl|u_ram`、True Dual Port、8192×64、524288 bits、32 M20K、同一
  MIF；L1/L2 `u_data_ram` 各为 512-bit `altera_syncram`、16 M20K。
- final `report_clocks`：`clk_u59=10.000 ns/100 MHz`，`sys_clk_25=40.000 ns/
  25 MHz`、Generated、divide-by-4、master=`clk_u59`，`clk_y3=3.750 ns/266.67 MHz`，
  EMIF user clock=`emif|emif_bot|emif_bot_core_usr_clk` 为 3.750 ns。Qsys 源连接为
  `clk_100.clk -> reset_controller_0.clk` 且 top `.clk_100_clk(clk_u59)`；
  `clk_266.clk -> emif_bot.pll_ref_clk` 且 top `.clk_266_clk(clk_y3)`。
- fitter final resource：ALM 164698/427200（39%）、register 98069、pins 141/826
  （17%）、block memory 245652/55562240（<1%）、RAM blocks 121/2713（4%）、DSP
  186/1518（12%）、PLL 3/112（3%）。
- DDR Summary=Pass：Read Capture 0.027 ns、Write 0.063 ns、Address/Command
  0.368 ns、DQS Gating 1.177 ns、Write Levelling 0.220 ns。Metastability=Pass：4
  corners、27 synchronizer chains、最短 2 registers、timing-violation chains=0、
  worst-case MTBF `1e+09` years，settling time 3.342/3.484/4.906/5.321 ns。

## 约束与物理风险

`report_exceptions` default report 中三条 T-045 false path 为 Complete；
`report_exceptions -ignored` 中没有这三个 target 的 named entry，但 poisoned
max-delay 仍是 Fully overridden。EMIF→`sys_clk_25` 有 50 setup paths、0 violated、
3.723 ns；反向 query 为 no setup paths，未伪装成正向 margin。STA 的
`unconstrained_paths.rpt` 记录 2 clocks、2 input ports/63 input paths、1 output
port/4 output paths，其中两个未约束 clock 名称已在 evidence 中列出。

Quartus 在首次打开工程后把远端 QSF 行尾从 LF 规范化为 CRLF：candidate 为 13761 B、
SHA=`3e0ef899...171c5fe`，postflight remote 为 13972 B、SHA=`1deb0042...5bfa46`；
去除 CRLF 后字节完全相同。没有手改或回写 QSF，SDC/QPF、RTL、source.lock 和
platform manifest 的远端 hash 均保持 candidate 值；该工具行为作为 provenance 偏差
保留记录，不能用 postflight raw QSF hash 当 candidate hash。

## 安全边界、瞬态 harness 事件和后续

fresh probe 保留在 GamePC，未删除/覆盖旧 probe 或数据库。过程中曾出现 verifier
命令行过长、审计片段语法错误、custom runner 文件名错误、`report_min_pulse_width`
误用 `-npaths`、以及初版 T-045 查询调用不存在的 `get_object_name`；这些均没有改
RTL/QSF/SDC，也没有启动错误的 Quartus compile，修正后的查询结果和原始日志均已在
evidence 的 `transient_harness_events` 列出。

当前 `local FREE; gamepc FREE`，EDA process=0，禁止扩展名 artifact=0。下一步只能
另立 RTL/CDC/SDC 任务处理 `response_fifo -> txn_local_q` hold、T-045 max-delay
override 和 unconstrained reset clock；在 setup/hold/recovery/removal/min-pulse
全非负、T-045 max-delay 真正 applied 且约束风险闭合前，不得 assembler 或板级动作。
