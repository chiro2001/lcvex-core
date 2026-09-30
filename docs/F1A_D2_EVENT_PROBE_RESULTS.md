# F1a `nocache_d2` 三 workload 有界事件因果 probe

> 任务：`T-20260901-009`（PE-F1H-D2-EVENT-PROBE）<br>
> 状态：review；本报告包含 probe 实现、6 行定向复测和事件级分析。<br>
> base/source：`b8a7294204de06b3c00f3abc02e181f6d035ac23`<br>
> report_tip：见最终报告（承载文档的 Git tip 不在 evidence 自引用）<br>
> received_at：`2026-09-01T11:08:01+08:00`；reported_at：`2026-09-01T12:20:08+08:00`

## 结论

在冻结 source 上，own worktree 重建 `nocache_d2_f0`/`nocache_d2_f1a` 两个
Verilator runner 和三个 workload image，串行完成 6 行、10M cap。6/6 行 `pass`，
cycles、retired、v2 commit digest、memory digest 与 T-004 对应值逐行一致；三项
性能护栏原样复现：

| workload | F0 cycles | F1a cycles | Δcycles | 增幅 | guard 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| `alu_latency` | 5,795,747 | 6,219,933 | +424,186 | +7.319% | FAIL |
| `ctrl_branch` | 5,172,730 | 5,749,229 | +576,499 | +11.145% | FAIL |
| `mem_seq` | 7,273,882 | 7,456,315 | +182,433 | +2.508% | FAIL |

probe 观测到三项共同的事件链：

```text
frontend_kill/flush
  -> epoch bump
  -> stale_drain 开始并阻止新的 fetch issue
  -> delay response pending 后被 stale drop 消费
  -> stale_drain 结束
  -> 当前 PC 重新发出 imem request
```

因此三项共享同一个 F1a stale-quarantine/delay2 触发链；`alu_latency` 和
`ctrl_branch` 是前端等待放大子类，`mem_seq` 是数据访存与 delay pending 重叠
不同造成的吞吐/相位子类，而不是独立触发源。现有证据没有显示 FIFO overflow、
epoch 错配、单 outstanding 违例或架构状态差异，也没有定位某一条 RTL 赋值为
唯一缺陷。F1a 默认启用和性能签核继续阻塞，`2%+64` 阈值不变。

## 1. Probe 契约与实现边界

本任务只增加诊断观测，不改变功能路径：

- [`rtl/lcvex_mem_delay.sv`](../rtl/lcvex_mem_delay.sv) 增加
  `probe_req_pending`、`probe_rsp_pending`、`probe_delay_count`、`probe_lfsr`
  纯组合输出。mode 0 输出固定零；mode 1/2 镜像既有寄存器，没有新状态、reset
  或握手副作用。
- [`tb/sv/lcvex_soc_tb.sv`](../tb/sv/lcvex_soc_tb.sv) 显式接线 delay 状态和
  imem/dmem/PTW、arb/L2、delay、RAM、frontend/FIFO 状态；runner 不读取 delay
  block 的不稳定 C++ 层次名。
- [`sim/microbench/microbench_runner.cc`](../sim/microbench/microbench_runner.cc)
  的 `--probe FILE` 为 opt-in；无 `--probe` 时默认 JSON/counters 不增加 probe
  字段。probe schema 为 `lcvex-f1a-d2-event-v1`。
- probe 只保存完整 aggregate counters、8-bin latency/starvation histogram、
  首事件窗口（每种事件最多 8 条、全局上限 128）和前 32 条 commit canonical
  key；事件窗口达到上限会显式 `event_window_truncated=true`，tracking 达到上限
  会显式 `tracking_truncated=true`，顶层 `truncated` 为二者或其 tracking 状态
  的并集。
- [`sim/microbench/perf_runner.py`](../sim/microbench/perf_runner.py) 只在传入
  `--probe` 时转发路径；`--probe-self-test` 不启动仿真，覆盖 schema、记录上限
  和默认关闭口径。

