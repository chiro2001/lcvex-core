# LCVEX 交接文档 040：P6 内核锁步基建 + 4 个真 bug 修复（卡点在 DTB 写源定位）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 039（内核 trace 800k + LDUR/STUR 族）。

## 1. 状态总览

- **分支**：本地 `main` HEAD=`839408a`；本轮全部修改**尚未提交**（工作区脏）。
- **阶段**：P0–P5/M3 完成；P6 内核锁步差分进行中，当前卡在 **seq=1794**。
- **后台**：交接时无正在运行的 lockstep/QEMU/Verilator 进程；最新 trace 为
  `/tmp/kernel_boot8.trace`（06:13，QEMU 侧 trace），Gate D 上次全量
  PASS 为 `build/logs/gate_d_p6_ldur_20260824_060400.log`（本轮基建改动后
  未重跑全量，提交前需补 `make test` + Gate D）。

## 2. 内核锁步基建（已完成并生效）

1. **协调器多镜像加载**（`sim/difftest/lockstep_coordinator.cc`）：
   新增 `--image2/--image3`、`--init-pc`、`--boot-dtb/--boot-entry`；
   RESET 时写 QEMU `bootloader_aarch64` 等价序列
   （`ldr x0,x4; br x4` + 字面量 DTB 地址/入口），
   DUT init-pc 设为 bootloader 入口 0x40000000。
2. **`run_lockstep_step.sh` KERNEL=1 模式**：QEMU 走 `-kernel/-dtb`，
   协调器写 bootloader@0x40000000（x0=DTB@0x44000000、跳 0x40080000）、
   内核@0x40080000、DTB@0x44000000。
3. **Makefile `lockstep-build-kernel`**：`RESET_PC_KERNEL := 64'd1073741824`
   = 0x40000000（**bootloader 入口**；注意文件内第 187 行注释误写为
   0x40080000，需修正注释）。
4. **soc_tb/mem_ram 调试口**：`RESET_PC` 参数化；mem_ram 增加
   `dbg_addr/dbg_rdata` 同步读口（协调器 `read_mem` 用它 dump 多处 RAM）；
   协调器失败时 dump 多个地址区间。
5. **内核输入**（/tmp）：`/tmp/Image-t80000`（Image 副本，text_offset
   补丁=0x80000）、`/tmp/virt-gic2-boot.dtb`（QEMU dumpdtb → dtc 去填充 →
   编辑 /chosen 加 bootargs、删 rng/kaslr seed）。

## 3. QEMU 启动布局（实证，勿再猜）

```
0x40000000  bootloader（6 指令 + 4 字面量：x0=DTB=0x44000000、entry=0x40080000）
0x40080000  内核 Image（text_offset 补丁 0x80000 生效）
0x44000000  DTB（QEMU 放置，非 0x40000000！）
init pc = 0x40000000
```

- `-kernel` 模式若 Image text_offset=0，入口 0x40000000 会与 bootloader
  重叠 → 必须补丁 text_offset=0x80000（`struct.pack_into('<Q', d, 8, 0x80000)`）。
- 锁步变体 QEMU 与协调器同时从 bootloader 开始，两侧逐条提交对齐。

## 4. 已修复 4 个真 bug（首分叉 33 → 1622 → 1794）

1. **变量移位 LSLV/LSRV/ASRV/RORV**：pkg `ALU_ROR`、alu ROR 旋转、
   decode 新分支（`insn[30:21]==10'b0011010110 && insn[15:12]==4'b0010`）、
   a64 `_enc_vshift`。首个指令 `lsl x2,x2,x3` 此前 UDEF。
2. **RET Xn**：RET 目标寄存器是 **Rn（insn[9:5]）不是 Rm**；内核用
   `ret x28`。RTL 曾硬编码 x30。
3. **CPACR_EL1 op2=2**（`S3_0_C1_C0_2`）：RTL/a64 原用 op2=0（旧编码），
   QEMU 11.1.0 实际 op2=2；RTL decode 与 a64.py sysreg 表已同时改。
