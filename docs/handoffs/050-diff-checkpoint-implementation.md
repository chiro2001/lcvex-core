# LCVEX 交接文档 050：差分 checkpoint 实施方案

日期：2026-08-24（Asia/Shanghai）

## 1. 当前结论

建议实现差分 checkpoint，但必须把它作为独立的验证基础设施阶段。当前仓库原本
只有协调器通过 QEMU HMP `migrate exec:gzip` 保存的**全量** VM 状态；本轮已
加入差分保存原型，但
`build/difftest/ckpt/ckpt-299999.gz` 没有 manifest，不能当作差分链，也不能
直接用于本轮 Linux/PSCI 修正后的恢复。

## 2. 目标与边界

第一版只覆盖项目当前固定配置：AArch64、单 vCPU、TCG `-icount`、无 DMA
设备、QEMU 11.1.0。checkpoint 必须同时恢复：

1. QEMU CPU/设备/计时器状态；
2. QEMU RAM 的基线或增量页；
3. checkpoint 序号、基线序号、镜像/DTB/QEMU/格式哈希。

只保存 CPU 寄存器而不保存设备状态是不安全的：Generic Timer、GIC 和
PSCI 探测都可能改变后续执行轨迹。

## 3. 文件格式

每条 checkpoint 使用一个目录，避免把未完成的单文件误认为可恢复：

```text
ckpt/<chain-id>/
  manifest.tsv        # 原型链：kind/seq/parent/ram_bytes/pages/文件路径
  base-<seq>.ram.gz   # 链中唯一的全量 RAM 基线
  base-<seq>.dev.gz   # CPU/设备 vmstate（QEMUFile，压缩）
  base-<seq>.arch.gz  # DUT 注入用架构摘要（GPR/SP/NZCV/PC）
  base-<seq>.sys.gz   # QEMU PSTATE/EL/MMU/系统寄存器 sidecar
  base-<seq>.dev.timer.gz # QEMU Generic Timer（虚拟计数/CVAL/CTL）sidecar
  diff-<seq>.ram.gz   # 自上次保存以来的页记录
  diff-<seq>.dev.gz   # 该 seq 的 CPU/设备 vmstate
  diff-<seq>.arch.gz  # 该 seq 的架构摘要
  diff-<seq>.sys.gz   # 该 seq 的系统寄存器/MMU sidecar
  diff-<seq>.dev.timer.gz # 该 seq 的 Generic Timer sidecar
```

`diff` 的 RAM 记录按 QEMU RAMBlock 编号、页号、页长度、页数据编码；页大小
固定记录为 4096，但恢复端必须校验 QEMU 实际 page size。设备状态使用
QEMU 已有的 `qemu_save_device_state()`/`qemu_load_device_state()` 接口，
避免复制 CPU、Timer、GIC 的私有状态。

## 4. 保存与恢复协议

### 保存

1. 协调器只在一个 COMMIT 已比较、尚未发送 ACK 且没有 pending PRE 时请求保存。
2. `CKPT_REQ` 在 QEMU 单指令回调上下文保存 CPU/设备 vmstate；插件随后
   发送 `CKPT_READY` 并继续等待 ACK，协调器在此窗口读取共享 RAM backend，
   因而不需要 QMP `stop/cont` 竞态。
3. 首次保存生成 `base`；之后每次生成 `diff`，并写临时目录后通过原子
   rename 发布 manifest，防止进程中止留下“看似完整”的文件。
4. 每个 diff 都记录前一条 `base_seq`/`parent_seq`；链断裂、哈希不匹配或
   QEMU 版本不一致时拒绝恢复。

### 恢复

1. 以同一 machine、CPU、Image、DTB 和 QEMU build 启动并暂停 QEMU。
2. 加载 base 的 CPU/设备状态和全 RAM，再按 parent 顺序应用 diff；每个
   diff 应用后校验页数、CRC/SHA256 与 `seq`。
3. 恢复后先执行一个“提交摘要”探针（PC、x0..x30、SP、NZCV、下一条 PC），
   与保存时的摘要完全一致，才允许进入锁步。
4. RTL 侧第一版使用显式 checkpoint 注入口灌入寄存器和 RAM；没有 DUT 恢复
   摘要时，禁止宣称 checkpoint 可用于锁步快进。

## 5. 磁盘和资源策略