本次 6 行的 `truncated=false`、`event_window_truncated=false`、
`tracking_truncated=false`。前 32 条 commit prefix 是有意的固定窗口，字段
`commit_prefix_truncated=true` 只表示后续 commit 未存入窗口；完整架构等价仍由
全量 v2 digest 和 memory digest 验证。

## 2. Provenance 与复现结果

权威紧凑汇总为
[`f1a_d2_event_summary.json`](evidence/artifacts/T-20260901-009/f1a_d2_event_summary.json)。
完整 report/probe/stdout/stderr 保留在 own worktree 的
`build/agents/T-20260901-009/`，不进入 Git。

| 项目 | 值 |
| --- | --- |
| source/base SHA | `b8a7294204de06b3c00f3abc02e181f6d035ac23` |
| Verilator | 5.050 (2026-07-01, conda-forge build 0) |
| cross compiler | `aarch64-linux-gnu-gcc 16.1.0` |
| image flags | `-O2` |
| delay | `MEM_DELAY_MODE=2`, `RAND_MAX=4`, `SEED=0xA5` |
| FIFO | depth=2；F0 enable=0；F1a enable=1 |
| max cycles | 10,000,000 |
| run scope | `run-p1246479-i34801077.scope` |
| run interval | 12:02:43–12:10:35 +08:00 |
| run resource | wall 472.285 s；CPU 236.161 s；peak 142M；15G/no-swap/50% CPU |

runner/image SHA256：

| artifact | bytes | SHA256 |
| --- | ---: | --- |
| `microbench_runner_nocache_d2_f0` | 12,829,896 | `c51a16cc723590879ad0284c834c773ec4d566c40738cefc0d4409d5d7771e6c` |
| `microbench_runner_nocache_d2_f1a` | 12,842,880 | `5565a24bccd090d2bc2d2a6e410bfde6444f6be0a04229037368550aa7df8f5f` |
| `perf_alu_latency.bin` | 1,096 | `fd70bfab998b564fd78b6dddd0e29ec3814f31409118868c50511cfb3cae6b4b` |
| `perf_ctrl_branch.bin` | 1,192 | `e193e924e846b0102cf58740dace1021d476fb6cdf56c732ec6d4a00a4f42890` |
| `perf_mem_seq.bin` | 1,048 | `92c4cf43107a173345475b6ced3048356a6a1f56a4bacbe563e2a5eddf5b9527` |

6 行摘要：

| workload/mode | status | cycles | retired | commit digest | memory digest | probe bytes |
| --- | --- | ---: | ---: | --- | --- | ---: |
| `alu_latency/f0` | pass | 5,795,747 | 750,049 | `ab7d672bf0489762` | `0dd7f555d8ef95bf` | 18,626 |
| `alu_latency/f1a` | pass | 6,219,933 | 750,049 | `ab7d672bf0489762` | `0dd7f555d8ef95bf` | 27,316 |
| `ctrl_branch/f0` | pass | 5,172,730 | 690,074 | `a555baec3f932af5` | `0617c8083a02b214` | 18,642 |
| `ctrl_branch/f1a` | pass | 5,749,229 | 690,074 | `a555baec3f932af5` | `0617c8083a02b214` | 27,319 |
| `mem_seq/f0` | pass | 7,273,882 | 803,657 | `46e5ead18aa77a80` | `6b40dea7a6ade5c3` | 18,642 |
| `mem_seq/f1a` | pass | 7,456,315 | 803,657 | `46e5ead18aa77a80` | `6b40dea7a6ade5c3` | 27,314 |

每对前 32 条 canonical commit key 完全相等；三对全量 digest 和 memory digest
也完全相等。与 T-004 的 cycles、retired、digest、memory 值逐行相等，而不是
仅复现百分比。

## 3. 事件级结果

### 3.1 Flush、stale、delay 和 fetch issue

F0 的这些 F1a 事件计数均为 0。F1a 的 aggregate 如下：

