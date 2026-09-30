# F1a 固定周期 timeout pair 架构等价口径审计

```text
task=T-20260901-002
label=PE-F1D-TIMEOUT-AUDIT
state=review
base=ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37
measurement_source=291018d9a63efe549be589d1127e424e1118ed8a
branch=review/T-20260901-002-f1a-timeout-equivalence
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260901-002
sent_at=2026-09-01T00:23:53+08:00
received_at=2026-09-01T00:23:53+08:00
reported_at=2026-09-01T00:43:46+08:00
```

## 结论

T-007 的 196 行数据完整、98 对均有 f0/f1a，但固定 `5,000,000` 周期会在 workload
完成前截断部分运行。因此本审计识别出的 10 对差异只能称为“固定周期下的
progress-boundary mismatch”，不能直接判为 RTL 架构错误，也不能直接判为等价。

当前 F1a 严格结果仍为 `83/98`，目标门槛仍为 `98/98`。这 10 对即使全部通过后续
动态等价验证，T-007 中另有 5 对 `neon_vect` 的 pass/pass `commit_digest` mismatch
仍需独立诊断；本任务不改变、不降低 98/98 门槛。

## 数据来源与独立重算

审计读取并独立解析：

```text
docs/evidence/artifacts/T-20260831-007/f1c_matrix.csv
  bytes=73816
  sha256=d8ab955ed67aab8ec6826621358153ac84481a972e69f2d2ac9e57965025e005
docs/evidence/artifacts/T-20260831-007/f1c_matrix.json
  bytes=1291199
  sha256=acd72c27741c121c5848fb0e45fe5ae80f13e0ae85cda7e939e1d93dd27c9274
```

按 `(base_config, workload)` 配对，每对恰有一个 `fifo=f0` 和一个 `fifo=f1a`；
共 196 行、98 对、7 个 base、14 个 workload，所有行的
`measurement_source_sha=291018d9a63efe549be589d1127e424e1118ed8a`。CSV 没有
`returncode` 列，本审计从同一行的 JSON 交叉核对：`pass -> 0`，`timeout -> 1`；
JSON/CSV 的 row、config、workload 和 hash provenance 一致。

独立重算脚本的 build-only 结果：

```text
build/agents/T-20260901-002/timeout_recalc.json
rows=196 pairs=98 selected_timeout_status_retired=10
bytes=10480
sha256=501b01ff59ab349a629e0aa4da2089f2186b49bcda6d5f3479d5b263426b873a
```

重算比较字段为 `status`、JSON `returncode`、`retired_insn`、`commit_digest` 和
`memory_digest`；从 15 个全量 strict mismatch 中排除仅有 `commit_digest` 差异的
5 个 pass/pass `neon_vect` pair 后，得到以下 10 对。

## 10 个 timeout-related pair

`cycles=5,000,000` 表示该侧达到固定上限；pass 侧的 cycles 是观察到 MAGIC commit
时的 runner loop index。`retired`、digest 和 memory effects 均为截至该观察边界的
前缀摘要。

| pair | status / returncode f0→f1a | cycles f0→f1a | retired f0→f1a | commit digest f0→f1a | memory digest / effects f0→f1a | 当前口径 |
| --- | --- | ---: | ---: | --- | --- | --- |
| `l1id_l2_d0/mem_random` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 398,516 → 420,876 | `18174ac5155862e9` → `fe72e94fa7ae284a` | `c109a4332b568b5b` → `c109a4332b568b5b` / 8195 → 8195 | cap 截断的进度差异；需完成/共同前缀确认 |
| `nocache_d1/mem_seq` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 787,714 → 796,232 | `21fa6f4867492b5d` → `4d4e958016fd784c` | `891501d65678a0da` → `f457537fc364cd8c` / 111527 → 113231 | cap 截断；memory 前缀差异需提交级确认 |
| `nocache_d1/mem_random` | timeout/1 → pass/0 | 5,000,000 → 4,759,843 | 474,797 → 475,192 | `8db34ca7282f37c4` → `08c9181cf290ad35` | `c109a4332b568b5b` → `4e707e98e0c89190` / 8195 → 8197 | status/progress 边界；pass 侧已包含 MAGIC，需动态完成确认 |
| `nocache_d2/alu_latency` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 647,073 → 602,941 | `02ea93e7af2acbd7` → `3f2cc6280d35122e` | `87946b26b0fbf38d` → `87946b26b0fbf38d` / 2 → 2 | cap 截断的进度差异；需完成/共同前缀确认 |
| `nocache_d2/alu_ilp` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 691,402 → 694,470 | `831fa17369682b8c` → `d6ea0e226e068f90` | `87946b26b0fbf38d` → `87946b26b0fbf38d` / 2 → 2 | cap 截断的进度差异；需完成/共同前缀确认 |
| `nocache_d2/ctrl_branch` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 668,403 → 607,808 | `be4d5838f31460fe` → `92f25245d411ba21` | `48a064bbacad1e70` → `48a064bbacad1e70` / 11 → 11 | cap 截断的进度差异；需完成/共同前缀确认 |
| `nocache_d2/mem_seq` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 562,166 → 553,599 | `8c4a9bb520bfdd2f` → `6780d87b236bc2ff` | `9682bb25ab29f2f2` → `9682bb25ab29f2f2` / 81943 → 81943 | cap 截断的进度差异；需完成/共同前缀确认 |
| `nocache_d2/mem_random` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 407,881 → 413,351 | `a9b36cc8cd729082` → `4f208b0b91e06700` | `c109a4332b568b5b` → `c109a4332b568b5b` / 8195 → 8195 | cap 截断的进度差异；需完成/共同前缀确认 |
| `fullcache_d1/mem_random` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 356,074 → 374,163 | `afb153dda1664de8` → `863cbfb03257b6f1` | `c109a4332b568b5b` → `c109a4332b568b5b` / 8195 → 8195 | cap 截断的进度差异；需完成/共同前缀确认 |
| `fullcache_d2/mem_random` | timeout/1 → timeout/1 | 5,000,000 → 5,000,000 | 319,908 → 333,415 | `5c7b458e951ecafe` → `315023745c7805b3` | `c109a4332b568b5b` → `c109a4332b568b5b` / 8195 → 8195 | cap 截断的进度差异；需完成/共同前缀确认 |

