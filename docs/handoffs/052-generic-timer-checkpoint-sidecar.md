# LCVEX 交接文档 052：Generic Timer checkpoint sidecar

日期：2026-08-24（Asia/Shanghai）
前置：handoff 051（checkpoint 联合恢复闭环）。

> 当前 GIC sidecar 已在 [handoff 053](053-gic-checkpoint-sidecar.md) 中补齐；
> 本文保留 Timer 格式和计数边界的历史记录。

## 1. 本轮目标与结论

本轮补齐差分 checkpoint 中此前缺失的 Generic Timer 架构状态，并把它接入
Verilator DUT 恢复入口。采用独立的压缩 `*.timer.gz` sidecar，不改变已经发布
的 `*.sys.gz` 二进制格式；旧的 7/8/9 列 manifest 仍可读取，新的链使用第 10
列记录 timer 文件。

已完成：QEMU 捕获、协议传输、gzip 链发布、Python 读取校验、DUT 注入，以及
QEMU `-incoming` + DUT 的第一条计数器读取联合恢复 smoke。当前没有启动
Linux 长跑。

## 2. sidecar 格式

未压缩 payload 固定 80 字节、little-endian、`LCVXTMR1` magic：

| 字段 | 含义 |
| --- | --- |
| `cntpct` | QEMU `gt_get_countervalue()` 的虚拟计数（下一条指令可见值） |
| `cntfrq` | `CNTFRQ_EL0`（当前 virt 配置为 1 GHz） |
| `cntvoff_el2`/`cntpoff_el2` | QEMU EL2 counter offset，当前配置应为 0 |
| `cntp_cval`/`cntv_cval` | 物理/虚拟比较值 |
| `cntp_ctl`/`cntv_ctl` | 低 3 位 `ENABLE/IMASK/ISTATUS`；ISTATUS 同时保留用于诊断 |

实际链文件名为 `base-<seq>.dev.timer.gz` 或
`diff-<seq>.dev.timer.gz`，manifest 第 10 列指向该文件。命令：

```bash
python3 sim/difftest/checkpoint.py read-timer \
  --chain <chain-dir> --seq <n>
make checkpoint-timer-smoke
```

## 3. QEMU/DUT 边界语义

QEMU 在 COMMIT/ACK 窗口内保存 sidecar；`cntpct` 已经是下一条 guest 指令
读取时的值。RTL 的 `cntpct_r` 表示已提交计数，而 EX 级 Generic Timer MRS
读取 `cntpct_r + 1`。因此 DUT 注入执行：

```text
cntpct_r = sidecar.cntpct - 1 (mod 2^64)
```

CVAL 与 CTL 的低两位原样灌入，ISTATUS 不直接写入 RTL，而由
`enable && (cntpct >= cval)` 组合逻辑重新生成；这避免恢复一个已经过期的
派生位。当前 RTL 尚不支持 `CNTVOFF_EL2/CNTPOFF_EL2` 非零，恢复入口保留
字段但要求固定的单核 EL1 配置。

QEMU 的 device-only migration 同样不包含 `QEMU_CLOCK_VIRTUAL` 的计数基准。
联合恢复时，插件读取未压缩的 timer sidecar（由 smoke 从 `.gz` 临时展开），
在第一条指令回调前调用 fork API 设置仅限 difftest 的 unsigned counter offset；
因此不会改变普通 QEMU 运行或新鲜锁步的计时器语义。

## 4. 修改范围

- `qemu/plugins/lcvex_protocol.h`：`CKPT_REQ` 增加 `timer_path`。
- QEMU fork 及 `qemu/patches/0001-*.patch`、`0002-lcvex-checkpoint-hook.patch`、
  `0003-lcvex-timer-clock-restore.patch`：
  导出 `lcvex_timer_state`、保存 Generic Timer 字段，并支持
  `LCVEX_TIMER_RESTORE_PATH` 计数校正；补丁在干净 QEMU 11.1.0 基线上按
  `0001`、`0002`、`0003` 顺序 `git apply --check` 通过。
- `sim/difftest/lockstep_coordinator.cc`：压缩/manifest、`read_timer` 结构、
  `--restore-timer`、`--selftest-timer` 和 DUT 注入。
- `sim/difftest/checkpoint.py`：第 10 列 manifest、`read-timer` 子命令。
- `Makefile`：新增 `checkpoint-timer-smoke`。
- 路线图、项目状态和 handoff 文档同步更新。

## 5. 验证证据

在 conda 环境 `lcvex`、单机低负载下执行：

```bash
make checkpoint-timer-smoke
```

结果：

- `hard_timer` QEMU/RTL 首 2 条逐指令锁步通过；
- seq=0 的 `base-0.dev.timer.gz` 捕获成功；
- DUT 从 seq=0 架构摘要 + timer sidecar 恢复，下一条 `CNTVCT` 提交与连续
  DUT 完全一致；
- 同一 seq=0 的 QEMU `-incoming` device state + timer offset 与 DUT 联合执行
  下一条指令通过；统一脚本输出
  `PASS: Generic Timer checkpoint QEMU/DUT 联合恢复 1 条指令`；
- `make checkpoint-dut-smoke` 原有 GPR/SP/NZCV/PC smoke 仍通过；
- QEMU 11.1.0 fork 重建成功，插件重新编译成功；
- 实测 sidecar 压缩后约 44 字节，128 MiB RAM backend 在脚本结束后删除，
  不在 `/tmp` 留下原始 RAM。

## 6. 尚未完成与下一步

1. 增加 GIC pending/enable/priority 的最小 sidecar；Timer IRQ 电平恢复必须
   与 GIC 状态一起验证。
2. 完善 manifest 的 Image/DTB/QEMU SHA256、链校验和压缩/淘汰策略。
3. 在 `SCTLR.M=1` 的真实 Linux checkpoint 上验证 TLB/MMU 冲刷后再恢复到
   14.8M 附近，继续 Linux step 锁步；不要重新启用高内存全量 trace。

## 7. 资源与进程状态

本轮结束时无 QEMU、协调器或 Verilator 长命进程。后台存在的系统服务和
Codex/OpenClaw 进程未修改；后续测试继续遵守本地约 50% CPU/RSS 预算并绑定
物理核。
