# LCVEX 交接文档 004：P4 完成（Gate C 通过），进入 P5

日期：2026-08-23（Asia/Shanghai）
范围：001（P0–P3）+ 002（P4a/Q6）+ 003（P4b）之后的 P4c 收尾状态。
本文只写 003 之后的新内容。

## 1. 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| P0–P3 | ✅ | 同 001 |
| P4a（Q6） | ✅ | 同 002 |
| P4b | ✅ | 同 003 |
| **P4c（Gate C）** | ✅ 本次 | 7 组异常定向锁步 + 全量回归 |
| P5 | 下一步 | MMU、TLB、I/D L1、统一 L2 |

## 2. 仓库状态（本会话结束时）

lcvex 仓库 `main` 有未提交改动（本次产物，待提交）：

- `sim/difftest/test_program.py`：新增 `build_p4c_el0_priv_program`
  （EL0 越权 MRS elr_el1 -> UDEF EC=0x00）与
  `build_p4c_el0_double_svc_program`（EL0 两次 SVC 往返，
  SPSR/ELR 复用）。
- `sim/difftest/run_gate_c.sh`：`make p4c`，Gate C 全套 7 组
  （q6_svc、p4b_el0_svc、p4b_invalid、p4b_dabt、p4b_iabt、
  p4c_el0_priv、p4c_el0_double_svc）。
- `Makefile`：新增 `p4c` 目标。
- `docs/ROADMAP.md`：Gate A/B/C 验收记录（✅）。
- `docs/DEVELOPMENT_PLAN.md`：P4 状态 = 完成。
- `docs/ISA_SCOPE.md`：EL0 越权 MRS/MSR -> UDEF。
- 本文件 `docs/handoffs/004-*.md`。

## 3. P4c 验证结果（全部实跑通过）

`make p4c`（Gate C 定向锁步，mode=step，QEMU EL1h）：

| 程序 | 覆盖 |
| --- | --- |
| q6_svc | EL1h SVC -> 向量 -> ERET（EC 0x15） |
| p4b_el0_svc | EL1h 预热 -> ERET 到 EL0 -> SVC -> EL0->EL1 向量 -> ERET |
| p4b_invalid | UDF #0 -> UDEF（EC 0x00） |
| p4b_dabt | store 0x50000000 -> DABT（EC 0x25） |
| p4b_iabt | BR 0x50000000 -> IABT（EC 0x21，合并到分支提交） |
| p4c_el0_priv | EL0 读 elr_el1 -> UDEF；EL1 handler 读 ELR=0x44000040 |
| p4c_el0_double_svc | EL0 连续两次 SVC，SPSR/ELR 跨轮复用正确 |

回归：`make test`、`difftest`、`difftest-hazard`、`difftest-random`、
`difftest-random-big`（100002 条）、`lockstep`、`lockstep-q5`、`q6`
全部通过（P4b 提交 662d11d 后未改 RTL，仅加测试与文档）。

## 4. 下一步：P5（MMU、TLB、Cache）

参考 `docs/DEVELOPMENT_PLAN.md` P5 与 `docs/LINUX_PLAN.md`：

1. **Q7：QEMU 锁步状态扩展**（`docs/DIFFTEST_QEMU_PLAN.md`）：
   导出系统寄存器/TLB fault/Cache maintenance 到 commit 消息；
   协调器增加统一物理内存服务或内存事件同步。
2. **RTL**：
   - EL1 4 KiB 页表遍历（TCR_EL1/TTBR0/1、MAIR、SCTLR.M）。
   - 基础 TLB（I/D 或统一，小容量）。
   - 分离 I/D L1（4 KiB、64B line、直接映射建议）与统一 L2
     （16~64 KiB、2-way）。
   - 权限、属性与 fault（沿用 P4b 的 IABT/DABT 提交路径）。
   - barrier（ISB/DSB/DMB）与 Cache maintenance 基础语义。
3. **软件**：页表构建 + 地址转换定向测试；MMU 开关后原有裸机程序
   重映射。
4. **验收（Gate D）**：地址转换、权限 fault、Cache hit/miss 与失效
   测试通过；P4 全套回归无变化。

## 5. 注意事项

- P4 的异常提交路径（ID 级提交、exc_valid/exc_code）是 P5 fault 的
  复用出口，MMU 引入后 IABT/DABT 的 ELR/EC 语义（转换 vs 权限 fault）
  需按 ESR 细化（当前简化：越界即 IABT/DABT）。
- QEMU virt 内存 128 MiB vs RTL SRAM 1 MiB 的地址范围差异是定向测试
  的坑（见 003 §5），P5 页表测试需在 RTL 侧扩大可寻址范围或显式建模。
