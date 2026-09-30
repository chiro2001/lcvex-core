# T-20260909-003：B25 provisional timing top-N 交接

```text
task=T-20260909-003
state=provisional-analysis-complete
acceptance=PROVISIONAL；no RTL candidate
base/source/head=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
r21_physical_source=80b1f813de47a1223dd135117650419a0b6c05fc
branch=verify/T-20260909-003-b25-provisional-timing-topn
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-003
sent_at=2026-09-09T01:21:51+08:00
restart_recovery_received_at=2026-09-09T01:46:47+08:00
reported_at=2026-09-09T01:57:55+08:00
evidence=docs/tasks/evidence/T-20260909-003.json
```

## 结论

本任务只使用 tracked 的 R16–R21 timing handoff、R21 physical evidence/handoff 和
`80b1f813..702bd8ee` source diff 做静态预分析。R21 physical 的真实 `sys_clk_50`
top-50 是 50/50 violated、WNS `-0.588 ns`、550 个 failing endpoints；只有两个
endpoint family：

| shared launch / endpoint | paths | slack | levels |
| --- | ---: | ---: | ---: |
| `core.idex_valid -> soc|core|fp_rsp_hold.gpr_data[]` | 41 | `-0.588..-0.529 ns` | 25–26 |
| `core.idex_valid -> soc|coh|i_l1|rsp_data_r[]` | 9 | `-0.566..-0.531 ns` | 25–26 |

首条报告路径为 `soc|core|idex_valid -> soc|core|fp_rsp_hold.gpr_data[40]`。此前
R21 的 `div_pre -> it_fin_mid`、`it_fin_mid -> pack_result`、FMA 两段和
`pack_mid -> pack_result` 均为正裕量；旧 `ap_pre -> pp_pre` 仍是独立的
50/50、`-0.271 ns` 残余。已闭合/明确 no-path 的旧方向不作为本次新写集。

## 当前 source diff 与任务触碰

当前 source 不是 R21 physical source 的同一树：B25 将时钟从 `sys_clk_50`/divide-by-2
改成 `sys_clk_25`/divide-by-4，并加入 BRAM M20K/MIF、EMIF、FP 兼容和 core/decode
修订。因此 R21 endpoint 只可作 provisional 线索，必须等待 T-20260909-002 fresh STA
确认时钟、层级、endpoint cardinality 和新 top-N。

- T-20260909-001（T-001）只改 BRAM image oracle/test 文件，不直接触碰两组 timing cone。
- T-20260909-002（T-002）无 RTL delta；其 fresh STA 是本任务的唯一激活门。
- T-20260909-004（T-004）是 physical acceptance audit，无 RTL delta。
- T-20260908-002 的 core forwarding/SP capture 与 T-20260908-004 的 decode 依赖修订
  不直接改两个 endpoint，但分别共享 core/idex_valid 或 decode/hazard fanout，故新
  write region 必须避开其具体区域。
- T-20260908-007（T-007）改 QSF/manifest/checker 并启用 `VERILOG_MACRO SYNTHESIS`；
  它不直接改 datapath，但会选择 BRAM 综合分支并改变 fitted hierarchy，不能把 R21
  层级名称视为当前事实。

## 最多三条互斥 provisional write_regions

以下均为 `PROVISIONAL` 规划，不是 candidate，不得在 T-002 返回前实现。公共 typedef、
端口、状态枚举、latency 表和 test entry 保持串行由 integration lane 管理。

1. `B25-R21-A-FP-RSP`：`rtl/lcvex_core.sv` 的 FP-P1 core-facing response/
   `fp_rsp_hold` block（约 1325–1368、1852–1891）与
   `rtl/lcvex_neon_fp.sv` 的 `rsp_comb`/`slot_int_result_r` response assembly。
   目标是 41 条 `fp_rsp_hold.gpr_data[]`。若 fresh path 仍在，候选机制为在现有
   TX_SLOT/TX_DONE 边界增加窄的已寄存 GPR response/metadata，使 hold D 不再依赖
   live `idex_valid/control`，同时保持 tag、GPR/FP flags、kill、ready/valid 和提交
   时序一致。

2. `B25-R21-B-I-L1-RSP`：只改 `rtl/lcvex_l1_i.sv` 的 `S_IDLE` hit/maintenance
   与 `S_REFILL_WAIT`/`S_BYPASS_WAIT` 的 `rsp_data_r` response-data 区域；不改 core、
   coherence wrapper 或公共协议。若 9 条 I-L1 路径仍在，候选机制为把 live `u_req`
   的 hit/index/offset lookup 移到本地 registered request/lookup stage，保持单在途、
   refill、fault、FIFO epoch 和 maintenance 语义；额外 hit latency 必须重验。

3. `B25-R21-C-SHARED-IDEX-FANOUT`：只改 `rtl/lcvex_core.sv` 的
   `fp_tx_candidate/fp_req_valid`（约 1767–1775）及
   `fetch_imem_req_valid/imem_req_valid`（约 2209–2241）两个 request-valid fanout
   区域；不改 response hold、gprv、EX/MEM capture、decode 或公共声明。只有 endpoint
   lane 仍留下共同 launch cost 时，才考虑 endpoint-specific valid qualifier 的复制/
   寄存切分；必须重新证明 token/epoch、FP exactly-once、kill 和 commit 顺序。

三条 lane 的 L0–L2 计划、排除项和精确区域均记录在 evidence JSON；所有状态统一为
`PROVISIONAL`。

## 激活与合并顺序

1. 先由 T-20260909-002 在精确 source `702bd8ee...` 做 fresh STA，确认实际 clock、
   hierarchy、endpoint 和新的 top-N。若 R21 两组路径不存在，全部 lane 保持
   provisional，任务结束且不创建 RTL candidate。
2. 若路径存在，按新 slack/count 重新排序后先处理 FP response lane，再处理 I-L1
   response lane，分别跑受影响 L0–L2。
3. 共享 `idex_valid` fanout lane 最后串行合入；随后只在一个合并 candidate SHA 上
   运行联合受影响 L0–L2 和下一次 fresh physical。这里没有启动 build、GamePC、
   Quartus、JTAG 或板级动作，也没有修改 active task/TASKS/PROJECT_STATUS/ROADMAP。

## 风险

主要风险是 source/clock/hierarchy 已从 R21 改变，R21 的 `sys_clk_50` 数值可能消失；
其次是 FP GPR response 的 exactly-once/flags/kill 边界、I-L1 fetch FIFO/refill/fault
边界，以及共同 launch lane 对两组 endpoint 的交叉影响。不得通过 timing exception、
关闭断言、跳过差分或修改参考结果规避风险。

精确输入、touch matrix、L0–L2 计划、激活门、merge order、policy 和 risk 见
[`T-20260909-003.json`](../tasks/evidence/T-20260909-003.json)。
