# LCVEX 测试增强计划：microbench 优先 + difftest 分层

日期：2026-08-24（Asia/Shanghai）；多 Agent 并行说明更新于 2026-08-26
背景：Gate D 已全量通过，P6 Linux 是下一阶段；测试套件需支撑快速迭代
（默认不开 difftest）与阶段验收（后台 difftest 默认绿）。

## 1. 目标与原则

- 日常开发以**秒级反馈**为准：microbench（Verilator-only、无 QEMU、
  按返回码判过）作为主快速回归；
- difftest（QEMU 锁步）保持权威：受影响的 L2 在任务 review 前运行；L3 全量只在
  integration wave/阶段候选后台运行，不阻塞其他 Agent 的分析和编码；
- **测试增强的三个缺口（随机生成器扩展、多 seed、指令覆盖记账）
  全部走 difftest**：它们是差分验证的加强，不是快速层替代品；
- 每个改动仍遵循 AGENTS.md：实现 + 测试 + 文档；
- 测试分层与 CI 分层（PR-fast / PR-difftest / nightly / milestone）
  对齐，本地先跑，CI 待核心完善后启用。

## 2. 分层架构

| 层级 | 内容 | 触发 | 目标耗时 |
| --- | --- | --- | --- |
| L0 microbench | 裸机 C 行为级单测，返回码判定，Verilator 直接跑 | 每次改动 | 秒级 |
| L1 单元/SVA | `make test`（ALU/regfile/背压/memif/SVA） | 每次改动 | 分钟级 |
| L2 定向锁步 | `hard_*` 定向（QEMU 差分） | 指令族改动 | 分钟级 |
| L3 全量回归 | `run_gate_d.sh`：L2 + **多 seed 随机锁步**（M3 族扩展后）+ **指令覆盖记账** + 裸机 C | 阶段完成 | 5-8 分钟 |
| L4 nightly | 多 seed 随机、随机延迟、patch 重放、长 Linux | 后台/夜间 | 小时级 |

日常：L0 + L1；指令/架构变化在提交 review 前补 L2；integration candidate 在
进入 main/阶段门前后台跑 L3，L4 留给 nightly/长跑。L2/L3/L4 全部是 QEMU
差分（difftest）范畴。

## 3. microbench 框架设计

### 3.1 镜像与返回码约定

- `baremetal/tests/`：每个测试一个 C 文件，导出
  `int run_test_<name>(void)`，返回 0=过、非 0=失败数；
- `baremetal/tests.h`：提供 `CHECK(cond)` / `CHECK_EQ(a,b)` 断言宏，
  失败时累计计数并可写入失败信息区；
- `baremetal/microbench_main.c`：按固定顺序调用全部 `run_test_*`，
  返回失败总数（0 = 全部通过）；
- `baremetal/startup_mb.s`（新增，不改现有 `startup.s`，避免扰动
  `bm_c.bin` 锁步窗口）：设栈 → `bl main` → 把返回值写入
  **MAGIC=0x4400FE00**（RAM 内、远离代码/数据/栈）→ 自旋。

### 3.2 运行器（无 QEMU）

- `sim/microbench/microbench_runner.cc`：复用 lockstep 协调器的
  Verilator 驱动方式（prog 口加载 bin、tick），**不需要 socket/QEMU**；
- 完成判定：轮询提交包，观察到
  `commit_mem_we && commit_mem_addr==MAGIC` 时取 `commit_mem_wdata`
  为返回码（soc_tb 现有端口即可，无需改 TB）；
- 超时：固定 cycle 上限（如 2M）→ FAIL；
- 输出：`PASS: <name> (<cycles> cycles)` / `FAIL: <name> (rc=<n>)`，
  进程退出码 0/非 0 供 Makefile/CI 使用。

### 3.3 Makefile 入口

- `make microbench`：构建 runner + 编译 `mb_all.bin`，逐项运行全部
  测试并汇总；
- `make microbench-one IMAGE=...`：单镜像调试；
- 失败时保留返回值与 cycle 数，便于归档。

### 3.4 首批测试内容（覆盖 M3 已完成族）

- 算术/逻辑/移位（含 32/64 位、NZCV 位域）；
- SBFM/UBFM/BFM（bfi/bfxil）；
- MADD/MSUB/SMADDL/UMADDL/UMSUBL、UMULH 与 MUL/UDIV/SDIV（含除零）；
- CSEL/CSINC/CSINV/CSNEG（条件两分支）；
- LDP/STP、寄存器偏移、LDR literal（跳转表读取）；
- 数组/结构体/字符串行为级用例（编译器 -O0/-O2 双编译）；
- 后续：异常路径（SVC/UDEF）与 MMU/Cache 行为（P6 相关）。

## 4. 并行化

