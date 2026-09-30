# F1A commit sequence 首分歧动态诊断

> 任务：T-20260830-044（PE-F1A-DYN）
> 状态：**review：已捕获历史非等价 workload 的第一处分歧；不修 RTL。**

本任务在同一诊断 source 上重建 `nocache_d0` 的 F0/F1a runner，增加默认关闭的
commit JSONL trace 和流式比较器。结论是 F1a 在 `fp_scalar`、`mem_seq` 中出现真实的
重复提交（duplicate retirement）：比较器在共同前缀后看到同一 PC/指令再次提交，且
trace 记录包含有效 vector/GPR 副作用。它不是 inactive commit payload 仅被哈希到的
假阳性。F1a 仍应默认关闭，下一任务需修复并重新做严格锁步/成对验证。

完整 JSONL trace 和比较 JSON 只保存在本 worktree 的 `build/agents/T-20260830-044/`
下，不进 Git。本文保存有限上下文、SHA 和可复现命令。

## 1. provenance 与实现

| 项目 | 值 |
| --- | --- |
| base SHA | `ab6e44f6de301a50dd8930b7e457ee6e4ba3d424` |
| diagnostic source SHA（runner 编译源） | `5f7120ac768f2c5257f7ae1899787829e6065ed9` |
| comparator footer/provenance 修复提交 | `cbd63645441677907caecb99857e01240b8cae47` |
| branch | `verify/T-20260830-044-f1a-commit-divergence` |
| worktree | `/home/chiro/projects/mycpu/lcvex-wt-T-20260830-044` |
| Verilator | `5.050 2026-07-01 rev conda-forge build 0` |
| 交叉编译器 | `aarch64-linux-gnu-gcc (GCC) 16.1.0` |
| workload 编译 | `-O2`，同一个 `.bin` 给 f0/f1a 复用 |
| FIFO 参数 | f0=`FETCH_FIFO_ENABLE=0`；f1a=`FETCH_FIFO_ENABLE=1`，depth=2 |
| 重型资源 | `MemoryMax=15G`、`MemorySwapMax=0`、`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1` |

runner 新增 `--trace FILE`，只有显式给出该参数才打开文件和 trace 分支。无 trace 时的
JSON 字段、周期、retired、digest 和退出码保持旧路径。JSONL 由 header、commit records、
footer 组成：

- commit record 含 `seq`、`cycle`、`pc`、`insn`、`next_pc`；
- `effects` 只写有效的 GPR/GPR2/GPR3、SP、NZCV、memory、exception、monitor、vector、
  FPCR/FPSR 字段，未使能 payload 省略；
- `fetch` 保留该提交周期的 epoch、occupancy、peak、push/pop/flush、stale drain/drop；
- header/footer 含 workload/image/source SHA、参数、状态、retired 和 digest。

比较器 `scripts/compare_commit_traces.py` 逐行读取、只保留有限的 before/after window，
架构比较忽略 `seq`、`cycle` 和 `fetch`，并分类 `duplicate`、`skip`、`wrong-path`、
`effect-mismatch`、`termination-boundary`。它还输出 header provenance、两侧 trace SHA、
footer、配置参数和 `objdump` 反汇编（不可用时保留 `.inst` 回退）。

## 2. 验证摘要

| 用例 | 结果 |
| --- | --- |
| comparator equal/duplicate/skip/effect/wrong-path/termination fixture | PASS |
| f0/f1a runner 构建 | 两个均 PASS；每次单独 cgroup、单线程 |
| 无 trace `alu_latency` f0 | `cycles=2500171`，`retired=750049`，`commit=e02f90ea8089a4f1` |
| 无 trace `alu_latency` f1a | `cycles=2000136`，`retired=750049`，`commit=e02f90ea8089a4f1` |
| `alu_latency` 完整架构 trace compare | `equal`，750049 records；source/image/参数（除 FIFO 开关）一致 |
| 无 trace/trace `fp_scalar` f0/f1a | `65963/65965` retired，均 pass |
| 无 trace/trace `mem_seq` f0/f1a | `803657/803667` retired，均 pass |
| trace comparator | `fp_scalar=duplicate`、`mem_seq=duplicate` |

无 trace 负对照的周期/retired/digest 与 T-043 历史值一致；开启 trace 只增加诊断输出，
不会改变这些架构/性能字段。`alu_latency` 原始 trace SHA 不同是因为 cycle 和 FIFO
观测字段不同；比较器报告的架构 commit sequence 完全相同。

## 3. `fp_scalar` 第一处分歧

比较命令：

