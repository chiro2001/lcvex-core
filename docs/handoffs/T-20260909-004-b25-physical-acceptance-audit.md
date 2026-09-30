# T-20260909-004：B25 physical acceptance audit 交接

```text
task=T-20260909-004 state=done acceptance_status=matrix-ready-read-only
base_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
candidate_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
branch=verify/T-20260909-004-b25-physical-acceptance-audit
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-004
original_sent_at=2026-09-09T01:21:51+08:00
restart_recovery_received_at=2026-09-09T01:46:47+08:00
reported_at=2026-09-09T02:13:07+08:00
remote_probe_contract=D:/Projects/fpga-altra/lcvex/build/T-20260909-002-b25-physical
quartus=Quartus Prime Pro 21.4.0 Build 67
device=10AX115N4F40E3SG
evidence=docs/tasks/evidence/T-20260909-004.json
```

## 结论

本任务交付一份独立、可直接套用到 T-20260909-002 返回物理证据的
fail-closed acceptance matrix。T-004 仅在指定 worktree 读取 candidate 与 tracked
T-20260908-005/006/007、T-20260909-001 evidence；没有运行 build、Quartus、GamePC、
远端、JTAG、assembler 或板级动作，也没有读取 T-002 worktree/probe。

矩阵包含 14 个 claim rows，逐项给出 exact command、Quartus report/query、所需
artifact、通过条件和 fail-closed 条件。完整机器可读版本见
[docs/tasks/evidence/T-20260909-004.json](../tasks/evidence/T-20260909-004.json)。

## 输入基线与不可继承项

candidate 的完整 source head 是
`702bd8ee5295efe8a2ad9e094d6c12471a1d3089`。当前 QSF/SDC/QPF 的 target hash 分别为：

- QPF `38ac01ac2dfc0dbf28fc5bb2be22e2323606c18716b46ec6c5d048e5fe4ec1dd`
- QSF `3e0ef899e341f92d1fb6468bb34be55e07f5d5591f875b864954cd559171c5fe`
- SDC `b16247b74c6b07c7d0c4a0a50d4787072299b8b73e0caccce5fb273307ac078f`

物理 candidate 必须重新绑定 47 个 root RTL、2 个 platform RTL、3 个 project
file、1 个 generated MIF（canonical=53），以及 QSF 相对路径所需的 47 个逐字节
`fpga/rtl/*.sv` alias；平台 payload 仍须为 75 项，QSF file references 为 49
项，missing/extra/hash_bad 全为 0。clean checkout 中不存在这些 candidate-only alias，
不能把其缺失误报为 tracked source 缺陷，也不能在物理同步时跳过它们。

四份历史 evidence 的边界如下：

- T-005 Gate D 全绿只证明功能回归，不证明物理时序、资源、M20K/MIF、DDR 或板测。
- T-006 的 Quartus synthesis 因 Error 19544/16186 停止；其 syn report 中的
  User-Specified Memory Initialization File 仅是 MIF recognition，不是 M20K
  consumption。
- T-007 证明 exact sole `VERILOG_MACRO SYNTHESIS`、行为分支 guard 和静态
  selector/platform closure，但未运行 Quartus。
- T-001 证明 ELF-derived oracle 与 13/13 negative contract；不证明 Quartus
  M20K initialization。

## 应用顺序

1. preflight 先核对 candidate SHA、clean 状态、platform/skeleton/SHA/selector
   checker、53+47 source/alias closure，并重新生成 boot ELF/BIN/HEX/MIF 与独立
   expected image。
2. 仅在 source/MIF closure 通过后，在 fresh probe 串行运行：
   `quartus_sh --flow compile catapult_a10 -c catapult_a10 -start ipgenerate -end synthesis`，
   再运行 fitter、signoff STA；任何阶段失败即停止，不 retry、bypass 或复用旧
   database。
