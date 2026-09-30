# F1a 控制流边界取指 fence 性能修复

> 任务：`T-20260901-010`（PE-F1I-CONTROL-FLOW-FETCH-FENCE）<br>
> 状态：review；本 provenance correction 重新归属 6 行 T-009 对照 probe。<br>
> base_sha：`c44a4bce153904631574141a8b0c7d2c71e6ef88`；implementation_source_sha：`d69f5bd08a6d87452ce96617520e5c4d7fe82ff0`；measurement_source_sha：`d69f5bd08a6d87452ce96617520e5c4d7fe82ff0`<br>
> report_tip：见最终报告（承载文档的 Git tip 不在 evidence 自引用）<br>
> received_at：`2026-09-01T16:05:59+08:00`；reported_at：`2026-09-01T16:25:47+08:00`

## 结论

在 `d69f5bd08a6d87452ce96617520e5c4d7fe82ff0` 功能提交对应代码上，复用已由该提交
构建的 F0/F1a runner 和三个 image，在新的 provenance scope 重新运行 `nocache_d2`
三项 10M F0/F1a probe。六行全部通过原 `2%+64` guard，且 F0 没有被拖慢：

| workload | F0 cycles | F1a cycles | Δcycles | 增幅 | guard 上限 | 余量 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | 5,795,747 | 4,904,275 | -891,472 | -15.381% | 5,911,725.94 | 1,007,450.94 |
| `ctrl_branch` | 5,172,730 | 4,599,259 | -573,471 | -11.086% | 5,276,248.60 | 676,989.60 |
| `mem_seq` | 7,273,882 | 6,664,445 | -609,437 | -8.378% | 7,419,423.64 | 754,978.64 |

6/6 行 `status=pass`，retired、v2 commit digest、memory digest 与 T-004 对应值
严格一致；F1a 的 imem request/response 与 F0 完全相等，stale-context drop、
drain、reissue 均为 0。当前 probe schema 是
`lcvex-f1a-d2-event-v2-stale-context`；T-009 的
`lcvex-f1a-d2-event-v1` 只作为 reference schema 记录。F1a 仍保持默认关闭，待
集成者在新 SHA 上运行完整 196-row 矩阵。

summary/evidence 同时记录：`reference_probe_schema=lcvex-f1a-d2-event-v1`、
`current_probe_schema=lcvex-f1a-d2-event-v2-stale-context`。

## 1. 最小实现

### 1.1 Raw control-flow predecode

[`rtl/lcvex_core.sv`](../rtl/lcvex_core.sv) 新增纯组合 `raw_control_flow`：

- `insn[30:26]==5'b00101`：B/BL；
- `insn[31:25]==7'b0101010 && !insn[4]`：B.cond；cond E/F 仍纳入，保留位 bit4
  与 decoder 一致；
- `insn[30:25]==6'b011010`：CBZ/CBNZ；
- `insn[30:25]==6'b011011`：TBZ/TBNZ；
- BR family 只接受 `insn[31:25]==7'b1101011`、`[20:16]==5'b11111`、
  `[15:10]==0` 且 `[24:21]` 为 0000/0001/0010，即 BR/BLR/RET；reserved
  op2 不触发 fence。

FIFO entry 只有 `valid && !fault && entry_epoch==fetch_epoch` 才能触发；IF/ID
还要求 `valid && d.valid && ifid_token_epoch==fetch_epoch`。因此 stale、fault、
invalid 或 feature-off 路径不会误判。

### 1.2 Fence 生命周期

`fetch_control_fence` 只门控 `fetch_req_valid` 和 `fetch_imem_req_valid`：

```text
current-epoch FIFO/IFID 持有未由 decode/flush 解析的 control-flow
    -> 禁止更年轻普通 fetch accept
    -> 允许 FIFO pop / space / stall_if / data_req_valid 正常运行
    -> 现有 d.next_pc、flush_id、frontend_kill 决定 taken/not-taken 和 redirect
```

没有引入预测器、BTB、RAS、提前目标计算或新状态/reset。taken 分支仍由既有
`flush_id`/`frontend_kill` 处理；not-taken 分支在 decode 后通过 FIFO/IFID 交接
恢复，不增加预测空洞。全局 SVA 增加 `!fetch_fifo_active |-> !fetch_control_fence`，
F1a SVA 增加 fence 有效时无普通 `fetch_req_accept/imem_req_accept`。

## 2. 定向验证

### 2.1 SV/Cocotb

- `make test-f1a`：PASS；新增 raw encoding fixture 覆盖 B/BL、B.cond、CBZ/CBNZ、
  TBZ/TBNZ、BR/BLR/RET，拒绝 B.cond reserved bit、BR reserved op2、UDEF、SVC、
  ERET、DSB；taken B fence/epoch/无 fetch accept 断言通过。
- `make cocotb-f1a`：PASS，3/3；原 FIFO、ready backpressure、dmem hold 测试通过，
  新增 B、B.cond taken/not-taken、CBZ/CBNZ、TBZ/TBNZ、BR register target，含
  `commit_ready` hold 的 fence cases 全通过。
- `make f1a-control-flow-fence-smoke`：PASS；同一 SV 入口分别运行 cache-off 和
  `I_L1_ENABLE=D_L1_ENABLE=L2_ENABLE=1`、`MEM_DELAY_MODE=2`，均通过 fence/epoch/
  取指边界检查；`+T010_IABT` 负控通过，确认 branch-target IABT 的 `d.exc` 不会
  卡住 fence，commit PC=`BASE+4`、FAR=`0x5000`、epoch 变化。

### 2.2 T-009 probe 6 行

