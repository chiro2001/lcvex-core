# LCVEX 交接文档 035：RTL 内存模型扩展为 128 MiB（P6 平台准备）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 034（P6 Linux 启动 ISA 缺口闭合）。

## 1. 变更：内存窗口 1 MiB -> 128 MiB（与 QEMU virt 对齐）

- `lcvex_mem_ram`：默认 DEPTH 128 MiB（`1<<27`），默认基址
  0x40000000；`lcvex_core/decode/mmu` 的 `SRAM_BASE/SRAM_TOP` 默认
  0x40000000/0x48000000；
- `lcvex_soc_tb`（锁步/协调器/Cocotb 仿真顶层）：core 实例化
  `RESET_PC=0x44000000`、`SRAM_BASE=0x40000000`、`SRAM_TOP=0x48000000`；
  `lcvex_mem_ram` 实例化 `DEPTH=1<<27, SRAM_BASE=0x40000000`；
- **差分测试程序基址保持 0x44000000（数据区 0x44080000）**：QEMU 11.1.0
  的 virt 机器在 `machine_done` 无条件调用 `arm_load_dtb`，把 DTB 写入
  0x40000000（实测 ROM 区域 0x40000000..0x40100000）；把程序基址迁到
  0x40000000 会触发 "Some ROM regions are overlapping" 并导致 QEMU 退出。
  这是本轮实测发现并回退的教训：**RTL 内存窗口可以大于差分程序所在区，
  但程序加载点必须避开 QEMU 的 DTB 保留区**。

## 2. 新增测试

- `lcvex_mem_if_tb` 新增大容量实例（`DEPTH=1<<27`，base 0x40000000）：
  64 MiB 偏移写读回、TOP-8（0x47FFFFF8）整宽写读回、TOP（0x48000000）
  越界读 fault、TOP 跨顶 8 字节写 fault；
- `hard_big_mem` 定向锁步：1 MiB + 4 KiB 镜像经 SoC 程序加载口写入，
  代码在 0x44000000，标记数据在 0x44100000（旧 SRAM_TOP）；若 RAM 在
  1 MiB 回绕，`ldr x3,[x2]` 会读到 NOP 与 QEMU 差分失败。已注册进
  `run_m2_4b.sh` M2_TESTS 与 `run_gate_d.sh` DELAY2_TESTS。

## 3. 验证结果（全绿）

- `make test`（toolcheck/lint/SV 单测/Cocotb/check-encoders 73 条）全绿；
- `make coverage` 全绿；
- **Gate D 全量 PASS**（`build/logs/gate_d_p6_mem_20260824_043531.log`）：
  96 个 OK(green) 步骤、0 失败——M2-4b 19 组 × base/cache、
  delay2 并行 19 组 + random_smoke、P5a-Hardening 13 组、Gate C 7 组、
  P5a 3 组、P4b、随机 seed 1~3 × 100k（300,007 条，61 族）、覆盖记账、
  baremetal-C 200 条；
- `hard_big_mem` base 锁步 6 条 PASS（标记读回一致）；
- `make microbench` PASS（mb_all 2304 cycles）。

## 4. 关键命令

```bash
bash sim/difftest/run_gate_d.sh --parallel
IMAGE=build/difftest/hard_big_mem.bin MAX_INSNS=6 \
  COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh
make microbench
```

## 5. 已知限制与下一步

- QEMU virt 的 DTB 保留区（0x40000000..0x40100000）在差分侧不可被程序
  占用；内核镜像后续按 QEMU `-kernel` 约定加载在 0x40080000（DTB 限界
  在镜像低地址之前，不重叠），RTL 侧届时同样加载内核于 0x40080000；
- 128 MiB RAM 数组使每个 Verilator 锁步模型运行内存约 128~135 MiB，
  并行回归（planner 绑核、50% 资源）实测无压力（29 GiB 主机）；
- **P6 剩余**：PL011 UART -> Generic Timer -> GICv2 -> Device Tree ->
  PSCI -> Linux early boot（Gate E）。