3. synthesis 成功只能宣称无 error、分支/elaboration 证据和 MIF recognition；
   M20K allocation/MIF consumption、post-fit clock、timing、DDR、metastability
   和资源必须等待 fitter/STA 的对应 report/query。
4. fitter 成功后仍须由 final database 运行
   `quartus_sta -t report_clocks.tcl`、`report_timing.tcl`、
   `report_t045_sdc_filters.tcl`、`report_emif.tcl` 及 MIF/resource query。
   TimeQuest opaque collection 计数必须用 `get_collection_size`，不能用
   `llength` 作为 T-045 resolve 证据。
5. setup、hold、recovery、removal、minimum-pulse 的 WNS 均须 ≥0、TNS=0、
   failing endpoints=0；DDR 五项（Read Capture、Write、Address/Command、
   DQS Gating、Write Levelling）须 Pass；Metastability 需实际 chain/corner
   summary；任何缺失或 ignored filter 均保持 blocked。
6. 最终只做 non-destructive postflight。T-002 明确不运行 assembler/bitstream、
   `quartus_pgm`、JTAG、board reset/power 或 Flash write；禁止扩展名
   `.sof/.jic/.rbf/.pof/.jbc/.svf/.jam` 的 artifact count 必须为 0。

## 关键硬门

| claim | 权威 evidence | 通过条件 |
| --- | --- | --- |
| source/MIF/alias provenance | candidate/platform manifests、source verifier、SHA256SUMS | 53 canonical + 47 alias、75 payload、49 QSF refs，hash/bytes/file-set 全零差异 |
| sole selector/行为排除 | selector checker + syn rpt/summary/smsg | 唯一 active SYNTHESIS；BRAM altsyncram/cache M20K 出现在 Quartus 结果；behavior/standalone duplicate 不出现 |
| MIF/M20K consumption | syn input table + fit RAM summary + `report_mif_consumption.tcl` | fresh MIF hash 同一；boot RAM post-fit init association 与 M20K allocation 均有对象级证据 |
| clock topology | final `report_clocks` + `report_clocks.tcl` | clk_u59=10.000 ns、sys_clk_25=40.000 ns（divide 4）、clk_y3=3.750 ns；Qsys 100/266 与 EMIF user sink 实连 |
| timing | `catapult_a10.sta.summary/.sta.rpt` + raw top-N | setup/hold/recovery/removal/min-pulse 全部非负且零 violation |
| T-045 filters | `report_t045_sdc_filters.tcl` + applied/ignored exception report | 三个 target/source collection 均 resolve，applied>0，ignored/unresolved=0，poison max-delay 2 ns 生效 |
| DDR/metastability | final STA DDR/Metastability Summary + EMIF reports | DDR Summary=Pass、五项 margin 非负；chain/corner/violation rows 完整且通过 |
| resources | `catapult_a10.fit.rpt/.fit.summary` + resource parser | fitter success，所有 used≤capacity，boot/cache M20K 与层次对象一致 |
| forbidden actions | final guard、artifact scan、command audit | EDA=0、禁止产物=0、assembler/JTAG/board/Flash 未运行 |

T-002 若停在 synthesis failure，必须保存首个 error 和 fresh probe；fitter、STA、
clock、M20K actual consumption、T-045、DDR/metastability、resource 及后续所有
claim 均为 unavailable。STA 工具 exit=0 但 Timing Closure fail 时只能报告实际
数值，不能称 timing closure 或 release-ready。

## 交付与策略

- evidence：`docs/tasks/evidence/T-20260909-004.json`
- handoff：`docs/handoffs/T-20260909-004-b25-physical-acceptance-audit.md`
- T-004 写集只有上述两个文件；未修改 active task、TASKS、PROJECT_STATUS、ROADMAP、
  RTL、QSF、SDC、test、QEMU 或其他 worktree。
- 该矩阵本身通过 JSON 解析和 `git diff --check`；当前 physical acceptance
  结论为 `NOT_SIGNED_OFF_BY_T-004`，仅表示 acceptance matrix 已就绪。