使用当前 `lcvex-f1a-d2-event-v2-stale-context` probe；本轮不重编译，复用由
`d69f5bd08a6d87452ce96617520e5c4d7fe82ff0` 构建的两个 runner 和三个 image，在新的
`build/agents/T-20260901-010-correction-provenance/` 目录运行。所有行
`max_cycles=10,000,000`、同一 source/tool/image/seed，且 report 的
`sha/git_sha/measurement_source_sha` 均为 d69 全 SHA。严格比较 status、retired、v2
commit digest、memory digest、FIFO bounds、stale-context 事件和 guard。历史 T-009
`lcvex-f1a-d2-event-v1` 仅用于 `t009_f1a_cycles` reference tuple。

| workload/mode | status | retired | commit digest | memory digest | F1a kill/flush | stale-context kill | stale-context drop/drain | imem request | reissue after stale kill |
| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `alu_latency/f0` | pass | 750,049 | `ab7d672bf0489762` | `0dd7f555d8ef95bf` | 0/0 | 0 | 0/0 | 750,050 | 0 |
| `alu_latency/f1a` | pass | 750,049 | `ab7d672bf0489762` | `0dd7f555d8ef95bf` | 250,011/250,011 | 0 | 0/0 | 750,050 | 0 |
| `ctrl_branch/f0` | pass | 690,074 | `a555baec3f932af5` | `0617c8083a02b214` | 0/0 | 0 | 0/0 | 690,075 | 0 |
| `ctrl_branch/f1a` | pass | 690,074 | `a555baec3f932af5` | `0617c8083a02b214` | 220,011/220,011 | 0 | 0/0 | 690,075 | 0 |
| `mem_seq/f0` | pass | 803,657 | `46e5ead18aa77a80` | `6b40dea7a6ade5c3` | 0/0 | 0 | 0/0 | 803,658 | 0 |
| `mem_seq/f1a` | pass | 803,657 | `46e5ead18aa77a80` | `6b40dea7a6ade5c3` | 172,124/172,124 | 0 | 0/0 | 803,658 | 0 |

F1a FIFO bounds 分别为 occupancy/peak `1/1`、`1/1`、`2/2`；push=pop、overflow=0。
`frontend_kill` 仍按 taken control-flow 正常发生，但三项的 kill 全部
`kill_without_stale_context`，没有旧取指需要 quarantine。v2 的 stale candidate 严格
为 `fetch_pending || fetch_trans_busy || fetch_stale_imem || fetch_stale_mmu`，明确
排除仅表示翻译完成的 `fetch_translated`。F1a 相对原 T-009
F1a cycles 分别改善 1,315,658、1,149,970、791,870 周期。

Stall delta（F1a-F0）为：

| workload | Δstall_if | Δfetch_wait | Δbranch_flush | Δmem_stall | Δload_use |
| --- | ---: | ---: | ---: | ---: | ---: |
| `alu_latency` | -6 | -1,141,540 | 0 | -6 | 0 |
| `ctrl_branch` | -46,476 | -945,419 | 0 | -46,476 | 0 |
| `mem_seq` | -216,137 | -2,378,616 | 0 | -216,137 | +1 |

其余 `ptw_stall`/`muldiv_stall`/`wb_stall` 无功能性变化；所有 request/response
通道与 F0 相等。probe 的 event window、stale-context tracking 均未截断；前 32 条
canonical commit key 每对相等（commit prefix 自身单独受 32 条上限约束）。

## 3. 资源和复现入口

所有重型命令均置于 `MemoryMax=15G`、`MemorySwapMax=0`、`CPUQuota=50%`、
`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1` 的 systemd scope，且未与其他重型任务并发。

| 作业 | scope | wall | CPU | peak/分配 |
| --- | --- | ---: | ---: | ---: |
| 本 provenance correction 六行 v2 probe | `run-p1951293-i35479004.scope` | 425.095 s | 212.595 s | 141.9M |
| 复用的 d69 runner/image 构建 | 见上一轮受限 scope | 未重编译 | 未重编译 | 已验证 artifact hash |

在上一轮 accepted 六行结果/evidence 之后、上一轮 `2026-09-01T14:35:11+08:00` correction
dispatch 之前，校验串曾误启动一次未置于 systemd scope 的 plain `make
f1a-control-flow-fence-smoke`（默认 `-j6`）；约 20 秒内发现并终止，未产生或采用
任何测试结果。上表及 evidence 只计入已受 cgroup 限制的有效作业。

紧凑机器可读结果：
[`f1a_control_flow_fence_summary.json`](evidence/artifacts/T-20260901-010/f1a_control_flow_fence_summary.json)。完整 report/probe/log 留在
`build/agents/T-20260901-010-correction-provenance/`，不进 Git。旧的
`build/agents/T-20260901-010-correction/` c44-labeled raw reports/probes 保留但明确
排除，不覆盖伪装为当前 provenance。

## 4. 风险、边界和 next

- raw predecode 与 `lcvex_decode.sv` 有一份受控的编码镜像；未来新增控制流编码时
  必须同步更新并保留 reserved negative fixture。
- 当前证据覆盖 cache-off/cache-on SV、delay2 六行和现有 F1a Cocotb；未运行完整
  196-row/98-pair 矩阵、Gate D、Linux、QEMU lockstep 或 Quartus。
- 这不是把 F1a 默认开关立即打开的签核；集成者应在合并 SHA 上重跑三项及完整矩阵，
  并确认其它 workload 没有超过原 guard。
- 建议后继登记一个共享 control-flow fetch-fence 修复验证任务，验收保留三项
  guard、架构 digest、FIFO/epoch/stale 边界；若其它控制流出现语义差异，立即拆成
  协议正确性任务和性能任务，不降低阈值。
