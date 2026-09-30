# LCVEX 交接文档 003：P4b（RTL 同步异常与 EL0/EL1）完成，进入 P4c

日期：2026-08-23（Asia/Shanghai）
范围：001（P0–P3）+ 002（P4a/Q6）之后的 P4b 完成状态与下一步。
本文只写 002 之后的新内容；系统状态细节见 `docs/ARCHITECTURE.md`。

## 1. 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0–P3 | ✅ | 同 001 |
| P4a（Q6） | ✅ | 同 002 |
| **P4b** | ✅ 本次 | RTL 同步异常 + EL0/EL1 + ERET + MRS/MSR |
| P4c | 进行中 | Gate C 验收：异常回归清单 + 文档收尾 |

## 2. 仓库状态（本会话结束时）

lcvex 仓库 `main` 有未提交改动（本次产物，待提交）：

- `rtl/lcvex_pkg.sv`：异常编码（UDEF 0x00/SVC 0x15/IABT 0x20·0x21/
  DABT 0x24·0x25）、`sys_op_t`（ERET/MRS/MSR）、`sys_reg_t`
  （VBAR_EL1/ELR_EL1/SPSR_EL1/NZCV）；`decoded_insn_t` 增加
  `exc/exc_code/sys_op/sys_reg/sys_wdata/exc_elr`。
- `rtl/lcvex_decode.sv`：新增 SVC/ERET/MRS/MSR 解码；未识别/保留编码
  → UDEF 异常；取指/Load-Store 越界（1 MiB SRAM）→ IABT/DABT；
  分支/跳转目标越界 → 合并为 IABT（与 QEMU 提交流一致），
  `exc_elr` 区分 SVC=pc+4 / 分支 IABT=目标 / 其余=pc。
- `rtl/lcvex_core.sv`：系统状态（el/sp_sel/daif/sp_el0/sp_el1/
  elr_el1/spsr_el1/vbar_el1）；异常/ERET/MSR **ID 级提交**
  （先等流水线排空，避免系统状态转发）；MRS 走普通流水线写回；
  SP 按 EL 分 bank；ERET 目标越界合并为 IABT（用恢复后的 EL/SP 算
  向量偏移）；`sys_next_pc` 统一驱动取指重定向与提交包。
- `sim/difftest/test_program.py`：新增 q6_svc（EL1h SVC）、
  p4b_el0_svc（EL0 SVC）、p4b_invalid（UDEF）、p4b_dabt（DABT）、
  p4b_iabt（IABT）程序生成器。
- `sim/difftest/run_lockstep_step.sh`：mode=step 锁步（QEMU
  `has_el3=false,has_el2=false` → EL1h 复位，与 RTL 一致）。
- `sim/difftest/run_p4b.sh`：`make p4b`，跑 5 条异常定向锁步。
- `sim/difftest/lockstep_coordinator.cc`：异常提交跳过 insn 诊断字段
  比较（IABT 未映射地址 QEMU 报 0、RTL 报 SRAM 回绕数据）。
- `Makefile`：`lockstep-step`、`p4b` 目标。
- 文档：`ARCHITECTURE.md`（系统状态 reset/权限/提交时机表）、
  `ISA_SCOPE.md`（P4b 指令与异常）、`COMMIT_PACKET.md`、
  `DEVELOPMENT_PLAN.md`、`DIFFTEST_QEMU_PLAN.md`、本文件。

## 3. RTL 设计要点（P4b）

### 系统状态与复位（与 QEMU `-cpu max,has_el3=false,has_el2=false` 对齐）

- 复位：EL1h（el=1, sp_sel=1）、DAIF=0xF、NZCV=0x4（Z=1）、
  SP_EL0/SP_EL1/ELR_EL1/SPSR_EL1/VBAR_EL1=0。
- SPSR 格式：`{32'd0, NZCV, 18'd0, DAIF, 2'b0, 0, EL, 0, SP}`，
  M=(EL<<2)|SP；ERET 恢复 el=spsr[2]、sp_sel=spsr[0]、
  daif=spsr[9:6]、nzcv=spsr[31:28]。
