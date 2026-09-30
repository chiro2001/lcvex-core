# LCVEX 交接文档 034：Linux 启动 ISA 缺口闭合（P6 准备）

日期：2026-08-24（Asia/Shanghai）
前置：handoff 033（M3 收尾，Gate D 全绿）。

## 1. 方法：真实内核实证缺口清单

下载并本机构建 **Linux 6.6**（`build/linux-6.6/`，defconfig，
`arch/arm64/boot/Image` 35MB），在 QEMU
`-cpu max,has_el3=false,has_el2=false` 下用 lcvex 插件 trace 早期启动
（前 15 万条提交，内核打印到 "random: crng init"）。新增两个脚本：

- `scripts/linux_insn_gap.py`：对 head.S/proc.S/entry.S 做宏级助记符
  盘点（参考）；
- `scripts/kernel_trace_gap.py`：对真实 trace 去重编码反汇编 → 与
  ISA_SCOPE 支持集比对，产出**权威缺口清单**。

实证缺口：`rev`（11300 次）、`ccmp`、`clz`、`bti`；系统寄存器
CurrentEL/MIDR/ID_AA64*/CTR_EL0/CPACR/MDSCR/PMUSERENR/CNTKCTL/TPIDR/
TPIDRRO/TCR2/PIR/PIRE0/SP_EL0/CNTFRQ；MSR immediate daifclr。

## 2. 实现（提交 `3581175` + `6f03629`）

- **指令**：REV/REV16/REV32/CLZ/CLS（新 ALU 操作码）；CCMP/CCMN
  （条件真=比较标志、假=NZCV 立即数，imm5 零扩展——QEMU
  `tcg_constant_i64(a->y)` 语义，非符号扩展）；BTI 按 NOP；
  MSR-i DAIFSet/DAIFClr（更新 PSTATE.DAIF）、SPSel（切换 SP 银行，
  提交包上报新可见 SP；EL0 执行 UDEF）；
- **系统寄存器**：只读 ID 族按 QEMU `-cpu max` 探针值硬编码（pkg
  常量）；读写寄存器复位 0，写掩码与 QEMU 一致（PMUSERENR 低 4 位、
  TCR2 0x70012=PIE|AIE|A2|FNG0|FNG1）；EL2 读 0 写忽略；
- **修复真实 bug**：addsub-ext 与 reg-offset 的 rm 未登记读源 →
  load/STXR 晚写回时读到陈旧值（随机回归复现：`sub w7,w4,w1,uxth #4`
  在 STXR 写 w1 后错误）。

## 3. 验证

- `hard_p6_isa` 定向 75 条：base + 全缓存锁步全绿；覆盖字节反转、
  CLZ/CLS 边界、CCMP/CCMN 真/假路径（mrs nzcv 观察）、BTI、DAIF
  （经 SVC 的 SPSR 观察）、SPSel（EL1t 向量 + SP 银行 + ERET 恢复）、
  26 个系统寄存器 MRS/MSR 往返与只读 ID 值；
- 随机 seed 1~3 × 100k（新族 rev/clz/ccmp/ccmn/bti/daif 入随机）全
  PASS；`make test` 全绿；check-encoders 73 条；覆盖记账新增
  rev/clz/ccmp/ccmn/bti 族命中；
- QEMU 探针记录（build/linux-src + /tmp 探针）：ID 寄存器值、TCR2 掩码、
  PMUSERENR 掩码、CurrentEL=EL<<2（op1=0, op2=2 编码）。
- **Gate D 全量 PASS**（`build/logs/gate_d_p6_*.log`）：make test、
  coverage、M2-4b 35 组 × base/cache（含 hard_p6_isa）、delay2、
  P5a-Hardening、Gate C/P5a/P4b、随机 300,007 条（61 族）、覆盖记账、
  baremetal-C；microbench 通过。

## 4. 关键命令

```bash
make test
bash sim/difftest/run_m2_4b.sh --only hard_p6_isa
make difftest-random-multi
python3 scripts/kernel_trace_gap.py /tmp/kernel_boot.trace --limit-insns 150000
```

## 5. 已知限制与下一步

- QEMU 对 `msr cpacr_el1/mdscr_el1, #-1` 会停住（QEMU 边界行为）；
  内核与测试不用该值，RTL 按 raw 存储（QEMU 对可用值同语义）；
- `LDXP/STXP`、LSE 原子、`LDAR/STLR`、WFE/SEV 仍 UDEF（后续）；
- **P6 剩余**：PL011 UART、Generic Timer、GICv2、DT、PSCI；RTL 内存
  模型 1 MiB SRAM 需扩展（QEMU virt RAM 128 MiB）才能加载内核镜像。
