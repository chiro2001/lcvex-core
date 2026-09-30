# LCVEX 交接文档 002：P4a（Q6 QEMU fork step hook）完成，进入 P4b

日期：2026-08-23（Asia/Shanghai）
范围：为上下文压缩后的后续会话提供 P4a 完成状态、Q6 实现细节与 P4b 计划。
先读 001 获取 P0–P3 背景；本文只写 001 之后的新内容。

## 1. 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0–P3 | ✅ | 同 001，回归全部通过 |
| **P4a（Q6）** | ✅ 本次 | QEMU fork 精确 step hook + SVC/UDF/ERET 上报验证 |
| P4b | 下一步 | RTL 同步异常、EL0/EL1、ERET、MRS/MSR |
| P4c | 待 RTL | 异常锁步差分 + Gate C |

配套锁步计划（`docs/DIFFTEST_QEMU_PLAN.md`）：Q0–Q5 完成，**Q6 本次完成**，
Q7 留给 P5。

## 2. 仓库状态（本会话结束时）

lcvex 仓库 `main` 有未提交改动（本会话产物，待提交）：

- `qemu/plugins/lcvex_difftest.c`：新增 `mode=step`（fork step hook），
  同步异常从 DISCON 失败改为带 `exc_valid/exc_code` 的 COMMIT；
  `mode=sync`（P2/P3/Q5）语义不变。
- `qemu/plugins/lcvex_protocol.py`：协议 Python 镜像（与 .h 一一对应）。
- `qemu/patches/0001-tcg-arm-lcvex-difftest-step-hook.patch`：QEMU fork 补丁。
- `qemu/VERSION`：记录 `QEMU_FORK_BRANCH=lcvex-step-hook`、
  `QEMU_FORK_COMMIT=ccd819d`（补丁内容即该提交，fork 工作区已回到基线
  84f0721 + git apply，使 toolcheck 的 HEAD 校验通过）。
- `sim/difftest/a64.py`：新增 `svc/eret/udf/msr_sys/mrs_sys` 编码器
  （MRS/MSR 的 SYS 编码：`0xD5000000 | (l<<21) | (op0<<19) | (op1<<16) |
  (crn<<12) | (crm<<8) | (op2<<5) | rt`，l=1 读 0 写）。
- `sim/difftest/test_program.py`：`build_q6_svc_program`（SVC→向量→ERET
  往返，VBAR_EL1=0x44010000，向量 0x44010200）。
- `sim/difftest/q6_harness.py`：Q6 轻量协调器（只驱动 QEMU，无 DUT）。
- `sim/difftest/run_q6.sh`：`make q6` 入口。
- `sim/difftest/lockstep_coordinator.cc`：CommitPacket 增加
  exc_valid/exc_code 读取与比较（P4c 预置，当前无异常测试不受影响）。
- `Makefile`：新增 `q6` 目标。
- `docs/DIFFTEST_QEMU_PLAN.md`、`docs/DEVELOPMENT_PLAN.md`：Q6/P4a 状态。
- 本文件 `docs/handoffs/002-*.md`。

## 3. QEMU fork step hook（Q6）实现

**设计**：插件 `mode=step` 继续驱动锁步协议；QEMU fork 只补插件 API
无法提供的“精确退休事件”。

1. `accel/tcg/cpu-exec-common.c` `curr_cflags()`：`LCVEX_DIFFTEST_STEP=1`
   时强制 `CF_NO_GOTO_TB | CF_NO_GOTO_PTR | 1`（单指令 TB、禁链式跳转）。
2. `target/arm/tcg/lcvex-difftest.c`：
   - `qemu_lcvex_difftest_active()`：缓存 env 变量（一次查询）。
   - `qemu_lcvex_difftest_note_exception(CPUState*)`：在
     `arm_cpu_do_interrupt()` 异常入口处记录（先 note 再 discon 回调）；
     同步异常（UDEF/SWI/HVC/SMC/HYP_TRAP/BKPT/IABT/DABT/GPC）记
     `syn_get_ec(env->exception.syndrome)`，其余（IRQ/FIQ/...）记 async。
   - `qemu_lcvex_difftest_take_exception(vcpu_index, &ec)`：返回
     1=同步（*ec=ESR.EC），2=异步，0=无；单 vCPU 假设，`current_cpu`
     校验。
3. `include/plugins/qemu-plugin.h`：新增两个 `QEMU_PLUGIN_API` 声明，
   `scripts/qemu-plugin-symbols.py` 自动导出（`nm -D` 可见）。
4. `target/arm/helper.c` `arm_cpu_do_interrupt()`：note 插入在
   `arm_do_plugin_vcpu_discon_cb(cs, last_pc)` 之前。
5. `target/arm/tcg/meson.build`：`arm_system_ss` 增加
   `lcvex-difftest.c`（仅 aarch64 softmmu）。

