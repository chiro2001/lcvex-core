# F1a `neon_vect` commit-only 首分歧诊断

> 任务：`T-20260901-001`（PE-F1D-NEON-DIAG）
> 状态：review；只交付诊断，不修 RTL、runner、workload、QEMU、comparator 或参考结果。

## 结论

在冻结 source SHA `ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37` 上，固定同一份
`neon_vect` 镜像运行 F0 与 F1a：

- `nocache_d0`：两侧都是 `pass`、`66721` 条退休提交，active commit record
  逐条相等；比较器在提交流结束处报告 `termination-boundary`，唯一不同的正式
  footer 架构摘要字段是 `commit_digest`。
- `fullcache_d1`：得到完全相同的类别和 digest 值，说明该现象不依赖于
  `nocache_d0` 的 cache 配置。
- 对 trace 中可见的 active 字段将 inactive payload 归零后，以固定 FNV-1a
  序列重算的诊断摘要，两侧在两组配置中均为 `5c1d4f0a0f31cfe7`。因此没有找到
  第一条架构提交差异；当前证据指向正式 runner 摘要哈希了 trace 未暴露的
  inactive payload。具体是哪一个 raw payload 需要后续扩展观测才能闭合。

这不是 F1a 架构等价签核。正式 `commit_digest` 仍不同，且本任务不弱化比较字段；
`FETCH_FIFO_ENABLE` 继续保持默认关闭。

## 1. 固定输入与构建 provenance

| 项目 | 值 |
| --- | --- |
| base / measurement source SHA | `ee3cc52bed9a6265e3ccb6c9198aff63bd62ab37` |
| trace runner source commit | `5f7120ac768f2c5257f7ae1899787829e6065ed9` |
| comparator source commit | `cbd63645441677907caecb99857e01240b8cae47` |
| branch / worktree | `verify/T-20260901-001-f1a-neon-commit-diff` / `/home/chiro/projects/mycpu/lcvex-wt-T-20260901-001` |
| image | `build/microbench/perf_neon_vect.bin`，1864 bytes |
| image SHA256 | `6ebbd4c33bce14151a78f318bb2a352f496f9def93b6cdd417b91d057db1f7bf` |
| workload source bundle SHA256 | `217b415cfabe179b66643abc0fe9746fbbf7d033439e65ebabdcac74644c9974` |
| workload C 文件 SHA256 | `4718c1db98de6a038112f14d7c6042a27ef9f021d6500b13a6e569b6af96278b` |
| Verilator / GCC / Python | `5.050 2026-07-01 rev conda-forge build 0` / `aarch64-linux-gnu-gcc 16.1.0` / `3.12.10` |
| 构建资源 | `MemoryMax=15G`，`MemorySwapMax=0`，`CPUQuota=50%`，`MAKEFLAGS=-j1`，`VERILATOR_JOBS=1` |

四个 runner 均由同一 source 顺序构建；只改变 cache/delay 参数和 FIFO 开关。

| 配置 | runner bytes | runner SHA256 | build log SHA256 |
| --- | ---: | --- | --- |
| `nocache_d0_f0` | 12786304 | `e6710ffdf23d05c478162d34ce81d6a844d32910fa0dc9ec20a9e86654dc7dc9` | `a0340b021287a18df81cc7499d538f6a773bd7b5290c62490770d63c2e392955` |
| `nocache_d0_f1a` | 12803488 | `894481929aae1bd8f85ab64d624c4baa3d09349e50b40c4ede112c8c31f5b768` | `3e1d2074cde5a174a602b7657ef58e63a03104b8aac87722fa072bf7637387b9` |
| `fullcache_d1_f0` | 12862416 | `337b81205430e8fecaa7badf0dfd08459a3e16bc9d884356683e36b82feb0502` | `abe95dd99cf214edeadb7883d7842e31500f36b1bb2cef25d75ac1cc2aed079b` |
| `fullcache_d1_f1a` | 12883512 | `2ccb96ec521e3ce995f58d4bb00afc3360dc51710c4f964e2d8a26a591e51885` | `88a9c1a6635a072253bf680f67f54e4ba723d356b12d4e18cdd4d89509d9114b` |

## 2. F0/F1a 运行和比较