- 当前可见 SP = el ? sp_el1 : sp_el0；普通 SP 写按当前 EL 分 bank。

### ID 级提交（异常/ERET/MSR）

- `sys_at_id = ifid_valid && (d.exc || sys_op in {ERET, MSR})`；
  `sys_commit = sys_at_id && !idex_valid && !exmem_valid && !memwb_valid`；
  `sys_hold` 时 stall（不取更年轻指令）。
- ID 级提交同时：更新系统状态、生成提交包、重定向取指
  （`if_pc <= sys_next_pc`）、清 IF/ID 与在途取指。
- 异常入口提交：`exc_valid=1`、`next_pc=向量`、`sp_we=1`（SP_EL1）、
  `nzcv_we=1`（NZCV=0）、无 GPR 写；保存 ELR/SPSR。
- ERET 提交：`next_pc=ELR_EL1`、`sp_we=1`（目标 EL bank）、
  `nzcv_we=1`（恢复）。
- MSR 提交：普通提交（NZCV 写回带 nzcv_we）。
- MRS：普通流水线（wb_extra=系统寄存器值），依赖 ID 级提交保证
  读到已提交的旧值/新值。

### 异常向量偏移

- EL0→EL1：+0x400；同 EL（h）：+0x200；同 EL（t）：+0x000（未用）。
- ERET 越界时用 ERET 恢复后的 EL/SP 计算偏移（`eret_exc_vector`）。

### 与 QEMU 提交流对齐的合并规则

- 分支（B/B.cond/CBZ/TBZ/BR/BLR/RET）目标越界 → 分支本身提交为 IABT
  （`exc_valid=1`，pc=分支 PC，ELR=目标）。
- ERET 目标越界 → ERET 提交为 IABT（ELR/SPSR 保持）。
- 顺序取指越界（指令位于越界地址）→ 该指令提交为 IABT。
- IABT/DABT 的 EC：EL0→EL1 用 0x20/0x24，同 EL 用 0x21/0x25。

## 4. 测试结果（全部实跑通过）

| 命令 | 结果 |
| --- | --- |
| `make p4b` | 5/5：q6_svc、el0_svc、invalid、dabt、iabt 锁步一致 |
| `make test` | PASS |
| `make difftest` | PASS |
| `make difftest-hazard` | PASS（34 条） |
| `make difftest-random SEED=2 LENGTH=3000` | PASS |
| `make difftest-random-big` | PASS（100002 条） |
| `make lockstep` | PASS（36 条，mode=sync 无回归） |
| `make lockstep-q5` | PASS（四场景） |
| `make q6` | PASS |

## 5. 踩坑记录

- `movz xN,#imm,hw` 的第 4 个参数是 hw（lsl#16 的 16 位组），不是
  目标地址；构造 0x44000030 需要 `movz x6,#0x4400,hw=1; movk x6,#0x30`。
- 0x45000000 在 QEMU virt 的 128 MiB RAM 内（读到 0 → UDEF EC=0x00），
  RTL 的 1 MiB SRAM 才视为越界；IABT 测试必须用 0x50000000。
- QEMU 把“分支/ERET 到未映射地址”合并成该指令的 IABT 提交（next
  指令回调在向量处形成），RTL 必须同样合并，否则提交流错位。
- 异常提交的 insn 字段是诊断值：IABT 未映射地址 QEMU 报 0、RTL 报
  SRAM 回绕数据，协调器跳过该字段比较（pc/exc/next_pc 仍严格比较）。
- ERET 越界合并的取指重定向必须与提交包 next_pc 同源（`sys_next_pc`），
  否则重定向到 ELR 而提交报向量，下一提交错位。

## 6. 下一步：P4c（Gate C 收尾）

1. 把 P4b 五条异常程序纳入持续回归清单（`make p4b` 已做）。
2. 可选扩展：EL0 下 MRS/MSR 越权 → UDEF 定向测试；更多 MRS/MSR
   （SPSel/DAIF）；`ERET` 到 EL0 后再 SVC 的多轮往返。
3. Gate C 验收记录（ROADMAP.md Gate C 状态、验证命令与结果）。
4. 更新 handoff 004 并提交。
