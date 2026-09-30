# LCVEX 交接文档 041：内核锁步推进至 713k 全绿 + 3 个真缺口修复

日期：2026-08-24（Asia/Shanghai）
前置：handoff 040（内核锁步基建 + LSLV/RET/CPACR，卡在 seq=1794）。

## 1. 状态总览

- **分支**：本地 `main` HEAD=`839408a`；本轮修改**尚未提交**（工作区脏）。
- **内核锁步**：从 seq=1794 推进到 **713k 条全绿**（脚本 60s 超时被杀，
  非失败；协调器日志最后 713479 条全部 OK）。QEMU 侧 800k trace 对应
  的早期启动已全部通过逐指令差分。
- **后台**：Gate D 全量回归正在运行（`build/logs/gate_d_p6_postpre_*`）。

## 2. 三个真实缺口与修复

### 2.1 DTB 一致性（非指令缺口，但导致 seq=1794 分叉根因之一）

- QEMU `-dtb` 加载后会对 FDT 做**非幂等**修改（`create_randomness` 注入
  kaslr/rng seed + libfdt buffer 膨胀），totalsize 每次递增
  （0x1e7e → 0x8b1c → 0x24e20）。协调器把磁盘原文件写进 DUT 与 QEMU
  实际内存不一致，校验函数读 DTB 字段时分叉。
- **修复**：锁步 KERNEL 模式改用 **QEMU 自己生成 FDT**：
  `-machine virt,gic-version=2,dtb-randomness=off` + `-append bootargs`
  （无 `-dtb`），先 `pmemsave 0x44000000 0x100000` 导出 QEMU 实际 FDT
  （`/tmp/qemu-gen-fdt-1m.bin`），协调器 image3 用该导出文件。
- 实证：QEMU 与 DUT 的 VA 0x42400000 都映射到 PA 0x44000000（DTB），
  翻译一致；差异仅在 DTB 内容。

### 2.2 LDR/STR 单寄存器 pre/post-index（seq=1833）

- `ldrb w6,[x0],#1`（0x38401406，post-index）此前 UDEF：decode 只实现
  LDUR/STUR（bits[11:10]=00），post/pre 的 01/11 落入兜底 `valid=0`。
- **修复**（`rtl/lcvex_decode.sv`）：LDUR 分支条件放宽为
  `bits[11:10] inside {00,01,11}`；01=post-index（先访存 `[rn]` 再
  `rn+=imm9`）、11=pre-index（先 `rn+=imm9` 再访存）。基址写回复用
  wb3 通道（Rn=31 走 sp 写回）。a64.py 补 26 个编码器（8/16/32/64 位
  post/pre + 符号扩展 X/W）。

### 2.3 DCZID_EL0（seq=216217）

- `mrs x3, dczid_el0`（0xd53b00e3，S3_3_C0_C0_7）此前 UDEF；QEMU
  返回 4（dc zva 64B 块，DZP=0）。decode 加 SREG_DCZID_EL0，pkg 加
  `DCZID_EL0_VAL=4`，并允许 EL0 读（与 CTR_EL0/ID 寄存器同豁免）。

### 2.4 DC ZVA（seq=216231）

- `dc zva, x8`（0xd50b7428，S1_3_C7_C4_1）此前 UDEF；QEMU helper 直接
  清内存、插件不记账 store。
- **修复**（`rtl/lcvex_core.sv` + decode）：新增 `MAINT_DC_ZVA`，核心
  维护状态机加 `MS_DCZVA_WRITE`：VA 翻译（复用 maint_va_pending 数据
  翻译）→ 按 `DCZID_EL0` 块大小（64B）发 8 次 8 字节 dmem 清零写
  （we=1, strb=0xFF, wdata=0）。维护提交不报 store（QEMU 插件也不报），
  协调器 store 列表两侧均为空，天然一致；后续 guest 读已清零地址时
  寄存器差分覆盖正确性。