本节的 runner 已能把同一批锁步用例按测试名隔离，但它还不是跨 Agent 的全局
调度器：`scripts/test_planner.sh` 只根据当时的 loadavg/内存给出建议，两个
进程同时调用可能拿到同一组物理核。因此“并行化完成”只表示单一 runner 的能力；
不同 worktree 会隔离仓库相对产物，但全机资源和外部 QEMU 仍需由集成者统一排队。
具体规则以 [`docs/MULTI_AGENT_WORKFLOW.md`](MULTI_AGENT_WORKFLOW.md) 为准。

0. **资源感知规划（前置门控）**：`scripts/test_planner.sh` 在并行
   测试前评估系统负载与剩余内存——负载按**已占用核数**估计
   （loadavg 1 分钟），可用并行度 = min(空闲核数, 内存预算/每单元)；
   输出建议并行度与**可绑定的物理核列表**（超线程去重，
   `lscpu` + affinity），运行器用 `taskset -c <cpus>` 绑定物理核
   执行；资源上限本地 50%、CI 75%（`--ci`）；`--wait` 开启排队：
   资源不足时按间隔重试直到可用或超时（`make test-plan` 查看当前
   决策）。planner 是 advisory，不提供原子 reservation；A0 由集成者统一安排
   重型作业时隙，不能把每个 Agent 各自的“50%”相加。只有人工队列成为瓶颈后才
   增加最小全局 `test-slot` wrapper。
1. **Verilator 构建 `-j`**：内部 `-j 1` 单线程编译（~16s/配置），
   12 核可压到 3~5s；
2. **microbench 多镜像并行**：首批先单镜像（秒级足够）；若测试增长，
   按分组编译多个 bin，用 `xargs -P $(planner.parallel)` + `taskset`
   绑定物理核并行跑；
3. **锁步测试并行 runner**（L2/L3）：`run_lockstep_step.sh` 的
   socket/日志路径固定，需 per-test 路径 + 独立 COORD/QEMU；
   30+ 项锁步可压到串行的 1/4~1/6；并行度与核绑定由 planner 决定；
4. **后台 difftest**：`run_gate_d.sh` 只在冻结 integration candidate SHA 的
   detached gate worktree 以文件日志方式后台运行（exec session + `tee`），
   turn 结束不杀进程；阶段末默认绿后进入 main，不阻塞其他 Agent 的只读/编码
   工作；启动前由集成者按全局预算排队确认资源。

## 5. 指令覆盖记账

- 从 **QEMU trace**（difftest 的批量 trace 副产品）提取每条已提交
  指令的助记符集合；
- 与 `ISA_SCOPE.md` 支持矩阵自动比对，缺失即报警；
- 纳入 L3/L4 回归输出，防止“实现但从未被验证”再次发生
  （BLR/LDRSB/LDRSH 缺口教训）。

## 5.1 测试 registry 与筛选入口（A0 试点）

现有 runner 已分别提供 `--only`、`MB_ONLY` 和 seed 参数，但测试名称、域和层级
此前分散在多个 shell 数组中。A0 新增只读清单
[`scripts/test_registry.json`](../scripts/test_registry.json) 与查询工具
[`scripts/test_registry.py`](../scripts/test_registry.py)：

```bash
python3 scripts/test_registry.py --check
python3 scripts/test_registry.py --check-consistency
python3 scripts/test_registry.py list --level L0
python3 scripts/test_registry.py list --domain difftest-infra --tag checkpoint
python3 scripts/test_registry.py list --format json --level L2
make test-list ARGS='--tag p6'
make test-registry-check
```

registry 只描述现有入口，不执行命令、不申请资源，也不取代 Gate runner；命令参数
仍由原脚本解释。每项记录唯一 ID、子域、L0–L4 层级、类型、标签、资源建议和
状态。当前 registry 是 **A0 部分清单**：只登记经确认存在的稳定入口，不作为自动
影响分析的唯一来源。`make test-registry-check` 同时跑 schema 校验和
`--check-consistency`，后者对 registry 声明的 `source_consistency.make_targets/scripts`
做最小反向检查，防止已登记为稳定的 Makefile/runner 入口在 registry 中缺失；该检查
不枚举全部 Makefile 目标，因此仍需要工单流程同步维护。后续 integration wave 可根据
registry 生成受影响的 L0–L2 套餐；只有在实证确认手工维护成为瓶颈后，才考虑将其接入调度器。

## 6. 三个缺口的 difftest 实现（用户确认口径）

1. **随机生成器扩展**：`random_program.py` 加入 CSEL 族、BFM、
   MADD/MSUB/SMADDL/UMADDL、LDP/STP、寄存器偏移 LDR/STR、LDR
   literal、扩展寄存器 ADD/SUB、位掩码立即数；a64.py 补齐对应
   编码器；约束：LDP/STP 对齐、literal 范围、CSEL 条件合法；
   生成结果直接进入 QEMU 锁步随机回归；
2. **多 seed**：L3 默认 seed 1~3 × 100k，nightly 5 seed；
3. **指令覆盖记账**：每个 seed 的 trace 汇总助记符集合，与支持
   矩阵比对，缺失报 WARN/FAIL；归档到 `build/coverage/insn_map.txt`。