- 压缩在 checkpoint 目录内完成，不把中间未压缩 RAM 写入 `/tmp`。
- 目标保留 `1 base + 5 diff`；当前原型不会删除仍被后续 diff 引用的
  parent，而是在链达到 512 MiB 上限时拒绝发布新 checkpoint；链压缩后再
  实现自动淘汰。
- manifest、状态文件和临时文件都写到 `build/difftest/ckpt`；CI 只上传
  经过大小检查的 release 资产，不把大文件提交 git。
- 保存耗时和 RSS 都记录到 manifest；若保存期间超过 50% 主机资源预算，
  测试规划器应暂停新任务而不是并行启动更多 QEMU。

## 6. 当前实现与分阶段验收

1. **已完成 L1-save/L2 原型**：`DIFF_CKPT=1` 使用共享 128 MiB RAM
   backend，QEMU fork hook 保存设备状态；`hard_psci` 29 条、每 10 条保存
   的 base/diff 锁步全绿。`base-9.ram.gz` 约 249 KiB，`diff-19.ram.gz`
   45 B；新增 `*.arch.gz` 架构摘要，`checkpoint.py restore-ram` 还原 RAM
   后与 backend `cmp` 全等，`read-arch` 可独立校验恢复 PC/GPR/NZCV；
   `--selftest-arch diff-19.arch.gz` 已用实际 checkpoint 摘要继续 5 条提交
   并通过；附加 `--selftest-ram restore-ram.bin` 的 128 MiB RAM 灌入路径
   也已通过同一 smoke；新增 `*.sys.gz` 保存 PSTATE/EL/SP、ELR/SPSR、
   VBAR/SCTLR/TCR/TTBR/MAIR、ESR/FAR/PAR、CPACR/MDSCR、DAIF、TPIDR 等
   字段，`read-sys` 可校验。随后增加独立 `*.timer.gz`（80 字节压缩前）保存
   `CNTPCT/CNTFRQ/CNTVOFF/CNTPOFF`、物理/虚拟 CVAL 与 CTL（含 ISTATUS
   诊断位），`read-timer` 可校验。QEMU sidecar 的计数是下一条指令可见值，
   注入 RTL 时转换为 `cntpct_r=cntpct-1`，使 EX 级 MRS 的 `+1` 与 QEMU
   对齐；`make checkpoint-timer-smoke` 已在第一条 CNTPCT 后恢复并读取
   CNTVCT，锁步/恢复全绿。进一步用匹配参数启动 QEMU `-incoming` + step 插件，
   与 Verilator 从同一 seq=19 checkpoint 各锁步 5 条，`joint3` 全绿。
   加载 `*.sys.gz` 并通过 Verilator 系统寄存器注入的 `joint4` 也全绿。
2. **已完成 QEMU L1-load**：`checkpoint.py restore-qemu` 用匹配的
   machine/CPU/TCG 参数启动 `-incoming exec:<device-state>`，立即 QMP
   `stop` 后读取恢复摘要；seq=9 实测 PC=`0x44000028`、x0=`0x84000000`
   与保存点一致。QEMU 仍输出缺少 vmdescription 的提示，但状态加载成功；
   直接调用通用 `xen-load-devices-state` 仍被脚本禁止。
3. **协调器 L2 完善**：加入链 manifest 的镜像/QEMU 哈希、原子发布、保留
   策略和总大小限制；当前原型已记录 seq/parent/页数，但尚未接入完整哈希。
   本轮 QEMU hook 已整理到 `qemu/patches/0002-lcvex-checkpoint-hook.patch`；
   已在干净 QEMU 11.1.0 archive 上完成 `0001+0002` 的 `git apply --check`。
4. **DUT L3 原型**：`make checkpoint-dut-smoke` 已验证 Verilator 复位后
   注入 EL1h 的 GPR/SP/NZCV/下一条 PC、冲刷流水线，再执行 10 条提交，
   与连续运行结果逐条一致。Linux 级 MMU/TLB/cache 状态和更深平台设备状态
   仍待完成。
5. **Linux L4**：仅在 L1-L3 全绿后启用 `CKPT_EVERY`，先恢复到 14.8M
   附近定位 PSCI 缺口，再推进 15M+；失败时保留最近完整链和
   `step_fail.txt`。

## 7. 禁止事项

- 不把现有 `ckpt-*.gz` 全量迁移文件改名伪装成 diff。
- 不使用 `--skip` 代替恢复；`--skip` 只适用于 trace 回放，不能重建 QEMU
  CPU/设备状态。
- 不在差分 checkpoint 未通过小镜像恢复闭环前重新启动高内存 Linux 长跑。
