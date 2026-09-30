# LCVEX 交接文档 026：M3 - 条件选择族 CSEL/CSINC/CSINV/CSNEG

日期：2026-08-24（Asia/Shanghai）
前置：handoff 025（乘加族）、PROJECT_STATUS M3。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（Data-processing 2-source 条件选择）

`CSEL/CSINC/CSINV/CSNEG` 四种条件选择（32/64 位）全部落地并与 QEMU
11.1.0 锁步一致：

### 1.1 解码（lcvex_decode.sv）

- 模式：`insn[28:24]==11010 && insn[23:21]==100 &&
  insn[30:29] inside {00,10} && insn[11]==0`；
- 变体区分：`insn[30:29]==00 && op=insn[10]==0` -> CSEL；
  `[30:29]==00 && op==1` -> CSINC；`[30:29]==10 && op==0` -> CSINV；
  `[30:29]==10 && op==1` -> CSNEG；
- 语义：条件真取 Rn，假取 Rm（CSEL）/ Rm+1（CSINC）/ ~Rm（CSINV）/
  -Rm（CSNEG）；32 位按低 32 位运算并零扩展，XZR 用 xzr（非 SP）；
- 条件在 ID 级用 `cond_taken(cond, nzcv)` 求值（与 B.cond 同一函数，
  NZCV 已前递），顺序单发射下等价 EX 级按架构 NZCV 选择；decode 把
  选中值合并进 `operand_a`，ALU 新增 `ALU_CSEL` 透传 op。

### 1.2 踩坑记录（编码位域）

- 最初误写为 `[30:29]==00 && [23:21] in {100,101}`，实际
  CSINV/CSNEG 的 `[30:29]==10` 且 `[23:21]` 仍为 `100`；
- 区分取反/取负家族的是 **`[30:29]` 两位**（00=CSEL/CSINC，
  10=CSINV/CSNEG），区分加一/取负的是 **bit10**（0=CSEL/CSINV，
  1=CSINC/CSNEG）；两次编码修正均靠锁步差分在第一条 csinv 处暴露。

### 1.3 裸机 C（baremetal/main.c）

- 新增 `csel_fn(a,b,c)`（`(a>b)?c:a`），从 volatile `g_arr[]` 读参；
- 反汇编确认真实生成 `cmp x0,x1; csel x0,x0,x2,ls`；
- `delay(8)` -> `delay(4)`，使目标代码（189 条）保持在 200 条锁步
  窗口内。

## 2. 验证结果（本机实跑）

- lint（Verilator `--lint-only -Wall`）通过；
- `hard_csel` 定向 51 条/55 提交：覆盖 eq/ne/ls/cs/gt/le/mi/pl 条件
  真/假两分支、CSINC 加一、CSINV 取反、CSNEG 取负、32 位回绕
  （`-0x80000000 -> 0x80000000`）与 XZR 操作数；base 55 条、全缓存
  60 条、delay2 60 条全部与 QEMU 一致；
- 裸机 C 200 条锁步一致（含真实 csel 路径）；
- `run_gate_d.sh` 全量 PASS：make test、coverage、M2/R1 28/28、
  hardening 23/23、delay2 13 项、Gate C/P5a/P4b、随机 100k、裸机 C。

## 3. 已知限制

- 条件按 ID 级 NZCV 求值并合并进操作数（与 B.cond 同机制），对顺序
  单发射语义完全正确；未来若引入乱序/多发射需改为 EX 级按流水线 NZCV
  选择；
- 寄存器变量移位（LSLV/LSRV/ASRV）、ROR、BFM、LDR literal、exclusive
  仍不支持（M3 剩余 / P6）。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，本阶段提交见 git log；
- M3 剩余：**BFM**（位域插入，O0 暴露 bfi）、**LDR literal**（启动/
  跳转表）、**exclusive**（P6 前）；
- 随后对照 Linux `head.S` 缺口清单补齐剩余启动路径指令。

关键命令：
`IMAGE=build/difftest/hard_csel.bin MAX_INSNS=55 COORD=build/verilator_lockstep/lockstep_coordinator bash sim/difftest/run_lockstep_step.sh`
`bash sim/difftest/run_gate_d.sh`（约 5-8 分钟，全量验收）
