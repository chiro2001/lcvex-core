# LCVEX 交接文档 053：GICv2 checkpoint sidecar

日期：2026-08-24（Asia/Shanghai）
前置：handoff 052（Generic Timer checkpoint sidecar）。

## 1. 结论

本轮把单核 GICv2 状态加入差分 checkpoint 链，并完成 QEMU `-incoming` 与
Verilator DUT 的联合恢复。新 sidecar 是独立压缩的 `*.dev.gic.gz`，manifest
从 10 列扩展到 11 列；旧的 7/8/9/10 列链仍可读取。

RTL `lcvex_gic` 只建模 96 个 IRQ，而 QEMU virt GICv2 实例通常报告 288 个
IRQ（256 SPI + 32 私有 IRQ）。保存前检查 96 以外的 enable/pending/active：
若存在 live 状态则拒绝发布，不能静默丢失中断。

## 2. sidecar 字段

未压缩 payload 固定 732 字节、little-endian、magic `LCVXGIC1`：

- `ctlr`、单核 `cpu_ctlr`、PMR、running priority、current pending、BPR、ABPR；
- 前 96 IRQ 的 `enabled/pending/active/level/edge/group`；
- 前 96 IRQ 的 priority；
- 16 个 SGI 的单核 source-pending 摘要。

QEMU 的内部 IRQ mask 只取 CPU0 bit；DUT 的 running/current pending 由恢复后的
active/priority/控制状态重新组合，sidecar 字段保留用于校验和诊断。

```bash
python3 sim/difftest/checkpoint.py read-gic \
  --chain <chain-dir> --seq <n>
```

## 3. 实现范围

- `qemu/plugins/lcvex_protocol.h`：`CKPT_REQ` 增加 `gic_path`；消息缓冲区扩展
  到 4096 字节（四个路径 + 头部超过原 2048 上限）。
- QEMU fork：从唯一 `TYPE_ARM_GIC` 对象读取 GICState，写出 732 字节摘要；
  可重放补丁为 `0001` → `0002` → `0003` → `0004-lcvex-gic-checkpoint.patch`。
- 协调器：压缩/manifest、`--restore-gic`、`--selftest-gic` 和 DUT GIC 数组
  注入；GIC sidecar 失败会让 checkpoint 原子保存失败，不会发布半条链。
- `checkpoint.py`：`read-gic` 和第 11 列 manifest。
- `checkpoint_gic_smoke.sh` / Makefile：可重复低资源联合恢复入口。

## 4. 验证证据

在 conda 环境 `lcvex`、单机串行执行：

```bash
make checkpoint-gic-smoke
bash sim/difftest/run_m2_4b.sh --only hard_gic
```

结果：

- `hard_gic` 捕获 seq=29 的 GIC sidecar，`read-gic` header/size/num_irq 校验通过；
- DUT 从 seq=29 架构摘要 + GIC sidecar 继续 5 条 MMIO 指令全绿；
- 同一 seq=29 的 QEMU device VMState + GIC sidecar 与 DUT 联合恢复 5 条全绿；
- `hard_gic` base/cache 两配置各 50 条逐指令锁步全绿；
- Generic Timer 的 `make checkpoint-timer-smoke` 仍全绿，且其 checkpoint
  现在同时捕获/注入 GIC sidecar；
- 最大运行时 RAM backend 仍为 128 MiB，脚本退出时清理；结束时无 QEMU/
  协调器/Verilator 长命进程。

## 5. 限制与下一步

1. 当前只支持 `TYPE_ARM_GIC`（GICv2）和单 vCPU；GICv3、虚拟化 list
   registers、多核 SGI source mask 不在范围内。
2. 真实 Linux checkpoint 还需验证 IRQ 正在 active、Timer PPI 电平和 GIC
   pending 同时存在时的恢复边界。
3. 完善 manifest 的 Image/DTB/QEMU SHA256、链校验和压缩/淘汰策略。
4. 在 `SCTLR.M=1` 的 Linux checkpoint 上验证 TLB/MMU 冲刷，再恢复到 14.8M
   附近继续 step 锁步；不恢复到高内存全量 trace 模式。