两项 memory digest/effect 差异不是当前就能归因为架构错误：它们的退休数量也不同，
正符合不同前缀长度的表现。尤其 `nocache_d1/mem_random` 的 f1a 已完成，而 f0
仍在上限内；其它通过的 `mem_random` 行都为 memory digest
`4e707e98e0c89190`、effects `8197`，说明该 mismatch 至少包含“是否已经观察到
结束阶段写入”的边界因素。仍须逐提交验证，不能据此自动判等价。

## workload 终止与摘要范围

### 终止条件

`baremetal/startup_mb.s:11-15` 统一执行：设置栈、`bl main`，将 `main` 返回值写到
`MAGIC=0x4400FE00`，然后永久自旋。运行器只把已提交且地址等于 MAGIC 的 store
作为 `done`；`wdata=0` 才是 pass，非零是 workload 功能检查失败。没有观察到 MAGIC
时，运行器在 `c < max_cycles` 循环结束后报告 timeout。

本次 10 对涉及的 workload 均是有限循环并返回 0/1，没有以 timeout 作为软件控制
流：

| workload | 静态工作量边界 |
| --- | --- |
| `alu_latency` | 5 个依赖链，各 `50,000` 次；成功返回 0 |
| `alu_ilp` | 2/4/8 条独立链，各 `40,000` 次；成功返回 0 |
| `ctrl_branch` | loop、条件分支、CSEL、直接 call、间接 call，各 `20,000` 次；成功返回 0 |
| `mem_seq` | 4 个 size/rep 档；总计 57,344 个 word 的 write/read/copy，即约 172,032 个 word memory operations，随后有限收尾读取 |
| `mem_random` | 初始化 8,192 个表项、65,536 次 pointer chase、32,768 次 random read；成功返回 0 |

### 摘要累计范围

`sim/microbench/microbench_runner.cc:328-330` 将两个 FNV 摘要初始化为固定 offset。
每次 `commit_valid && commit_ready`（约 `524-594`）先递增 `retired_insn`，再把
完整提交包字段喂入 `commit_digest`；其中包括当前退休序号、PC、insn、next PC、
GPR/SP/NZCV、mem/mem2、异常、monitor、vector/FP effect。它不包含 cycle 或 wall time。

`memory_digest` 只在 `commit_mem_we`/`commit_mem2_we` 时累计地址、数据和 byte
strobe，`committed_memory_effects` 也只在这两个 effect 上递增；它不是最终 RAM
快照。MAGIC store 的检查在同一循环后部（约 `681-685`），所以 pass 行的结束
MAGIC store 已经被计入两个摘要，timeout 行通常尚未计入。

因此，固定周期下不同 `retired_insn` 会自然导致不同的 commit digest；memory digest
差异也可能只是某一侧多退休了若干 store。相反，若在相同退休前缀内首条提交记录
的 PC/写回/NZCV/next PC/内存 effect 不同，则才是必须升级为架构风险的证据。

## 不降低强度的后继验收契约

### 方案 A：双方运行至完成（推荐）

对每一个 timeout-related pair 的 f0/f1a 两侧使用同一 image、同一 source/tool
provenance、同一配置参数，取消 5M 的实验性上限或使用明确高于实测完成点的安全
上限，直到两侧都提交 MAGIC：

1. 两侧必须 `status=pass`、`returncode=0`，且没有 `fail/error/timeout`。
2. 比较最终 `retired_insn`、完整 `commit_digest`、`memory_digest` 和
   `committed_memory_effects`；应全部相同。
3. 若任一侧仍到达新安全上限，pair 保持 unresolved，不能按 timeout/timeout
   计为等价；若 marker 返回非零，按功能失败处理。

### 方案 B：共同退休前缀逐提交核对