**关键语义**：
- 同步异常 COMMIT：`post.pc=异常指令 PC`、`post.insn=异常指令编码`、
  `exc_valid=1`、`exc_code=ESR.EC`、`post.next_pc=异常向量入口`；
  GPR/SP/NZCV 为异常入口后状态（QEMU 行为：NZCV 清 0、SP 切 SP_EL1、
  PSTATE=DAIF 全置位 + 目标 EL 模式）。
- ERET 是正常退休：`next_pc=ELR_EL1`，PSTATE/NZCV 从 SPSR_EL1 恢复。
- 异步 IRQ/FIQ：`take_exception` 返回 2，插件仍 DISCON 失败（P4 无 IRQ）。
- **坑**：ARM discon 回调的 `from_pc` 是首选返回地址（SVC 为指令+4，
  即 ELR 值），不是异常指令地址；异常指令地址以插件 pending 的
  `last_pc` 为准，不要用 from_pc 校验。

## 4. 测试结果（全部实跑通过）

| 命令 | 结果 |
| --- | --- |
| `make q6` | PASS：SVC EC=0x15/向量/ELR=svc+4/SPSR=0x400003c5/ERET 返回，UDF EC=0x00 |
| `make test` | PASS（P0 toolcheck 含 fork HEAD 校验） |
| `make difftest` | PASS（P1/P2 批量 trace） |
| `make difftest-hazard` | PASS（34 条） |
| `make difftest-random SEED=1 LENGTH=3000` | PASS（3002 条） |
| `make lockstep` | PASS（36 条，mode=sync 无回归） |
| `make lockstep-q5` | PASS（四场景，mode=sync 无回归） |

Q6 测试程序关键值（`-cpu max,has_el3=false,has_el2=false` → 复位 EL1h，
VBAR_EL1=0x44010000）：
- SVC @0x4400000c：EC=0x15，ELR_EL1=0x44000010（SVC+4），
  向量=0x44010200（EL1→EL1 同步、SP=1、+0x200）。
- SPSR_EL1=0x400003c5（Z + DAIF 全置位 + EL1h；QEMU 复位 DAIF=0xF00）。
- 异常入口后 NZCV=0（QEMU `pstate_write(PSTATE_DAIF|new_mode)` 行为），
  ERET 后恢复 0x4。
- UDF @0x44000014：EC=0x00，ELR_EL1=0x44000014（pc_diff=0）。

## 5. 下一步：P4b（RTL 同步异常与 EL0/EL1）

1. **RTL 状态**：新增 SPSR_EL1/ELR_EL1/（必要时 VBAR_EL1）；说明 reset
   值、读写权限、提交时机（AGENTS.md 规则 5）。提交包已预留
   `exc_valid/exc_code`，需新增 ELR/SPSR 写回事件或按“异常提交=改 PC 到
   向量 + 保存 ELR/SPSR”建模。
2. **异常生成**：非法指令（当前是停住，P4 改异常提交，EC 0x00）、SVC
   （EC 0x15）、指令/数据 Abort（EC 0x20/0x24，EL0→EL1 时 IABT=0x20、
   DABT=0x24，Same-EL 为 0x21/0x25）、ERET；异常向量按
   `VBAR_EL1 + offset`（低 EL→EL1 同步 +0x400，同 EL +0x200 或 +0x000）。
3. **权限与入口**：EL0 代码下 SVC 到 EL1 的 ELR/SPSR/SP 切换语义；
   MRS/MSR（ELR_EL1、SPSR_EL1、VBAR_EL1 等必要寄存器）。
4. **差分**：`mode=step` 锁步 + `make q6` 扩展为 DUT 版本；协调器
   exc 比较已就绪；异常测试程序可复用 q6_svc.bin 的向量布局。
5. **收尾**：Gate C 验收、全量回归、更新 ISA_SCOPE.md/DEVELOPMENT_PLAN.md
   与 handoff 003。

## 6. 注意事项

- fork 工作区是“基线 84f0721 + git apply 补丁”（未提交），分支
  `lcvex-step-hook` 保留提交版 ccd819d 供追溯；toolcheck 只认基线 HEAD。
- 改 QEMU 后记得 `ninja -C ../qemu/build qemu-system-aarch64` 重建，
  插件用 `make -C qemu/plugins`（插件改了要重编，`q6` 目标会重编）。
- Python 协议解析索引易错：COMMIT 的 exc 字段在 unpack 后索引 43/44/45，
  store 从 46 起（`lcvex_protocol.py` 已修，勿按 13/16 索引）。
- SOCK_SEQPACKET 必须整包 `recv`，不能跨 recv 拼消息（harness 已按
  整包读取）。
- MRS/MSR 编码以 QEMU `a64.decode` SYS 模式为准；a64.py 已修正。