| workload | kill/flush | stale_drop | drain windows/cycles | stale∩delay-rsp | stale∩delay-req | fetch issue blocked | raw valid&&!ready |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 250,011/250,011 | 250,009 | 250,009/1,054,904 | 804,895 | 0 | 1,054,904 | 0 |
| `ctrl_branch` | 220,011/220,011 | 220,006 | 220,006/901,818 | 681,812 | 0 | 901,818 | 0 |
| `mem_seq` | 172,124/172,124 | 172,101 | 172,101/677,434 | 505,333 | 0 | 677,434 | 0 |

这里的 `fetch issue blocked` 定义为 stale quarantine 或 raw fetch valid&&!ready；
三项 raw valid&&!ready 都为 0，故所有新增 fetch issue 阻塞恰好来自
`stale_drain`。`stale_drop` 少于 kill 的 2/5/23 个事件在 MAGIC 完成边界前仍
没有对应 stale response，probe 保留为 `unresolved_kill_windows`，没有静默补零。

三项首事件窗口的共同片段为：

```text
cycle 23  frontend_kill  delay_req_pending=true
cycle 24  stale_drain_start / fetch_issue_blocked_start
cycle 28  stale_drop       delay_rsp_pending=true, delay_count=0
cycle 29  stale_drain_end / fetch_issue_blocked_end / imem_reissue_after_kill
```

这直接确认了“kill 后等待旧 delay response，再重发当前取指”的事件顺序。事件
窗口固定上限没有截断；重复事件由 aggregate count 和 histogram 完整统计。

### 3.2 Kill-to-response 延迟直方图

直方图 bin 为 `0,1,2,3,4,5-8,9-16,17+` 周期；每个 F1a pair 的两个 histogram
和为对应完成事件数：

| workload | kill→stale drop | kill→drain end |
| --- | --- | --- |
| `alu_latency` | `0,0,36587,54884,42684,115854,0,0` | `0,0,0,36587,54884,158538,0,0` |
| `ctrl_branch` | `0,0,34844,50363,42551,92248,0,0` | `0,0,0,34844,50363,134799,0,0` |
| `mem_seq` | `0,0,20655,60365,25500,65581,0,0` | `0,0,0,20655,60365,91081,0,0` |

三项均没有 9+ 周期长尾；`17+` 为 0。`mem_seq` 的 5–8 bin 计数较小但仍是
同一 2–8 周期响应窗口，而非新协议路径。

### 3.3 非重叠/重叠核算

所有 `stale_drain` 与 `mem_stall` 的交集为 0，所以在每个 F1a 运行内部：

```text
union(stale_drain, mem_stall)
  = stale_drain + mem_stall
```

`stale_drain` 与 delay pending 则有约 75% 的响应 pending 重叠；其余为
stale-only。下表给出可审计的非重叠子集、重叠比例、cycle guard 余量和 commit
starvation 最大 run；不能把这些事件时间宣称为净 cycle delta 的线性和。

| workload | F1a stale cycles | stale∩delay | stale-only | stale∩delay 比例 | F1a stale∪mem | Δcycles−stale-only | Δcycles / imem reissue | guard 超限 | max starvation F0→F1a |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 1,054,904 | 804,895 | 250,009 | 76.300% | 1,054,962 | 174,177 | 1.696669 | +308,207.06 | 27→28 |
| `ctrl_branch` | 901,818 | 681,812 | 220,006 | 75.604% | 1,114,390 | 356,493 | 2.620319 | +472,980.40 | 26→29 |
| `mem_seq` | 677,434 | 505,333 | 172,101 | 74.595% | 3,000,379 | 10,332 | 1.059893 | +36,891.36 | 66→66 |

`Δcycles−stale-only` 是算术余量，不是因果归因；它包含 FIFO 并行收益、delay
pending 与原有访存等待的重排等重叠效应。guard 超限按
`F1a - (F0*1.02+64)` 计算，三项均为正，故不能放宽门槛。

### 3.4 Delay pending、访存和 starvation

