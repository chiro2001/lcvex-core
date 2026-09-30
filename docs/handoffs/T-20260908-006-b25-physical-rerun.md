# T-20260908-006：B25 physical rerun 交接

```text
task=T-20260908-006 state=blocked-synthesis
base=ff88f6985f632de19896e17763182d1f44bd9703
source_head=2743ecb8aec7d949eec259e743e76dfb48682677
branch=verify/T-20260908-006-b25-physical-rerun
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-006
sent_at=2026-09-08T23:04:55+08:00 received_at=2026-09-08T23:04:55+08:00
reported_at=2026-09-08T23:20:00+08:00
files=docs/tasks/evidence/T-20260908-006.json,docs/handoffs/T-20260908-006-b25-physical-rerun.md,build/agents/T-20260908-006/**（ignored）,D:/Projects/fpga-altra/lcvex/build/T-20260908-006-b25-physical
stages=preflight -> source/MIF closure -> IP generation PASS -> synthesis FAIL -> fitter/STA/custom not run
resource_lock=gamepc；final=local FREE / gamepc FREE
candidate/source=ff88f6985f632de19896e17763182d1f44bd9703
evidence=docs/tasks/evidence/T-20260908-006.json
```

## 结论

本轮严格使用 source/candidate `ff88f6985f632de19896e17763182d1f44bd9703`。工作树
`2743ecb8aec7d949eec259e743e76dfb48682677` 相对 candidate 只有 T-006 active task
元数据，非 docs 物理输入差异为 0。

本地 boot/平台/manifest 闭包及远端 source/MIF 逐项核对均通过，但 fresh Quartus
流程在 synthesis 阶段首个语义错误处停止：

```text
Error (19544): lcvex_bram_boot.sv(165):
  if-condition does not match any sensitivity list edge
Error (16186): Can't elaborate top-level user hierarchy
```

Quartus IP Generation 已通过（0 errors、6 warnings）；`quartus_syn` 失败（3 errors、
26 warnings），完整 flow exit 3/5 errors/32 warnings。该错误与内存无关：运行最低物理
空闲 43735.7 MiB，未触发 14336 MiB safety stop。按任务要求没有改 RTL、没有绕过或
重试，也没有进入 fitter/STA。

## 输入与远端闭包

- `boot/build.sh` 从候选重建 ELF 68832 B、BIN 957 B、HEX 2871 B、MIF 204942 B；
  MIF 为 `WIDTH=64`、`DEPTH=8192`、8192 records，MIF SHA-256
  `614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7`。
- `check_platform.py` 50/50 pass；`check_skeleton.py --require-boot-image` pass；
  `SHA256SUMS` 50/50 pass。
- canonical manifest 为 53 项（47 root RTL、2 platform RTL、QPF/QSF/SDC、generated
  MIF），QSF 相对 alias 47 项，平台 payload 75 项；manifest SHA-256 和精确命令见
  evidence。
- GamePC 为 `GAMEPC`，Quartus Prime Pro 21.4.0 Build 67，器件
  `10AX115N4F40E3SG`。初始物理空闲 48702.6 MiB，D: 可用 91497054208 bytes，EDA
  进程 0；仅观察既有 `jtagserver` PID 5688。
- 远端 source verify：53/47/75 项全部 hash/bytes=0 mismatch；QSF 的
  `../boot/build/boot.mif` 已解析到远端 MIF；初始无 db/incremental_db/output_files
  或 forbidden artifact。

## 阶段结果

唯一 Quartus 阶段命令：

```text
quartus_sh --flow compile catapult_a10 -c catapult_a10 -start ipgenerate -end synthesis
```

`gamepc` 锁内启动时间 `2026-09-08T23:12:37.9790879+08:00`，结束时间
`2026-09-08T23:14:47.2375935+08:00`，exit 3，Quartus PID 29328，运行时采样25次，
最低空闲43735.7 MiB，前后 EDA 进程均为0。IP Generation 0/6（错误/警告），Analysis
& Synthesis 3/26；`lcvex_bram_boot.sv:165` 是第一个错误。

Synthesis report 的输入表已把 `../boot/build/boot.mif` 列为
`User-Specified Memory Initialization File`，并显示 Qsys/adapter/cache 等 RAM
提取信息；但没有成功 netlist，所以不能声称 MIF 已完成 M20K 消费，也不能给出 fit
资源或时序数字。

以下均为未测量，不是通过：

- `sys_clk_25` 预期 40.000 ns，但没有 post-fit STA；
- setup/hold/recovery/removal/min-pulse、Fmax、DDR/metastability、M20K/资源未生成；
- `emif_reset_cpu_meta_q`、`emif_poisoned_cpu_meta_q`、`cpu_rst_emif_meta_q` 三个
  T-045 SDC filter 未由 TimeQuest resolve；
- fitter、signoff STA、clock/BRAM/CDC/MIF custom reports 未运行。

## Warning 分类

- IP Generation 6：Qsys `clk_100`、`clk_266`、`reset_controller` 的 Project Setting
  与 IP Variant 信息不匹配，各出现两次。
- Synthesis 26：16749=19（core/adapter 标识符提前声明）、13469=2（截断赋值）、
  16746=1（隐式声明）、19651=1（latch）、16750=1（always_comb 信号）、17074=1
  （BRAM boot 多边沿赋值）、16788=1（无驱动 net）。19544/16186 为 error，不降级为
  warning。

## 安全与边界

- fresh 现场保留于 `D:/Projects/fpga-altra/lcvex/build/T-20260908-006-b25-physical`；
  失败后未删除或覆盖任何远端文件。
- postflight EDA=0、forbidden artifact=0；失败运行仅新建了该 probe 下的
  `quartus/output_files`，不作为可复用数据库。
- 未运行 assembler，未生成 SOF/JIC/RBF/POF/JBC/SVF/JAM；未运行 quartus_pgm、
  nios2-terminal、JTAG、配置、复位、上电或 Flash/EPCQ 操作；未读取 license 内容。
- 未修改 RTL、QSF、SDC、QEMU、active task JSON、TASKS、PROJECT_STATUS 或 ROADMAP。

精确 hash、日志、内存采样、锁命令和首个错误见
[`T-20260908-006.json`](../tasks/evidence/T-20260908-006.json)。
