# LCVEX 交接文档 033：exclusive 指令完成，M3 收尾

日期：2026-08-24（Asia/Shanghai）
前置：handoff 032（测试增强完成）、ROADMAP M3（仅剩 exclusive）。

## 1. 完成内容

单寄存器 exclusive 族（`LDXR/LDAXR/STXR/STLXR/CLREX`）全部落地，
**M3（Linux 前 ISA 收敛）关闭**。提交：

| 提交 | 内容 |
| --- | --- |
| `fd1aaa4` | a64.py exclusive 编码器 + check_encoders 51 条对照 |
| `0a29d7d` | RTL：decode exclusive 族 + 架构监视器 + STXR 两相访存 + 提交包 mon 字段 |
| `b4a8432` | 协议：lcvex_protocol.h/.py + 协调器比较 + 插件监视器追踪 + 幻影 store 修复 |
| `ffd2d22` | 验证：hard_exclusive 定向 55 条（base + 全缓存锁步） |
| `082a72a` | 随机回归修复 3 个真实 bug（见下） |

## 2. QEMU 语义（源码 + 实跑探针双重确认）

- `LDXR` 记录 clean VA + 加载值（`exclusive_addr/val`）；
- `STXR`：`addr==exclusive_addr && [addr]==exclusive_val`（QEMU 按
  STXR 宽度截取比较，允许跨 size）→ 条件写并返回 0；否则不写返回 1；
  **任何情况都清监视器**（`exclusive_addr=-1`）；
- `CLREX`、`ERET`、复位清监视器；
- **A profile 异常入口（SVC/UDEF/Abort）不清**（探针 D：LDXR→SVC→
  handler STXR 通过 w10=0；探针 E：LDXR→SVC→ERET→STXR 失败 w12=1）。

## 3. RTL 实现要点

- decode：`bits[29:24]==001000` 且 `bits[23:21]∈{000,010}`（STXR/LDXR，
  lasr=bit15 区分 acquire/release；LDXP/STXP/CAS 仍 UDEF）；
- 架构状态 `excl_valid/addr/data` **只在提交更新**；STXR 在 ID 等待前方
  流水线排空（`excl_hold`），随后“读比较写”两相访存：读响应与
  `excl_data` 按宽度比较，通过才发条件写，失败无内存副作用；
- 提交包新增 `mon_we/mon_valid/mon_addr/mon_data`：LDXR 记录、
  STXR/CLREX/ERET 清、异常入口/MSR/自身 fault 不动；
- `ERET` 目标越界合并 IABT 也清（QEMU 先 clear 再取指）。

## 4. 随机回归暴露并修复的真实 bug（`082a72a`）

1. **STXR 状态写回未纳入 load-use**：STXR 的 rs 写回晚到，但 hazard 只
   挡 load；下一指令在 STXR 仍处 EX/MEM 时译码，EX/MEM 前递假值 0。
   修复：`load_use` 纳入 `is_stxr`，并抑制 EX/MEM 对 STXR 的前递。
2. **分支冲刷丢失分支本身**：EX/MEM 正被访存事务冻结（`dmem_pending`）
   时 ID/EX 无法接收分支，但 `flush_id` 已清 IF/ID → 指令流断链（cbnz
   消失）。修复：`flush_id` 门控 `!dmem_pending && !stall_wb &&
   !fetch_walk`（不用 `exmem_can_adv`，避免组合逻辑环）。
3. **STP rt2 未登记读源**：STP 的 rt2 在 decode 里直接 `rdg()` 读取但未
   登记 rs3 → load-use/前递漏掉，读到陈旧值。修复：STP 登记
   `rs3=rt2`。

## 5. 验证结果

- `make test` 全绿（单元 + SVA + check-encoders 51 条）；
- `hard_exclusive` 55 条：base + 全缓存（I+D+L2）锁步全绿，逐提交比较
  mon 字段；覆盖跨 size（LDXR X→STXR W）、CLREX、直接 STXR、
  LDAXR/STLXR、byte/half/word/dword、rs=31、普通 STR 改值失败、
  SVC/ERET 往返；
- 随机 seed 1~3 × 100k（300,006 条）全部 PASS（含 exclusive 对/直接
  STXR/CLREX 路径）；
- 覆盖记账：ldxr/stxr/clrex 族全部命中（4636/6133/592 次）；
- `run_m2_4b.sh` 全量 34 组 × base/cache 全绿。
- Gate D 全量 PASS（`cd74d13` 起 run_gate_d.sh 会重新生成
  random_smoke.bin——此前陈旧镜像用旧生成器，含“分支跳过基址 movz”
  序列，在 delay2-random-smoke 触发未映射向量死锁）。
- **最终验收**：完整 Gate D 重跑全绿（`build/logs/gate_d_excl2_*.log`）：
  make test、coverage（7337 点）、M2-4b/4c 34 组 × base/cache、
  delay2 全缓存 + 随机延迟（含 hard_exclusive 55 条 + random_smoke
  3000 条）、P5a-Hardening 26 组、Gate C 7 组、P5a 3 组、P4b 5 组、
  随机 seed 1~3 × 100k（300,006 条）、覆盖记账 55/55 族、baremetal-C
  200 条。

## 6. 已知限制

- `LDXP/STXP`、LSE 原子（CAS/SWP）与 `LDAR/STLR` 未实现（UDEF）；
- 若异常向量本身未映射（如 VBAR=0 时 SVC 到 0x200），RTL 会卡在空
  流水线取指 fault（QEMU 会持续提交 IABT）；随机生成器已约束地址
  合法避免触发，P6 前需补强；
- 插件追踪 LDXR rt=31 时读不到记录值（测试约束 rt!=31）；
- `LDXR/STXR` 与“取指 fault 合并”同现（MMU on 的页边界）时，插件按
  EC=IABORT 应用指令监视器效果，RTL 侧同步实现，但该组合暂无定向测试；
- 异常向量本身未映射时 RTL 会卡在空流水线取指 fault（随机生成器已
  约束地址合法避免触发；P6 需补强）。

## 7. 下一步

1. 合 main 后跑一次 Gate D 全量（`bash sim/difftest/run_gate_d.sh`，
   含新 exclusive 测试与随机）；
2. Linux head.S 缺口清单 → P6（PL011 UART、Generic Timer、GICv2、DT、
   PSCI、更多 EL1 系统寄存器）。

## 8. 关键命令

```bash
make test
bash sim/difftest/run_m2_4b.sh --only hard_exclusive   # 或全量
make difftest-random-multi                             # seed 1~3 × 100k
python3 scripts/insn_coverage.py --expect random \
  build/difftest/random_{1,2,3}.trace
bash sim/difftest/run_gate_d.sh                        # 全量验收
```
