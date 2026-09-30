# LCVEX 交接文档 051：checkpoint 联合恢复闭环

日期：2026-08-24（Asia/Shanghai）

> 本文记录联合恢复闭环的基线状态；Generic Timer sidecar 已在
> [handoff 052](052-generic-timer-checkpoint-sidecar.md) 中补齐，阅读当前状态
> 时以 052 为准。

## 1. 当前分支与提交

- 分支：`main`，工作树干净，领先 `origin/main` 42 个提交。
- 关键提交：
  - `b44ffde`：PSCI/HVC 最小闭环；
  - `870c14c`、`02fc4d5`：差分 checkpoint 保存与 QEMU 恢复工具；
  - `216cc23`：架构摘要（PC/GPR/SP/NZCV）；
  - `5b042e0`、`8f293eb`：Verilator DUT 架构/RAM 注入 smoke；
  - `a7b8966`：QEMU/DUT checkpoint 联合锁步；
  - `3add9bf`、`ca78168`：QEMU 系统状态 sidecar 与联合恢复验证。

QEMU 位于 `../qemu`，仍有本地 fork 的未提交 step-hook 源码改动；不得
`reset/checkout` 覆盖。对应补丁已整理在 `qemu/patches/0001`、`0002`，并在
干净 QEMU 11.1.0 archive 上通过 `git apply --check`。

## 2. 已验证能力

### PSCI/Linux 前置

- `hard_psci` base/cache 29 条逐指令锁步全绿；覆盖 VERSION、MIGRATE_INFO_TYPE
  返回 2、FEATURES、AFFINITY_INFO、CPU_ON。
- Linux 锁步此前已到 14M；修正后的长跑曾在 `seq=14867468` 暴露
  `MIGRATE_INFO_TYPE` 返回值缺口，已修为 QEMU 的 2，但修正后尚未重新跑
  Linux 长窗口。

### 差分 checkpoint

`DIFF_CKPT=1` 通过 `CKPT_REQ/CKPT_READY` 在 QEMU 单指令回调保存：

- `*.ram.gz`：128 MiB RAM 的 base/diff 页链；
- `*.dev.gz`：QEMU CPU/设备 VMState；
- `*.arch.gz`：PC、下一条 PC、GPR、SP、NZCV；
- `*.sys.gz`：PSTATE/EL/SP、DAIF、ELR/SPSR、VBAR、SCTLR/TCR/TTBR/MAIR、
  ESR/FAR/PAR、CPACR/MDSCR、CNTKCTL、TPIDR、PIR。

小镜像实测：`base-9.ram.gz` 约 249 KiB，`diff-19.ram.gz` 45 B；
`read-arch`、`read-sys` 和 RAM 恢复校验均通过。原始 RAM backend 默认在
测试结束后删除，避免留下 128 MiB 文件。

### QEMU/DUT 联合恢复

使用同一 seq=19 checkpoint、匹配的 virt/CPU/TCG 参数、QEMU `-incoming` 和
step 插件：

- `joint3`：RAM + arch sidecar 恢复后，QEMU/DUT 锁步 5 条全绿；
- `joint4`：再加入 sys sidecar 注入，QEMU/DUT 锁步 5 条全绿；
- `make checkpoint-dut-smoke`：DUT 复位后注入 EL1h 架构状态，冲刷流水线，
  连续 10 条提交与基线逐条一致。

## 3. 当前限制

1. Generic Timer 的 `CNTPCT/CNTVCT`、CVAL、CTL、ISTATUS 尚未进入 sys sidecar
   或 DUT 注入；设备 VMState 虽保存，但 RTL Timer 仍需单独恢复。
2. GIC pending/enable/priority 状态尚未注入；缓存/TLB 可在恢复时清空并重建，
   但 Timer/GIC 不能简单清空。
3. sys sidecar 已覆盖 Linux 需要的主要 EL1/MMU 控制寄存器，但尚未验证
   `SCTLR.M=1` 的真实 Linux checkpoint 恢复；DUT 的 MMU walker 在恢复点的
   在途状态仍需明确冲刷策略。
4. manifest 目前为 TSV，尚未加入 Image/DTB/QEMU SHA256；链压缩/自动淘汰
   仍待实现。总大小超过 512 MiB 时原型拒绝新 checkpoint，避免断链。
5. QEMU 仍输出缺少 vmdescription 的提示；不影响已验证的 `-incoming` 状态
   恢复，但后续可补完整 migration 描述段。

## 4. 资源与安全状态

- 当前无 QEMU、协调器或 Verilator 长时进程。
- 未启动 Linux 长跑；不要在 Timer/GIC/DUT 恢复闭环前设置高 `MAX_INSNS`。
- 独立 trace 长跑曾达到约 1.2 GiB RSS，禁止继续使用该模式；Linux 只用
  `mode=step`、`tb-size=64`、单物理核、低频进度日志。

## 5. 下一步顺序

1. 审计 QEMU `ARMGenericTimer` 与 RTL Timer 字段，加入 timer sidecar 和
   Verilator 注入；写一个 `hard_timer` checkpoint restore smoke。
2. 增加 GIC pending/enable 的最小单核状态摘要；验证 IRQ 恢复边界。
3. 完善 manifest 哈希和链恢复校验；再验证 `SCTLR.M=1` 的 MMU 恢复。
4. 以 checkpoint 恢复到 14.8M 附近，继续 Linux step 锁步；下一分歧仍保存
   `step_fail.txt` 和最近 checkpoint 链，不生成全量长 trace。
