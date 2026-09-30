# LCVEX 交接文档 031：测试增强计划落地与完整工作交接

日期：2026-08-24（Asia/Shanghai）
前置：handoff 030（LDR literal）、TEST_ENHANCEMENT_PLAN.md。
分支：`feature/m3-isa`，HEAD=`34245b0`（main 同步于更早阶段，待下次阶段门合并）。

## 1. 项目状态快照

- **阶段**：M3（Linux 前 ISA 收敛）进行中，**仅剩 exclusive**；
  P0-P5/Gate A-D 完成，P6 未开始。
- **分支**：`feature/m3-isa`（工作区干净，远端已推送）。
- **RTL 最近变更**：LDR literal（79cc6f3）、**ORN/BIC/EON/BICS/MVN
  取反族修复**（2a54a07）、microbench 框架（34245b0）、资源规划器
  （b156588）、测试计划文档（dcc4930）、ROADMAP 对齐（d777872）。

## 2. 测试增强计划完成情况

### 已完成

1. **资源感知规划器** `scripts/test_planner.sh`：
   - 负载按“已占用核数”估计（loadavg 1m），可用并行度 =
     min(空闲核, 内存预算/每单元)；输出 JSON（parallel/cpus/ok）；
   - 本地上限 50%、CI（--ci）75%；`--wait` 排队重试直到可用或超时；
   - 枚举可绑定物理核（lscpu 超线程去重 + affinity），运行器用
     `taskset -c <cpus>` 绑定；`make test-plan` 查看。
2. **microbench 框架**（L0，无 QEMU）：
   - `baremetal/tests/t_{arith,madd,bfm,csel,ldst}.c`：CHECK 宏、
     volatile 输入防折叠、内联汇编验 NZCV/BFI/BFXIL，返回失败数；
   - `startup_mb.s`：main 返回码写 MAGIC=0x4400FE00 后自旋；
   - `sim/microbench/microbench_runner.cc`：Verilator-only，轮询
     MAGIC store 提交包取返回码，PASS/FAIL + cycles + 超时；
   - `MB_ONLY=<name>` 单测构建；`make microbench` 全量
     （5/5 PASS，全量 mb_all 1526 cycles）；改坏期望可被捕获（rc=1）。
3. **ORN 族真实 bug 修复**：编译器 `~y` 生成 `mvn`（ORN xzr 别名），
   原 decode 的 AND/ORR/EOR/ANDS 分支硬性 `bit21==0` 导致 UDEF；
   新增 `inv_b` 通路（移位后取反）修复，mb_all.bin 与 QEMU 锁步
   4000 条一致。

### 未完成（交接后按顺序做）

4. `run_m2_4b.sh` / `run_p5a_hardening.sh` / `run_gate_d.sh` 加
   `--only name1,name2` 筛选参数（循环过滤，低成本）。
5. 随机生成器扩展（difftest 三缺口之一）：a64.py 补编码器
   （csel/csinc/csinv/csneg、bfm/bfi/bfxil、madd 族、ldp/stp、
   寄存器偏移 ldr/str、扩展 add/sub），random_program.py 加入新族
   与权重，seed 1~3 纳入 L3。
6. 指令覆盖记账脚本：从 QEMU trace 提取助记符，与 ISA_SCOPE 支持
   矩阵比对，缺失报警（归档 build/coverage/insn_map.txt）。
7. 并行化：Verilator 构建 `-j`；锁步测试并行 runner
   （per-test socket/日志 + planner 绑核）。
8. **ORN 修复后 Gate D 需重跑确认**（RTL 变更：decode/alu/pkg/core；
   mb_all 锁步已过，但全量回归尚未重跑）。

## 3. 测试分层现状

| 层 | 内容 | 状态 |
| --- | --- | --- |
| L0 microbench | `make microbench`（无 QEMU，返回码判定） | ✅ 5/5 PASS |
| L1 单元/SVA | `make test` | 既有，绿 |
| L2 定向锁步 | `hard_*`（QEMU 差分） | 34+26+16 项，Gate D 绿 |
| L3 全量 | `run_gate_d.sh`（后台，默认绿） | LDR literal 轮次绿；ORN 修复后待重跑 |
| L4 nightly | 多 seed / 延迟 / patch 重放 | 未纳入本轮 |

## 4. 关键命令

```bash
make test-plan                                   # 资源决策 JSON
make microbench                                  # L0 全量（含 runner 构建）
MB_ONLY=madd bash scripts/build-microbench.sh && \
  ./build/microbench_runner/microbench_runner --image build/microbench/mb_all.bin --name madd
IMAGE=build/microbench/mb_all.bin MAX_INSNS=4000 COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh         # mb_all 锁步（含 ORN）
bash sim/difftest/run_gate_d.sh 2>&1 | tee build/gate_d_YYYYMMDD.log   # L3 后台
```

## 5. 环境注意

- conda 环境 `lcvex`（Verilator 5.050、cocotb）；交叉工具链
  `aarch64-linux-gnu-gcc`；QEMU fork 在 `../qemu`（11.1.0，补丁
  可重放）；测试以本地为准，CI 待核心完善后启用。
- 后台长任务用 exec session + `tee` 日志（turn 结束不杀进程）；
  并行任务先过 `test_planner.sh` 排队 + 绑核。

## 6. 下一步建议顺序

1. 重跑 Gate D（ORN 修复回归确认）→ 绿后阶段门合入 main；
2. `--only` 筛选参数（三个 run 脚本）；
3. a64.py 编码器补齐 → 随机生成器扩展 → seed 1~3；
4. 覆盖记账脚本；
5. 并行 runner + Verilator `-j`；
6. M3 剩余 exclusive → Linux head.S 缺口清单 → P6。