```sh
python3 scripts/compare_commit_traces.py \
  --off build/agents/T-20260830-044/traces/fp_f0.jsonl \
  --on build/agents/T-20260830-044/traces/fp_f1a.jsonl \
  --out build/agents/T-20260830-044/comparisons/fp.json
```

结果：`status=mismatch`、`category=duplicate`、共同架构前缀 65,957 条，第一差异为
两侧第 65,958 条提交。

| 侧 | seq/cycle | PC | 指令/反汇编 | active effect | fetch context |
| --- | ---: | --- | --- | --- | --- |
| f0 | 65958 / 226575 | `0x44000578` | `0xfd40041f` — `ldr d31, [x0, #8]` | vector rd31, lo=`0x41f0000000000000` | epoch=0, occ=0, peak=0，脉冲全 0 |
| f1a | 65958 / 172970 | `0x44000574` | `0xbd47703f` — `ldr s31, [x1, #1904]` | vector rd31, lo=`0x4f800000` | epoch=50, occ=0, peak=2，脉冲全 0 |

f1a 的 seq 65957 已提交同一条 `0x44000574/bd47703f`，seq 65958 再次提交它，
seq 65959 又再次提交它，随后才到 `0x44000578`；因此最终多出 2 条 retired。第一差异
之后 f1a 的 seq 65961 在 `0x4400057c` 发生 `flush=1, stale_drop=1`，说明 trace 能把
差异附近的 frontend 代次/清理事件保留下来，但首个重复本身发生在无 flush 脉冲的提交
周期。两侧 footer 分别为 retired `65963/65965`，commit digest
`0x78dbdb2d365390ea/0x1cbe38d7f5aa2933`，memory digest 相同
`0x4078dabba91c60f0`。

## 4. `mem_seq` 第一处分歧

比较命令：

```sh
python3 scripts/compare_commit_traces.py \
  --off build/agents/T-20260830-044/traces/mem_f0.jsonl \
  --on build/agents/T-20260830-044/traces/mem_f1a.jsonl \
  --out build/agents/T-20260830-044/comparisons/mem.json
```

结果：`status=mismatch`、`category=duplicate`、共同架构前缀 15 条，第一差异为两侧第
16 条提交。

| 侧 | seq/cycle | PC | 指令/反汇编 | active effect | fetch context |
| --- | ---: | --- | --- | --- | --- |
| f0 | 16 / 61 | `0x44000108` | `0xf86a7967` — `ldr x7, [x11, x10, lsl #3]` | GPR x7=`0x1000` | epoch=0, occ=0，脉冲全 0 |
| f1a | 16 / 48 | `0x44000104` | `0xaa0a03e6` — `mov x6, x10` | GPR x6=`0` | epoch=3, occ=1, peak=1，`pop=1` |

f1a 的 seq 15 已提交 `0x44000104/aa0a03e6`，seq 16 再次提交同一条，seq 17 又再次
提交，seq 18 才到 `0x44000108`。首个重复周期的 FIFO occupancy 从 1 通过 `pop=1`
消耗；此后 occupancy=0。后续 trace 能继续看到 `0x44000108` 及后续顺序流，表明这里
是插入 duplicate retirement 而不是单纯终止边界差异。两侧 footer 分别为 retired
`803657/803667`，commit digest `0x826084b57439f54a/0x2cb364e799addcd1`，memory
digest 相同 `0x6b40dea7a6ade5c3`。

## 5. 根因候选与证伪条件

这些是诊断假设，不是已完成的 RTL 修复结论。

1. **FIFO pop 与 IF/ID consume/replace 没有严格绑定（最高优先级）。**
   `rtl/lcvex_core.sv:812-819` 的 `fetch_fifo_pop` 没有直接表达“当前 IF/ID 本拍必定
   被 ID/EX 接收”；`rtl/lcvex_core.sv:2564-2577` 则在 pop 时把 FIFO head 写入 IF/ID。
   `mem_seq` 的第一差异恰好是当前 `mov x6,x10` 已提交后，`occupancy=1,pop=1` 又产生
   同 PC/insn，强烈支持重复 head/IFID replace。证伪：增加只读 FIFO head PC/seq 与 IF/ID
   accept/valid 观测后，若首差异时 head 明确是下一条且 ID/EX 也已接收旧 IF/ID，则该
   假设不成立。下一 RTL fix 应在 `rtl/lcvex_core.sv` 收紧 pop/replace 原子条件，并加
   “pop 必须对应 IF/ID advance、同一 PC 不得重复提交”的 SVA；定向测试写集为
   `rtl/lcvex_core.sv`、`tb/sv/lcvex_fetch_fifo_tb.sv`、`sim/cocotb/test_fetch_fifo.py`。