| pair | F0 cycles / retired | F1a cycles / retired | status | commit digest | memory digest |
| --- | ---: | ---: | --- | --- | --- |
| `nocache_d0/neon_vect` | 227526 / 66721 | 175716 / 66721 | pass / pass | `3caef22144f0b28a` / `3ec03fbc5b7681d0` | `3ba6dea5f6c76128` / `3ba6dea5f6c76128` |
| `fullcache_d1/neon_vect` | 253416 / 66721 | 200033 / 66721 | pass / pass | `3caef22144f0b28a` / `3ec03fbc5b7681d0` | `3ba6dea5f6c76128` / `3ba6dea5f6c76128` |

比较器命令均使用 `--window 4`，只比较 commit 的架构字段和 footer 的
`status/retired_insn/commit_digest/memory_digest`；`cycle` 和 `fetch` 只保留作
上下文，不参与等价判断。

| 比较 artifact | 结果 | records_compared | artifact SHA256 |
| --- | --- | ---: | --- |
| `docs/evidence/artifacts/T-20260901-001/first_commit_diff.json` | `mismatch / termination-boundary` | 66721 | `e8e7ec9c241fa7e781edd39652e8dbb258545956869ea78413ea1c2c608d364d` |
| `build/agents/T-20260901-001/comparisons/fullcache_d1.json` | `mismatch / termination-boundary` | 66721 | `89a7ec0828d7ad8f39b9d5a95c0e6881e1972ef619fdc4bfd5823e8ca530043d` |

两组比较的 `first_mismatch` 都是 `off=null/on=null`、index `66721`，原因是
`commit prefix equal but footer architectural summary differs`。这表示“第一处分歧”
发生在最后一条共同提交之后的 footer，而不是某条提交包的 PC、指令或 active effect。

## 3. 最后共同提交窗口

`first_commit_diff.json` 保存了两侧最后四条提交。关键末条如下：

| seq | PC | 指令 | next PC | active effect | F0 cycle / F1a cycle |
| ---: | --- | --- | --- | --- | ---: |
| 66718 | `0x00000000440003b8` | `0xd65f03c0` | `0x000000004400000c` | 无 | 227514 / 175705 |
| 66719 | `0x000000004400000c` | `0xd2a88001` | `0x0000000044000010` | GPR x1=`0x0000000044000000` | 227518 / 175709 |
| 66720 | `0x0000000044000010` | `0xf29fc001` | `0x0000000044000014` | GPR x1=`0x000000004400fe00` | 227521 / 175711 |
| 66721 | `0x0000000044000014` | `0xf9000020` | `0x0000000044000018` | store addr=`0x000000004400fe00`，wdata=0，strb=`00ff` | 227526 / 175716 |

四条记录的 `pc/insn/next_pc/effects` 完全相同；只有 cycle 和 F1a fetch context
（例如 epoch/occupancy/peak）不同。完整有限窗口、header、footer 和 provenance 见
[`first_commit_diff.json`](evidence/artifacts/T-20260901-001/first_commit_diff.json)。

## 4. 独立 trace/header/footer 审计

对四份 JSONL 逐行独立解析，不复用 comparator 的读取结果：

- 每份均为 `1 header + 66721 commit + 1 footer`，非空行数 `66723`；footer 是
  最后一条记录，footer 后无数据。
- `seq` 均从 1 连续到 66721；四份 trace 的 JSON、header 和 footer 均可解析。
- 每个 pair 的 schema、name、image/source SHA、measurement source SHA、max cycles
  和除 FIFO 字段外的 params 相等。
- active effect 计数在两侧完全相同：GPR `10798` 条、SP `1` 条、NZCV `10752`
  条、vector record `43097` 条（每条一个 vector item）、FPSR `36891` 条；memory
  record `2060` 条，对应 memory side effect `4116` 项；exception、monitor、FPCR 均为 0。
- 独立逐条架构字段比较（去除 `kind/seq/cycle/fetch`）得到 `66721/66721` 相等、
  首个 active record 差异不存在；memory side effect 序列也相等。

原始 trace SHA256 如下。F0/F1a 原始文件不同是预期的，因为 cycle、FIFO context
和 header params 不同，不代表 active commit 序列不同。

