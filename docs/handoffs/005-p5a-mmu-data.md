# LCVEX 交接文档 005：P5a（MMU 数据翻译）完成，进入 P5a-2/P5b

日期：2026-08-23（Asia/Shanghai）
范围：001（P0–P3）+ 002（P4a）+ 003（P4b）+ 004（P4c）之后的 P5a 状态。
本文只写 004 之后的新内容。

## 1. 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0–P4 | ✅ | 同 001–004 |
| **P5a（MMU 数据翻译）** | ✅ 本次 | 系统寄存器 + 页表遍历 + TLB + 权限 fault |
| P5a-2 | 下一步 | 取指翻译 + IABT 合并 |
| P5b | 下一步 | I/D L1、统一 L2、barrier/Cache maintenance |

## 2. 仓库状态（本会话结束时）

lcvex 仓库 `main` 有未提交改动（本次产物，待提交）：

- `rtl/lcvex_mmu.sv`（新）：4 KiB 页表遍历 FSM（L0–L3，请求/等待
  子状态）+ 8 项全相联 TLB + AP/UXN/PXN 权限检查 + PA 越界检查。
- `rtl/lcvex_pkg.sv`：sys_reg_t 增加 SCTLR/TCR/TTBR0/TTBR1/MAIR；
  ex_pipe_t 增加 `mem_paddr`。
- `rtl/lcvex_decode.sv`：MMU 系统寄存器 MRS/MSR；`mmu_en` 时关闭
  SRAM 范围 fault 检查（VA 可合法落在 SRAM 外）。
- `rtl/lcvex_core.sv`：MMU 状态寄存器（复位值匹配 QEMU EL1h，SCTLR
  =0xC50838）；数据翻译状态机（请求/冻结/结果/`dabt_pending`）；
  ID/EX 携带 `mem_paddr`；MEM 端口仲裁（页表遍历 > MEM > 取指）；
  提交改为"进入 WB 当拍"的一次性脉冲（`memwb_prev_valid`）；
  翻译冻结期间屏蔽重复 store。
- `rtl/filelist.f`、`sim/cocotb/Makefile`：加入 lcvex_mmu.sv。
- `sim/difftest/test_program.py`：`build_p5a_mmu_program`（EL1h）与
  `build_p5a_mmu_program_el0`（EL0 数据访问），页表预构建在二进制内。
- `sim/difftest/run_p5a.sh` + `Makefile p5a` 目标。
- 文档：ARCHITECTURE.md（MMU 小节）、DEVELOPMENT_PLAN.md、ISA_SCOPE.md、
  本文件。

## 3. 关键设计（P5a）

### MMU 单元（lcvex_mmu.sv）

- 握手：`req_valid && req_accept` 接收请求；`done` 输出一个周期；
  TLB 命中/直通 1 周期，4 级遍历约 8 周期。
- 区域：`va < 2^(64-T0SZ)` -> TTBR0；`va >= -2^(64-T1SZ)` -> TTBR1；
  其余 -> 翻译 fault。
- 遍历：L0（va[47:39]）→ L1（[38:30]）→ L2（[29:21]）→ L3（[20:12]）；
  表描述符 bits[1:0]=11；L3 页描述符 OA[47:12] + AP[7:6] + AF[10] +
  UXN[54] + PXN[53]；块描述符暂不支持（fault）。
- 权限：UXN/PXN（取指）、AP（数据读写，EL1/EL0 规则见代码）。
- PA 超出 SRAM 范围 -> fault（与 QEMU 外部 abort 同 EC）。

### 核心集成

- Load/Store 在 ID 级翻译：`mmu_req_issue` 当拍冻结 IF/ID/ID/EX，
  `data_trans_active` 冻结全部级（遍历独占 SRAM 端口，保持译码输入
  稳定）；完成后 ID/EX 携带 `mem_paddr`，fault 转 `dabt_pending`
  -> 复用 sys_commit 的 DABT 异常提交（EC=0x24/0x25，ELR=pc）。
- 取指保持恒等（P5a 范围）；`mmu_en` 时 decode 关闭 IABT/DABT 范围
  检查（VA 语义）。
- **提交一次性脉冲**：`commit_valid` 只在指令进入 WB 当拍置位
  （`memwb_prev_valid`），翻译冻结不再重复提交同一指令。
- 翻译冻结期间 `mem_we/strb/wdata` 屏蔽，避免重复 store。

## 4. 测试结果（全部实跑通过）

| 命令 | 结果 |
| --- | --- |
| `make p5a` | 2/2：p5a_mmu（EL1h 数据翻译 + 权限 fault EC=0x25）、p5a_mmu_el0（EL0 翻译 + 权限 fault EC=0x24） |
| `make test` / `difftest` / `difftest-hazard` | PASS |
| `make difftest-random-big` | PASS（100002 条） |
| `make lockstep` / `lockstep-q5` | PASS |
| `make p4c` | PASS（Gate C 7 组，RTL 改动无回归） |
| `make q6` | PASS |

## 5. 踩坑记录

- 页表遍历期间若只冻结部分级，提交点（MEM/WB）保持会让
  `commit_valid` 每周期重复置位 -> 同一指令多次提交；必须改为
  "进入 WB 当拍"的一次性提交（`memwb_prev_valid`）。
- 翻译请求被接受的当拍必须同时冻结 IF/ID 与 ID/EX，否则未翻译的
  load/store 会提前进入 EX（mem_paddr 未就绪）。
- 翻译冻结期间取指状态必须保持（`fetch_issued_r` 拉低），否则解冻时
  在途取指数据会覆盖 IF/ID 中的等待翻译指令。
- 页表描述符高 32 位为 0 时，Python `bytearray` 切片赋值超出长度会
  静默"追加"而不是报错 -> 页表落在错误偏移；缓冲区必须开够
  （0x16000）。
- QEMU 页表 L1 索引：VA 0x44000000 的 L1 索引是 1（0x40000000..
  0x80000000 区域），不是 17；代码与数据同区时 L2 表共享。
- 异常向量必须映射且 VBAR 必须设置，否则 DABT 跳到未映射向量后
  QEMU 插件无指令回调形成 COMMIT -> 锁步死锁。
- 锁步超时有两种：DUT 未提交（`step_until_commit` 上限）与 QEMU 未
  发消息（recv 超时），诊断路径不同，先看 note 区分。

## 6. 下一步

1. **P5a-2：取指翻译**：IF 级翻译 if_pc；取指翻译 fault 按 QEMU
   提交流合并到上一条指令的 WB 提交（IABT，ELR=目标 VA）；`sys_next_pc`
   与向量偏移沿用 P4b；decode 的分支越界合并仅保留 MMU 关闭时。
2. **P5b：Cache**：分离 I/D L1（4 KiB、64B line、直接映射）+ 统一
   L2（16~64 KiB、2-way）；MAIR 属性生效；Cache hit/miss/失效测试；
   ISB/DSB/DMB 与 TLBI/Cache maintenance 基础语义。
3. **Q7**：QEMU 锁步扩展（导出 TLB/Cache 事件到诊断通道，可选）。