2. **flush 后 tail/context 与已存在 IF/ID entry 重叠。** F1a 用
   `fetch_pc_r/fetch_ctx_*` 组装 push entry（core 同文件 `:855-884`），而 flush/epoch
   在 `:795-801` 统一清理。若同拍或相邻拍的旧 context 被作为当前 entry，可能把已交付
   PC 再放回 FIFO。证伪：head/tail 的 `pc_va/seq/epoch` trace 显示重复前 entry 来源不
   是旧 context，且 flush 后新代的请求 PC 单调 `+4`。需要时只在 core 增加内部 debug/SVA，
   不应把公共 `mem_rsp_t` 无 tag 协议扩展混入本修复。

3. **仅 commit digest 的 inactive payload 假阳性。** 该候选已被动态 trace 证伪为低可信：
   第一差异的 PC/insn 本身重复，且 vector/GPR active effect 被规范化写入 record；
   `mem_seq` 的 memory digest/effect count 仍相同，但 retired sequence 已插入真实重复
   指令。证伪条件已满足，不应通过改 digest 忽略它。

4. **时序/缓存改变暴露窗口。** 历史上 delay0/cache 组合多退休，delay1 多数等价；
   本次首差异在 `nocache_d0` 已出现，FIFO occupancy=1/2 与 branch/loop 频率相关，故
   该候选更像触发条件而非根因。可用同一 source 运行 delay1、固定 stall/backpressure
   和 cache 变体做交叉验证；这些不属于本任务已完成套餐。

## 6. 观测边界与下一步

当前公开顶层只给 FIFO occupancy、push/pop/flush、stale、epoch/peak，没有 FIFO head/tail
的 `pc_va/seq`、IF/ID valid/PC、ID/EX advance 或 `stall_if` 的 trace 端口。因此本任务
可以确定第一处分歧和 duplicate 分类，但不能仅凭公开端口证明重复 entry 的具体来源。
不为此扩大 T-044 写集，也不修改 RTL/TB。

建议下一修复任务精确写集：

- `rtl/lcvex_core.sv`：修正 FIFO head 到 IF/ID 的 consume/replace 原子绑定；加入
  `pop -> IF/ID advance`、entry `pc/seq/epoch` 单调/不重复和 commit 不重复断言；
- `tb/sv/lcvex_fetch_fifo_tb.sv`、`sim/cocotb/test_fetch_fifo.py`：加入可控 load-use/
  stall + FIFO head refill 的 duplicate 回归；
- `sim/difftest/test_program.py`、`sim/difftest/run_f1a.sh`：把 duplicate 场景纳入
  feature-on strict lockstep；必要时只读暴露内部 head/IFID debug，不改公共内存 ABI。

在修复和严格验证完成前，`FETCH_FIFO_ENABLE` 保持默认 0；F1b 继续阻断。

## 7. trace/comparison hashes

| 文件 | SHA256 |
| --- | --- |
| `traces/alu_f0.jsonl`（750049 records，202569750 bytes） | `3d5be64ea62361d2d333cd94b604fa3ada02863e6c499c24d174a314d41d233d` |
| `traces/alu_f1a.jsonl`（750049 records，203664107 bytes） | `03fd8d371c39a3f183cc24544d3b97f5c806df3a53ebd3454413b26ce782aa16` |
| `traces/fp_f0.jsonl`（65963 records，19975709 bytes） | `57b487563be7219db39f79649a7c795053f872116909f9c7ad653053062b2ebb` |
| `traces/fp_f1a.jsonl`（65965 records，20069206 bytes） | `f557cf5afe4b676a64fb109ad8805b33cbc6933749d52d9f482db44a44d5ac3d` |
| `traces/mem_f0.jsonl`（803657 records，224843212 bytes） | `53961e052ed8f2197b631efb7b4bb5ece473b5910f4171d956012d51a2f46a15` |
| `traces/mem_f1a.jsonl`（803667 records，226055027 bytes） | `824518d1b299e5a7755f0ac28a1b36a7a87bbf6834c6fe60dea87bda8d589cfc` |
| `comparisons/alu.json` | `700230bf71718e0de1396420eb736339e45c1136454dacda0ed66a2fcc8a1938` |
| `comparisons/fp.json` | `175dd620ffccba9ade7737038ab9f8f7de64b76782699ecf3004a35a44c1ca2e` |
| `comparisons/mem.json` | `fbf19cceccc4c1eba01cf1289dee0ca90348a951195339f3aa3a99ac1cd1930c` |