## 3. 测试

- **`hard_postpre` 定向锁步**（70 条，base + 全缓存配置全绿）：post/pre
  各宽度读写、正/负偏移、符号扩展 X/W、str post/pre、DCZID_EL0、
  dc zva 64B 清零后读回验证。**注意**：8 字节 stur 必须 8 字节对齐，
  QEMU 对未对齐报 alignment fault（FSC=0x21，SCTLR 对齐检查），测试
  数据区布局已对齐。
- `check-encoders` 73 条 PASS；`make test` P0 全绿；M2-4b 全量
  base+cache 26 组 PASS（含新 hard_postpre）。
- **tb 修复**：mem_if/l1d/l1i/l2/mmu tb 的 mem_ram dbg 口连接此前存在
  缺逗号/`32\'d0` 转义残留/声明位置错误，已统一修复（从 HEAD 恢复后
  重新应用）。

## 4. 关键命令（更新后）

```bash
# 导出 QEMU 生成 FDT（锁步前执行一次）
cat >/tmp/dump_fdt.txt <<'EOF'
pmemsave 0x44000000 0x100000 "/tmp/qemu-gen-fdt-1m.bin"
quit
EOF
qemu-system-aarch64 -machine virt,gic-version=2,dtb-randomness=off \
  -cpu max,has_el3=false,has_el2=false -accel tcg,thread=single \
  -icount shift=0,align=off,sleep=off -kernel /tmp/Image-t80000 \
  -append "console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/bin/sh nokaslr panic=-1" \
  -display none -serial null -S -monitor stdio < /tmp/dump_fdt.txt
# 内核锁步（QEMU 无 -dtb，-append + dtb-randomness=off）
IMAGE=/tmp/Image-t80000 IMAGE2=/tmp/qemu-gen-fdt-1m.bin MAX_INSNS=800000 KERNEL=1 \
  COORD=$PWD/build/verilator_lockstep_kernel/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh
```

**注意**：`/tmp/run_ls_fdt.sh`（临时脚本）是本次迭代用；正式流程需把
FDT 导出 + 新 QEMU 参数固化进 `run_lockstep_step.sh` 与文档。

## 5. 下一步

1. 固化 KERNEL 锁步流程（run_lockstep_step.sh 内嵌 FDT 导出 + 新参数）。
2. 继续推进更深启动（memblock/earlycon/GIC init/timer IRQ），预计缺口：
   **LSE 原子（LDADD 等，alternatives 补丁）、LDXP/STXP、WFE/SEV、
   SMC（PSCI）、更多 ID/系统寄存器、MRS rndr**。
3. Gate D 完成后提交本轮（文件清单见下），更新 ROADMAP/PROJECT_STATUS/
   ISA_SCOPE（ISA_SCOPE 已更新）与本 handoff。

## 6. 未提交修改文件

`Makefile`、`rtl/lcvex_alu.sv`、`rtl/lcvex_decode.sv`、
`rtl/lcvex_mem_ram.sv`、`rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、
`sim/difftest/a64.py`、`sim/difftest/lockstep_coordinator.cc`、
`sim/difftest/run_gate_d.sh`、`sim/difftest/run_lockstep_step.sh`、
`sim/difftest/run_m2_4b.sh`、`sim/difftest/test_program.py`、
`qemu/plugins/lcvex_difftest.c`（DBG mem 打印 + MEM_RW 注册）、
`tb/sv/lcvex_*_tb.sv`（dbg 口 + 修复）、`docs/ROADMAP.md`、
`docs/PROJECT_STATUS.md`、`docs/ISA_SCOPE.md`、
`docs/handoffs/040-kernel-lockstep.md`。

**注意**：插件 DBG 打印（`DBG mem` 命中 0x424 区域）与 MEM_RW 注册是
调试残留，提交前评估保留（对后续调试有用）或收敛。