验收：seed 1~3 随机锁步全绿；覆盖记账显示 M3 全部已支持族在随机中
至少出现一次；运行时间纳入 L3（5-8 分钟预算内，若超出则并行化）。

## 7. 落地顺序与验收

### 完成情况（2026-08-24）

1. ~~LDR literal 阶段收尾~~：✅ 完成（Gate D 绿后合入，见 handoff 031/032）。
2. **microbench 框架**：✅ 完成（`make microbench` 8/8 PASS、全量 mb_all
   2666 cycles、改坏 RTL 可捕获；`MB_ONLY=<name>` 单测）。本轮新增
   `sys`（DAIF、AT/PAR_EL1、LDAR/STLR、UMULH），`MB_ONLY=sys` 379 cycles
   PASS；裸机镜像已通过 12,000 条 QEMU/RTL 逐指令锁步。
3. **单 runner 并行化**：✅ 完成；跨 Agent 重型作业队列仍为 A0 手工流程
   - Verilator 构建 `-j $(VERILATOR_JOBS)`（默认 6 = 12 核 50%）；
   - 锁步并行 runner `scripts/run_lockstep_parallel.sh`（planner 并行度 +
     物理核 taskset 绑定 + per-test socket/日志 + 排队 `--wait`），
     `make test-parallel` / `run_p5a_hardening.sh --parallel` 接入；
   - `run_lockstep_step.sh` 的 SOCK/DUMP/COORD_LOG/QEMU_LOG 均可环境变量
     覆盖，支撑并行实例隔离。
4. **随机生成器扩展 + 多 seed**：✅ 完成
   - a64.py 新增编码器并逐字对照 GNU 汇编器自检
     （`make check-encoders`，35 条 + 随机模糊对照）：
     CSEL 族（X/W ×4）、SBFM/UBFM/BFM/BFI/BFXIL、MADD 族（8 形）、
     LDP/STP（offset/pre/post，X/W）、寄存器偏移 LDR/STR（含
     LDRSW/LDRSB/LDRSH W/X）、扩展 ADD/SUB、BIC/BICS/ORN/EON；
   - random_program.py 纳入上述族 + LDR literal/PRFM/NOP；
     随机约束：pair pre/post 用专用基址 x21/x22（每步重置防漂移）、
     寄存器偏移索引 x23 受限且非 byte 固定 S=1 防非对齐、UBFM X 的
     imms≤30 避开保留编码；
   - L3 改为 seed 1~3 × 100k（`make difftest-random-multi`）。
5. **指令覆盖记账**：✅ 完成（`scripts/insn_coverage.py`）
   - QEMU trace `disas` 助记符归一（含 mov→movn/movz/movk 按 opc 解码、
     bfi/bfxil/sbfx/ubfx/cneg/cinc/cinv 别名折叠）与 ISA_SCOPE 支持矩阵
     比对；缺失 FAIL（`--warn-only` 可降级）；
   - 归档 `build/coverage/insn_map.txt`；Gate D 已接入
     （random 1~3 trace，54/54 族命中）。
6. 定期用 L3 全量回归校准，CI 待核心完善后启用 pr-difftest：
   ⏳ 持续执行（本轮 Gate D 全量重跑中，见 handoff 032）。

### 关键命令（更新后）

```bash
make test-plan                                     # 资源决策 JSON
make microbench                                    # L0 全量
make check-encoders                                # a64 编码器对照
make test-parallel                                # P5a-Hardening 26 项并行
SPECS="hard_csel:build/difftest/hard_csel.bin:55:build/verilator_lockstep/lockstep_coordinator" \
  bash scripts/run_lockstep_parallel.sh --wait     # 通用并行锁步（排队）
bash sim/difftest/run_gate_d.sh --only hard_csel   # L2：Gate runner 的单用例筛选
make difftest-random-multi                         # seed 1~3 × 100k
python3 scripts/insn_coverage.py --expect random \
  build/difftest/random_1.trace build/difftest/random_2.trace \
  build/difftest/random_3.trace                    # 覆盖记账
```

验收状态：`make microbench` 全绿；随机 seed 1~3 × 100k 的 trace 已生成
且无 UDF（QEMU 侧干净）；RTL 差分结果见 Gate D 全量重跑（handoff 032）。

## 8. 风险与已知限制

- microbench 只能证明“行为正确”，不能证明“与 QEMU 逐指令一致”，
  因此 L2/L3 的差分不可替代；
- MAGIC 地址与镜像布局冲突风险：镜像 <64KB 且栈固定 0x44080000，
  0x4400FE00 安全；链接脚本加断言防溢出；
- 运行器不处理异常/虚拟地址（microbench 在 MMU 关闭的裸机环境跑）；
- 后台 difftest 与本地开发可能争抢 CPU，建议限核或错峰。