4. 另加 `hard_ttbr1` 定向测试（TTBR1 线性映射高 VA→PA，PA 0x40000000
   2MB 块）已 PASS，证明 TTBR1 基础正常（未发现 MMU bug）。

## 5. 当前卡点：seq=1794 分叉，写 0x42400000 的指令未定位

- 故障指令：`ldr w0,[x0]`，x0=0x42400004；QEMU 读 0x1c8b0000、
  DUT 读 0x7e1e0000（两边初值不同，RTL RAM dump 与 QEMU 初始 dump
  均为零，说明 0x42400000 内容来自内核更早的写入）。
- 0x42400000 由 seq 215 `add x1, x1, #0x200, lsl #12`（x1: 0x42000000 →
  0x42400000）产生；seq 215–221 是页表填充循环
  `str x12, [x0, x10, lsl #3]`，0x42400000 是**新页表映射的物理页**。
- 推测：DTB 通过该映射被 memcpy（seq≈1730–1768 的 `__pi_memcpy` /
  `early_fdt_map` 附近），但协调器 DBG（命中 0x42400000/0x02400000 的
  DUT store 与 QEMU store）**两侧均无命中**——可能写入指令的
  commit_pkt 未覆盖（某 store 形式被 RTL 按 NOP，且 QEMU 插件不记账），
  或写入发生在更早阶段。前 1794 条中 `dc` 全为 `dc ivac`（无写副作用），
  无 `dc zva`。

## 6. 下一步（按序）

1. **定位写 0x42400000 的指令**：
   - 协调器 DBG 的 QEMU store 打印扩大到 0x0000_0000..0x5000_0000 全打印，
     找真正写入该地址的 QEMU commit；
   - 或 `qemu_probe.py --icount` 单步探针 seq 215–1794，抓写该地址的指令
     编码（重点 seq≈1730–1768 memcpy）；
   - 反汇编 0x41b47440 上方页表映射函数，确认 DTB 拷贝源；
   - 同时核对 seq 215 `str x12,[x0,x10,lsl #3]` 两侧 x0/x10——若 RTL 与
     QEMU 页表内容不同，后续 PTW 翻译也会分叉。
2. 修复后继续内核锁步迭代；**预计后续缺口**：LSE 原子（LDADD 等，
   内核 alternatives 补丁）、LDXP/STXP、WFE/SEV、SMC（PSCI）、更多 ID
   寄存器、`mrs x0, rndr`（trace 已见）。
3. 提交本轮（含 2–4 节全部内容），补 `make test` + Gate D 全量，
   更新 docs/ROADMAP/PROJECT_STATUS 与本 handoff，然后继续推进至
   memblock/GIC init/timer IRQ，最终 Gate E。

## 7. 关键命令

```bash
make lockstep-build-kernel   # RESET_PC=0x40000000 内核锁步变体
IMAGE=/tmp/Image-t80000 IMAGE2=/tmp/virt-gic2-boot.dtb MAX_INSNS=20000 KERNEL=1 \
  COORD=$PWD/build/verilator_lockstep_kernel/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh   # 当前在 seq=1794 分叉
python3 scripts/kernel_trace_gap.py /tmp/kernel_boot6.trace --limit-insns 800000
```

## 8. 未提交修改文件（提交时逐一核对）

`Makefile`、`rtl/lcvex_alu.sv`、`rtl/lcvex_decode.sv`、
`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_pkg.sv`、`sim/difftest/a64.py`、
`sim/difftest/lockstep_coordinator.cc`、`sim/difftest/run_gate_d.sh`、
`sim/difftest/run_lockstep_step.sh`、`sim/difftest/run_m2_4b.sh`、
`sim/difftest/test_program.py`、`tb/sv/lcvex_*_tb.sv`（soc/core/背压/
L1I/L1D/L2/memif/mmu 的 dbg 口与参数化）。

**已知小瑕疵**：Makefile 第 187 行注释写 `RESET_PC=0x40080000`，实际
`RESET_PC_KERNEL=0x40000000`（bootloader 入口），提交时一并修正注释。