| trace | bytes | SHA256 |
| --- | ---: | --- |
| `neon_nocache_d0_f0.jsonl` | 20441709 | `491c06f9f6d434977f1ee94fa694de5acdeb89ce947b97890be3b1024e4ef023` |
| `neon_nocache_d0_f1a.jsonl` | 20533940 | `3d684cc0d5ad08cf47b124a60773d8d3e1c41fbed389f4697ba94e9027bc0077` |
| `neon_fullcache_d1_f0.jsonl` | 20442063 | `cbbfb6979908f47074b91dc2457de6ae02ba34193932fae9183fbaa1c95269b6` |
| `neon_fullcache_d1_f1a.jsonl` | 20534513 | `d79a54f2d46c5796f822a4e70262a9cb41e1db4110b73fdcbde89fb0a9d62260` |

## 5. digest 输入审计

`sim/microbench/microbench_runner.cc:524-580` 的正式 digest 使用显式的
FNV-1a byte-wise helper（offset `1469598103934665603`、prime
`1099511628211`），依次哈希：

- `retired_insn`、PC、next PC、instruction；
- 三组 GPR 的 write-enable、寄存器号和值，SP、NZCV；
- 两组 memory 的 write-enable、地址、写数据和 byte strobe；
- exception、exclusive monitor；
- vector write count、四组 rd 和四组 128-bit payload；
- FPCR/FPSR 的 write-enable 和值。

该实现没有哈希 cycle、FIFO/fetch counters、wall time、C++ struct padding 或 host
字节序。`digest_u8/u32/u64` 逐字节按固定小端顺序喂入，故不能将 cycle 差异解释为
footer commit digest 差异。

但 runner 在 `commit_valid && commit_ready` 时无条件哈希上述 payload；trace writer
在 `:362-488` 只在对应 write-enable/count 有效时输出 effect。也就是说，trace 能
证明 active 字段相等，却不能看到未使能的 GPR/SP/NZCV/memory/exception/monitor/
vector/FPCR/FPSR payload。两侧 active canonical digest 相等而正式 raw digest 不同，
因此当前最小解释是 inactive payload 被纳入正式 digest；现有 trace 不足以把它归因
到某一个 raw 信号。

诊断 canonical digest 的定义是固定使用 trace 可见的 architecture fields，active
effect 保留原值，inactive effect 的 enable/has 值保留为 0，其 payload 置 0；向量
槽按 `rd/lo/hi` 顺序、最多四槽喂入同一 FNV-1a。它仅用于隔离观察边界，不替代正式
比较，也没有删除 PC、next PC、寄存器写回、NZCV、内存或 FP/NEON 字段。

## 6. 边界、判断与后继任务

T-007 的矩阵曾列出五个 `neon_vect` commit-only mismatch：
`nocache_d0`、`l1i_d0`、`l1id_l2_d0`、`fullcache_d1`、`fullcache_d2`。本任务重新构建
并审计了首个 `nocache_d0` 与代表性 cache 配置 `fullcache_d1`；另三项未在本任务
重复运行，因此不把它们称为新的复现实验结果。两组已运行配置的 footer digest、
active 序列和 memory digest 完全同源。

建议登记一个单独的最小后继任务（本任务不实施）：

- 写集：`sim/microbench/microbench_runner.cc`，以及新增的
  `sim/microbench/commit_digest_test.cc` 和对应任务 evidence/handoff/doc；不改 RTL、
  公共 commit packet、QEMU 或正式 comparator 字段。
- 在 digest 输入处对每个 write-enable=0、slot 超出 vector write count 的 payload
  先 canonicalize 为零；保留所有 enable、PC、next PC、寄存器写回、NZCV、memory、
  exception、monitor、FPCR/FPSR 和 active vector 字段。
- 先用 C++ fixture 构造“active packet 相同、inactive payload 不同”，要求摘要相等；
  再以同一 image 串行运行 `nocache_d0` 与 `fullcache_d1` 的 F0/F1a，要求
  `status/retired/commit_digest/memory_digest` 全相等、active trace 逐条相等；最后
  运行 comparator self-test 和现有 NEON 定向验证。若仍有差异，再扩展 opt-in trace
  暴露 raw payload，不能放宽正式比较。

在该后继任务完成前，当前 `3caef...`/`3ec03...` footer 差异必须保留为严格失败，
不能仅凭相同 retired 或 memory digest 宣称 F1a 等价。