当完整运行时间过长时，可先用 runner 的 `--trace`/`perf_runner.py --trace` 产生
JSONL commit trace，再按 `seq` 和退休序号比较到较短前缀。每条记录必须比较：

- PC、原始指令、next PC；
- GPR/GPR2/GPR3、SP、NZCV 写回及 enable/rd/value；
- mem/mem2 地址、数据、byte strobe 和 effect 顺序；
- exception code/ESR/FAR、exclusive monitor、vector/FP effect；
- trace header 中 image/source/config/max-cycle provenance。

共同前缀首条记录不一致即判架构风险并保存失败现场；共同前缀完全一致但一侧先到
固定上限，只能说明已确认到该前缀，仍须提高上限直至 marker 和最终状态比较。该
方案保留 PC/写回/NZCV/next PC/内存副作用，不把摘要或退休数量比较删掉。

## 最小复测集合、停止条件与资源

### 集合

- **完整闭合最小集合：20 行**，即上表 10 对各重跑 f0/f1a 一次；这是把这 10 对
  从 unresolved 变成可计入 98/98 的最小数量。
- **优先诊断子集：10 行**，先跑 `nocache_d1/mem_random`、`nocache_d1/mem_seq`、
  `l1id_l2_d0/mem_random`、`nocache_d2/alu_latency`、`nocache_d2/ctrl_branch`
  五对并开启 trace，覆盖 status/memory、L2、delay2 ALU/分支和最大退休差异；
  该子集只能排序风险，不能替代 20 行闭合集合。
- T-007 已有 5 个 pass/pass `neon_vect` commit-only pair 不在本次 10 对范围；
  后继诊断可在自己的 sibling worktree 中与本任务串行排队，但不得访问或复用
  T-007 worktree/build 产物。

### 停止条件

- 首条共同前缀 commit 的任一架构字段不同：停止该 pair，保存两侧 trace、执行前状态、
  最近提交和参数，不继续用摘要掩盖差异。
- 出现 `fail`、`error`、异常退出或非零 MAGIC：停止并按功能/架构失败处理。
- 新上限仍 timeout：保持 unresolved；不能把上限再提高而不记录预算，也不能改写
  status 或参考结果。
- 任一 runner 超过 `MemoryMax=15G`、发生 swap、或资源队列检测到并发重型作业：
  停止后续测试并由集成者重新排队。

### 资源估计

T-007 这 20 个对应 row 在 5M cap 下的已记录 wall time 合计约 `1,262.7 s`（约
21.0 分钟，单 row 最大约 68.6 s），但无 cap 完成时间未知，`mem_seq/mem_random`
应按 60--120 分钟动态诊断窗口预留。后继任务不得复用 T-007 worktree/build；完整
20-row closure 必须在自己的 sibling worktree、冻结 source 上重建 10 个 unique
config runner（5 个 base × f0/f1a：`l1id_l2_d0`、`nocache_d1`、`nocache_d2`、
`fullcache_d1`、`fullcache_d2`）和 5 个 workload image（`mem_random`、`mem_seq`、
`alu_latency`、`alu_ilp`、`ctrl_branch`）。按 T-007 的全矩阵经验，重建加串行执行
应保守预留约 3--4 小时；T-007 hash 仅作 provenance 对照。

固定资源策略为：

```text
systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% --
env MAKEFLAGS=-j1 VERILATOR_JOBS=1
```

本审计没有启动任何动态 runner。

## runner provenance、隔离与门槛决策

仓库中的 T-20260830-001 是 FPGA-A standalone Quartus 模块实验，T-20260826-001
是 registry/query 任务，均不是 F1C microbench runner，不能直接复用为本审计的
等价执行器。T-007 的 14 个 per-config `microbench_runner`、runner manifest 和
workload image 只能作为 hash/provenance 对照；后继动态任务不得访问
`/home/chiro/projects/mycpu/lcvex-wt-T-20260831-007` 的 worktree/build/失败现场。

后继动态任务必须在自己的 `/home/chiro/projects/mycpu/lcvex-wt-<task-id>` sibling
worktree，从冻结 source 重新构建本次 20-row closure 所需的 10 个 unique config
runner 与 5 个 workload image；所有输出放在该任务自己的 build staging。可共享的
只有 T-007 的 source/image/config/hash 元数据，不共享可执行文件或生成目录。neon
诊断同理，只能复用后继任务自己重建的 runner，并保持独立 workload/pair identity。

当前 98/98 是既定验收契约，不能调整为 88/88（只看 pass/pass）、83/98（当前值）、
或排除 timeout 后的比例。任何改变 98/98 的阶段门都必须由集成者和用户明确批准；
本审计不提出门槛修改。

## 边界

本任务只做 T-007 数据、runner/workload 源码和终止/摘要口径审计；未修改 RTL、TB、
runner、workload、QEMU、comparator、参考结果或 98/98 门槛，未运行 Verilator、
QEMU、Quartus、Gate 或 Linux。动态共同前缀和运行至完成证据留给后继验证任务。
