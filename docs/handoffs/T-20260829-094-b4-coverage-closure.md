# T-20260829-094 B4 编译器/覆盖闭合 handoff

- 任务 ID：T-20260829-094（B4）
- 状态：review（owner 交付；等待集成者复核）
- 分支：`feature/T-20260829-094-b4-coverage-closure`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-088`
- base SHA：`fcd952090994359861c85d001c07bfe560133e35`
- sent_at：2026-08-29T12:40:00+0800（约）
- received_at：2026-08-29T12:45:00+0800（约）
- reported_at：2026-08-29T12:55:00+0800

## 完成内容

### 1. 随机覆盖表闭合
- 扩展 `scripts/insn_coverage.py` 归一化：
  - 新增 `rbit`、`umulh`/`smulh` 支持族；
  - `EXPECT_RANDOM` 增加 `rbit`、`umulh`。
- `sim/difftest/random_program.py` 的乘除族增加 `smulh`。
- 使用 QEMU 11.1.0 + 本仓库 `lcvex_difftest.so` 生成 4 个种子随机 trace：
  - seed 1..4，length=5000
  - 合计提交 20,010 条
- 覆盖结果：
  - `expected_hit = 62/62`
  - `observed_families = 63`
  - `PASS`（无缺失、无未知助记符）
- 说明：`smulh` 在生成 trace 中未单独出现，但与 `umulh` 归入同一
  multiply-high 族；该族由随机 trace 命中。
- 输出：`build/coverage/b4_random_insn_final.txt`

### 2. 裸机 C -O0/-O2/-Os 反汇编审计
- 新建 `scripts/b4_baremetal_cov.py`，解析 `build/b4_baremetal/*/mb_all.dis` 并生成
  `build/coverage/b4_baremetal_cov.json`。
- 编译产物：
  - `-O0`：37 个归一化支持族
  - `-O2`：44 个
  - `-Os`：42 个
  - 合计反汇编见到 47 个支持族
- 无未知助记符（alias 已归一：`cmp/cmn/neg/mvn/cset/umull/sxtw/tst` 等）。
- 裸机 C 未覆盖的族（如 `isb/dsb/dc/tlbi/msr/svc` 等）由随机/定向测试覆盖，
  不把 baremetal 命中率当作静态全覆盖。

### 3. Negative / reserved 集合
已由前序 B3 解码器 TB 覆盖，本切片引用：
- `SB CRm!=0` -> UDEF
- `MRS OSLAR_EL1` / `MSR OSLSR_EL1` -> UDEF
- EL0 访问 EL1-only 系统寄存器 -> UDEF
- 未知 SYS 编码 -> UDEF
- EL0 PL1-only maintenance / TLBI op1=4 -> UDEF
- `DC CVADP` -> UDEF（POST-V82）
- 保留 LSE op -> UDEF
- `ADDG/SUBG` 等 MTE 保留编码 -> UDEF（既有 decoder 负测）

## 改动文件

| 文件 | 说明 |
| --- | --- |
| `scripts/insn_coverage.py` | 补 `rbit`/`umulh`/`smulh` 归一与 expectation |
| `sim/difftest/random_program.py` | 随机乘除族加入 `smulh` |
| `scripts/b4_baremetal_cov.py` | 新增裸机 C 反汇编覆盖表生成器 |
| `docs/handoffs/T-20260829-094-b4-coverage-closure.md` | 本 handoff |
| `docs/tasks/evidence/T-20260829-094.json` | evidence |

## 验证命令与结果

```text
# 随机 trace 生成（4 seeds）
python3 sim/difftest/run_qemu.py --trace-only --program random \
  --seed N --length 5000 --out build/difftest/b4_random_N.trace

# 随机覆盖表
python3 scripts/insn_coverage.py --expect random \
  out build/coverage/b4_random_insn_final.txt \
  build/difftest/b4_random_1.trace ... b4_random_4.trace
# PASS: expected_hit=62/62 observed_families=63

# 裸机 C 构建
aarch64-linux-gnu-gcc -O0|-O2|-Os ... mb_all.elf
aarch64-linux-gnu-objdump -d mb_all.elf > mb_all.dis

# 裸机覆盖表
python3 scripts/b4_baremetal_cov.py
# JSON: build/coverage/b4_baremetal_cov.json

# 编码器回归
python3 sim/difftest/check_encoders.py
# PASS: 86 条

python3 -m py_compile scripts/insn_coverage.py \
  scripts/b4_baremetal_cov.py sim/difftest/random_program.py
```

## 限制 / 未执行

- 本切片只生成 QEMU trace 做覆盖统计，未跑 RTL 随机锁步或 Gate D。
- 未运行 `make compile`；本次只改脚本/测试生成器，不影响 RTL 源码。
- 未启动 Quartus；未修改 QEMU fork，只构建了现有 plugin。
- 未跑完整 Linux 动态窗口。
- 裸机反汇编覆盖表是静态覆盖，不代表 profile 行 100% 的定向执行证据；
  profile 行完整证据仍以既有 manifest、B3 定向测试和集成者 Gate D 为准。

## 剩余 gap

- 随机生成器仍未覆盖：LSE 单寄存器原子、系统维护（IC/DC/TLBI/AT）、
  barrier（DMB/DSB/ISB/SB）、FP/NEON（非本任务）。
- 裸机 C 未覆盖：`isb/dsb/dc/tlbi/msr/svc` 等系统族、部分 ALU/分支族。
- 没有单一脚本把 V82 profile 117 行逐一绑定到 trace 命中；需要后续把
  manifest row_id -> 归一化族映射补成全自动矩阵。
- 尚未生成全量 QEMU sysreg inventory JSON。