| workload | delay pending F0→F1a | delay rsp pending F0→F1a | mem_stall F0→F1a | mem∩delay F0→F1a | mem∩stale F1a | imem reissue F1a | imem extra-vs-retired F1a |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 3,295,575→4,219,798 | 2,545,520→3,219,734 | 63→58 | 43→42 | 0 | 250,011 | 250,010 |
| `ctrl_branch` | 2,842,449→3,869,003 | 2,132,352→2,938,900 | 230,203→212,572 | 150,129→152,509 | 0 | 220,011 | 220,007 |
| `mem_seq` | 4,231,669→4,816,260 | 3,198,575→3,611,065 | 2,531,444→2,322,945 | 1,613,700→1,577,290 | 0 | 172,124 | 172,102 |

`alu_latency`/`ctrl_branch` 的新增 imem request 与 reissue-after-kill 一一对应，
且 stale drain 与 data mem stall 没有交集，故其净回退是前端等待放大。`mem_seq`
也有完全相同的 reissue/stale 链，但它原本的 data memory stall 很大，F1a 的
`fetch_wait`/`mem_stall` 重排抵消了大部分 stale gross time；因此只剩 36,891.36
周期的 guard 超限。这是同一触发链的 throughput/overlap 子类，而不是证据支持的
第二个独立根因。

commit starvation 的完整 8-bin histogram 保存在 summary 对应的 per-run probe
中；本次最大无提交 run 只从 27→28、26→29 或 66→66 变化，没有出现无限饥饿。

## 4. RTL 对照与证据边界

动态顺序与冻结 RTL 的关系如下：

1. `lcvex_core.sv` 的 `frontend_kill` 同拍 flush FIFO、bump epoch，并把旧的
   in-flight fetch 纳入 stale quarantine；`fetch_imem_req_valid` 在
   `fetch_stale_drain` 时关闭。
2. stale response 通过 `imem_rsp_ready` 被消费/丢弃，随后当前 PC 重新发出
   imem request。probe 的 kill→drop→drain-end histogram 和首事件窗口逐项观察到
   这一顺序。
3. `stall_id` 把 `fetch_stale_drain` 传入 `stall_if`；本次 probe 还观察到
   `fetch_issue_blocked == stale_drain`，但 raw valid&&!ready=0，说明瓶颈是协议
   quarantine 等待而非 downstream ready-low。
4. delay module 为单 outstanding；本次 stale drain 与 `delay_rsp_pending` 有
   74.595–76.300% 交集，与 `delay_req_pending` 无交集，符合 stale response 已
   到达 delay response holding/ready 边界后才被消费的路径。
5. FIFO occupancy/peak：三个 F1a pair 分别为 1/1、1/1、2/2；overflow=0，
   push=pop。因果证据指向等待/重取指成本，不指向容量越界或 push/pop 破坏。

这些结论是事件级因果链确认，不等于已证明存在功能 bug；probe 也没有 QEMU
状态，因此不提供 QEMU-side failure现场。commit prefix 与 full digest 均无差异，
所以不能把性能回退误写成架构不等价。

## 5. 后继修复建议与最小验证集

当前证据不要求把三项拆成两个触发根因：建议登记一个共享
“F1a stale-quarantine 与 delay2 fetch recovery”最小修复任务，验收保留三个
定向 workload。修复任务仍应只在功能语义明确后改变 RTL，并同时检查：

- kill/stale response 的等待是否可安全与当前取指或其他独立工作重叠；
- stale drop 后当前 PC 是否可以避免无效的重复 issue，且不放宽 epoch/响应隔离；
- `mem_seq` 的高 data-memory overlap 是否需要独立调度/背压子优化；
- 三项 commit digest、memory effects、FIFO bounds 和 `2%+64` guard 均不回退。

若下一次 probe 或修复前后比较发现首条 commit 差异、overflow、单 outstanding
违例或新的长尾，立即停止并拆分为协议正确性任务与性能任务；不得降低阈值或过滤
失败样本。

## 6. 验收边界

本任务已完成 probe 实现、6 行定向复测、摘要 artifact 和事件级 cycle accounting。
未运行完整矩阵、Gate D、Linux、Quartus、QEMU lockstep；没有修改 workload、
commit digest schema、比较器、参考结果或性能阈值。F1a 仍保持默认关闭。
