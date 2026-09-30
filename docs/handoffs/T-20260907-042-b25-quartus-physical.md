# T-20260907-042：B25 Quartus physical 交接

```text
task=T-20260907-042 state=blocked-synthesis
base=259188ac33322a74a8911c9c37edc6302f6d6169
head=b0749a63c164a210239366738c43fa03b7e91e36
branch=verify/T-20260907-042-b25-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-042
sent_at=2026-09-07T09:28:00+08:00 received_at=2026-09-07T09:28:00+08:00
reported_at=2026-09-07T09:55:30+08:00
files=docs/tasks/evidence/T-20260907-042.json,docs/handoffs/T-20260907-042-b25-quartus-physical.md,build/agents/T-20260907-042/**（ignored）,D:/Projects/fpga-altra/lcvex/build/T-20260907-042-b25-physical
stages=source-manifest -> synthesis（IP Generation pass, Analysis & Synthesis fail） -> fitter/STA/custom not run
resource_lock=gamepc；synthesis已锁；final=local FREE / gamepc FREE
candidate/source=259188ac33322a74a8911c9c37edc6302f6d6169
evidence=docs/tasks/evidence/T-20260907-042.json
```

## 结论

在精确 B25 candidate `259188ac33322a74a8911c9c37edc6302f6d6169` 上，fresh
remote probe 已完成源闭包，但 synthesis 被 Quartus Prime Pro 21.4 的
SystemVerilog 输入端口默认值拒绝，任务因此阻断。IP Generation 已成功（0 errors、6
warnings），随后 Analysis & Synthesis exit 3（8 errors、24 warnings）。首个四个实质
错误均在 `rtl/lcvex_fp_scalar.sv`：

```text
17324 line 48   iter_kill = 1'b0
17324 line 49   iter_pause = 1'b0
17324 line 6122 kill = 1'b0
17324 line 6123 pause = 1'b0
```

后续 `13363` 是上述错误引起的模块忽略。历史 T-035 曾使用过只存在于远端的 Quartus
兼容副本，但本任务要求保留 exact candidate、失败后不得自行修改 RTL/QSF/SDC 或重试，
所以本轮没有应用该副本，也没有继续 fitter/STA。

## 输入与 MIF

- 本地 `check_platform.py`：50/50 pass；`check_skeleton.py --require-boot-image`：
  6 files pass；`sha256sum -c SHA256SUMS`：50/50 pass。
- 非 docs 物理输入相对 candidate 为 0 diff；物理 manifest canonical 53 项（47 root
  RTL、2 platform RTL、3 project 文件、1 generated MIF），另有 47 个为 QSF 相对路径
  服务的逐项 alias；平台 payload 独立清单 75 项。
- `boot/build.sh` 重新生成：ELF 68832 B、BIN 957 B、HEX 2871 B、MIF 204942 B；
  MIF `WIDTH=64`、`DEPTH=8192`、8192 records，MIF SHA-256
  `614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7`。
- 远端 source verify 逐项 hash/bytes 为 0 mismatch，QSF 的
  `../boot/build/boot.mif` 解析到远端 MIF，fresh probe 初始无 Quartus database 或
  forbidden artifact。
- Quartus synthesis report 的输入表已把 MIF 列为
  `User-Specified Memory Initialization File`，但 synthesis 未完成，因此不能声称
  M20K 已实际消费、也不能给出 fit 后 M20K 数字。

## 物理阶段

唯一 synthesis 命令为：

```text
quartus_sh --flow compile catapult_a10 -c catapult_a10 -start ipgenerate -end synthesis
```

时间为 `09:45:44.2552284` 至 `09:47:44.1189606 +08:00`，exit 3，运行时最低物理空闲
`34873.1 MiB`，没有触发 `<14 GiB` safety-stop；前后 EDA 进程均为 0。失败现场保留在
fresh probe，关键本地报告及 SHA-256 见 evidence。

因此以下结果是“未测量”，不是通过：

- `sys_clk_25` 预期 40.000 ns，但没有 post-fit STA 结果；
- setup/hold/recovery/removal/min-pulse、Fmax、资源和 M20K 使用量未生成；
- `emif_reset_cpu_meta_q`、`emif_poisoned_cpu_meta_q`、`cpu_rst_emif_meta_q` 三个
  T-045 SDC filter 未能由 TimeQuest 实际 resolve；
- fitter、signoff STA、clock/BRAM/CDC/MIF custom reports 均未运行。

## Warning 分类

- IP Generation 6：clk_100、clk_266、reset_controller 的 Project Setting 与 IP Variant
  信息不匹配各出现两次。
- Synthesis 24：16934（FP 输入默认值）4 条，16746（`mmu_en` 隐式声明）1 条，
  16749（core/adapter 标识符提前声明）19 条。16934 与阻断错误属于同一 Quartus
  兼容性边界，不能降级为无害 warning。
- 无 fitter/STA warning 可分类。

## 安全边界与修正记录

- 未修改 RTL、QSF、SDC、QEMU 或 active task 台账；未读取 license 内容。
- 未运行 assembler，未生成 SOF/JIC/RBF/POF/JBC/SVF/JAM；未运行 quartus_pgm、JTAG、
  nios2-terminal、reset/power/Flash/板级动作。
- 仅观察到既有 `jtagserver` PID 5476，未停止或连接。
- 远端 probe 是任务专用 fresh 目录；失败后保留其 generated Qsys/output_files 现场，
  不删除、不覆盖、不复用。
- 准备阶段一条 `New-Item -LiteralPath` 因远端兼容性失败后改为 `-Path`；一份平台
  manifest 首次 SCP 和一条只读 debug SSH 未在锁内，均未启动工具或改变 RTL/Quartus
  工程，随后在 `gamepc` 锁内重传并以锁内 verifier 通过结果为权威证据。后续所有远端
  操作均经过 `resource-lock run gamepc`。

## 下一步

由集成者决定是否另行授权/登记 Quartus 21.4 兼容输入副本或修复方案；在此决定前不得
把本 fresh database 交给 assembler，也不得把未测量的时钟、资源或 SDC filter 状态当作
B25 physical pass。精确命令、源/远端 hash、首个错误和现场路径以
[`T-20260907-042.json`](../tasks/evidence/T-20260907-042.json) 为准。
