# LCVEX 交接文档 006：P5a-2（取指翻译与 IABT 合并）完成，进入 P5b

日期：2026-08-23（Asia/Shanghai）
范围：001–005 之后的 P5a-2 状态。本文只写 005 之后的新内容。

## 1. 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0–P4 | ✅ | 同 001–004 |
| P5a（数据翻译） | ✅ | 同 005 |
| **P5a-2（取指翻译 + IABT 合并）** | ✅ 本次 | `make p5a` 3/3 |
| P5b | 下一步 | I/D L1、统一 L2、barrier/Cache maintenance |

## 2. 仓库状态（本会话结束时）

lcvex 仓库 `main` 有未提交改动（本次产物，待提交）：

- `rtl/lcvex_mmu.sv`：增加 `walking` 输出（遍历中需冻结流水线）。
- `rtl/lcvex_core.sv`：
  - 取指翻译状态机（`fetch_req_valid/fetch_trans_busy/fetch_pa_r/
    fetch_faulted`），MMU 请求仲裁（数据优先）；
  - WB 合并 `fetch_merge_wb`（上一条指令 next_pc 取指 fault → IABT，
    保留该指令已执行的 GPR/SP 写回与访存副作用，SPSR 用 post-指令
    NZCV）；
  - ID 系统指令（ERET/MSR）在 sys_commit 前等 `fetch_next_settled`
    （next_pc 取指翻译已定），fault 则 `sys_fetch_merge` 为 IABT；
  - `sys_fetch_redirect`：ERET/异常在 ID 提前重定向取指到 d.next_pc
    （仅在取指空闲且目标不符时触发一次）；
  - P4b 的 ERET-to-fault（SRAM 范围）检查加 `!mmu_en` 门控
    （MMU 开启时 ERET 目标由取指翻译判定）；
  - `sys_next_pc` 的 ERET-to-fault 条件同步加 `!mmu_en` 门控。
- `sim/difftest/test_program.py`：`build_p5a2_fetch_program`（取指翻译
  + 分支 fault 合并 + 顺序 fault 合并交替循环）。
- `sim/difftest/run_p5a.sh`：加入 p5a2_fetch（MAX_INSNS=40）。
- 文档：ARCHITECTURE.md、DEVELOPMENT_PLAN.md、本文件。

## 3. 关键设计（P5a-2）

### 取指翻译（IF 级）

- MMU on 时，取指先翻译 if_pc（与数据翻译共享 MMU，数据优先）；
  翻译完成（TLB 命中 1 周期）后以 `fetch_pa_r` 发起 SRAM 读；
  TLB 命中不冻结，遍历（`fetch_walk`）冻结全部级（端口独占 + 保证
  WB 合并判定在提交前可用）。
- 翻译 fault → `fetch_faulted`（`fetch_pc_r` = 故障 VA），不发 SRAM 读。

### 提交流合并（与 QEMU 插件语义对齐）

- **WB 合并**：指令在 WB 且其 next_pc（`memwb_next_pc`）的取指翻译
  fault → 该指令提交转为 IABT 异常（`exc_valid=1`、EC=0x20/0x21、
  ELR=故障 VA、next_pc=向量、PSTATE→EL1h+DAIF+NZCV=0），并**保留该
  指令已执行的 GPR/SP 写回与访存副作用**（QEMU：指令先退休、随后
  取指 fault）；SPSR 记录 post-指令 NZCV；同时冲刷整条流水线并
  重定向到向量。
- **ID 合并（ERET/MSR）**：系统指令在 ID 提交前等 next_pc 取指翻译
  判定（`fetch_next_settled`）；fault 则 `sys_fetch_merge` 为 IABT。
- **取指提前重定向**：ERET/异常在 ID 把 if_pc 重定向到 d.next_pc
  （避免在途 pc+4 取指导致判定永不满足）；仅在取指空闲且目标不符时
  触发，防止反复清状态。

## 4. 测试结果（全部实跑通过）

| 命令 | 结果 |
| --- | --- |
| `make p5a` | 3/3：p5a_mmu、p5a_mmu_el0、p5a2_fetch（取指翻译、分支/顺序 fault 合并、写回保留、ERET 往返） |
| `make test` / `difftest` / `difftest-hazard` | PASS |
| `make difftest-random-big` | PASS（100002 条） |
| `make lockstep` / `lockstep-q5` | PASS |
| `make p4c` | PASS（Gate C 7 组） |
| `make q6` | PASS |

## 5. 踩坑记录

- MMU 开启后 P4b 的 ERET-to-fault（SRAM 范围）检查必须加 `!mmu_en`
  门控：ELR 是 VA，可能合法落在 SRAM 范围外；否则正常 ERET 被误判
  合并（`sys_next_pc` 与提交分支两处都要改）。
- 合并提交必须保留指令自身的写回（QEMU：movz 执行后 x7 已写，随后
  取指 fault；提交包 gpr_we=1 且 exc_valid=1）。
- sys_commit 的 next_pc 判定不能依赖"在途 pc+4 取指"：ERET/异常要
  先把取指重定向到 d.next_pc（`sys_fetch_redirect`），且重定向只能在
  取指空闲、目标不符时触发一次，否则会反复清掉已完成的翻译。
- 取指翻译 fault 会出现在"上一指令的提交"里，必须等其 WB/ID 提交
  判定后再清 `fetch_faulted`，否则丢失 fault 或错位。

## 6. 下一步：P5b（Cache）

1. 分离 I/D L1（4 KiB、64B line、直接映射建议）与统一 L2
   （16~64 KiB、2-way），阻塞式、单 miss。
2. MAIR 属性生效（Normal/Device），Cache hit/miss/失效（DC/IC）测试。
3. ISB/DSB/DMB（可先作 NOP）与 TLBI 基础语义。
4. Gate D 验收：地址转换、权限 fault、Cache hit/miss/失效；P0–P5a
   全量回归。
