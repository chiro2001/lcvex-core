# T-20260909-006：B25 CDC exception precedence audit

## 元数据

```text
task=T-20260909-006
label=B25-CDC-EXCEPTION-PRECEDENCE-AUDIT
state=done-read-only-audit
acceptance_status=non-conflicting-datapath-candidate-proven; physical-signoff-blocked
base_sha=2a10d23740e67850cdae7e91fd834c53c7746cac
physical_source_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
branch=verify/T-20260909-006-b25-cdc-exception-precedence-audit
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-006
remote_host=192.168.101.5 (GAMEPC)
fitted_probe=D:\Projects\fpga-altra\lcvex\build\T-20260909-002-b25-physical
project_dir=D:\Projects\fpga-altra\lcvex\build\T-20260909-002-b25-physical\fpga\catapult_a10\quartus
quartus=Quartus Prime Pro 21.4.0 Build 67
device=10AX115N4F40E3SG
```

## 结论

Quartus 21.4 在实际加载的 final fitted database 中支持以下无冲突表达：

```text
set_false_path -from <source> -to <target>
set_data_delay -from <source> -to <target> 2.000
```

`set_data_delay` 的 loaded-DB `-long_help` 明确说明它是 maximum datapath delay，默认不
包含 launch/latch clock arrival，并且独立于 `set_false_path`、不能被其它 SDC 覆盖。将
原来的 full `set_false_path` 保留，再把五条 `set_max_delay 2.000` 换成对应的
`set_data_delay 2.000`（候选 G1）后，四组 Gray 指针和 T-045 poison 都有独立的
`report_timing -setup -data_delay` 路径，所有 data-delay slack 非负且无 violation。

候选 B 的 `set_false_path -hold` + 普通 `set_max_delay 2.000` 也能使五个 max-delay
exception 显示 `Complete`、不出现在 `-ignored`，但它不是 datapath-only：普通 setup
检查仍包含跨时钟 skew，request_wr 和 response_rd 的 setup 分别为 `-10.276 ns`、
`-10.166 ns`。`-datapath_only` 和 `-setup` 均被 Quartus 21.4 拒绝。故 G1 是本审计
建议的 future SDC 方案；B 只作为语法/precedence 对照，不可直接宣称 timing closure。

未修改 RTL、正式 SDC/QSF、测试、任务台账或状态文档；未运行 compile、fit、asm、SOF、
JTAG、板级动作。所有远端同步、STA、报告回读和 postflight 都通过
`/home/chiro/projects/.resource-locks/resource-lock run gamepc`，每次最多一个
`quartus_sta`。

## Quartus 21.4 help 与语法证据

在加载 `catapult_a10` final snapshot 后执行 `set_false_path -help/-long_help` 和
`set_max_delay -help/-long_help`，结果如下：

- `set_false_path` 明确有 `-hold` 和 `-setup`；help 进一步说明 `-hold` 只作用于
  hold/removal，`-setup` 只作用于 setup/recovery。
- `set_max_delay` 的完整选项只有 `-fall_from/-fall_to/-from/-rise_from/-rise_to/
  -through/-to <value>`，没有 `-datapath_only` 或 `-setup`。
- 候选 A 的 `set_max_delay -datapath_only ... 2.000` 在 `read_sdc` 时得到
  `Unknown option: -datapath_only`；候选 F 的 `set_max_delay -setup ... 2.000` 得到
  `Unknown option: -setup`。两次均为 loaded final DB 的 Quartus STA，exit=3。
- `set_data_delay -long_help` 说明：`Specifies a maximum datapath delay exception`；
  默认不含时钟到达时间；约束独立于 `set_false_path`/`set_clock_groups`，不能被其它
  SDC 覆盖，可用于被 `set_false_path` cut 的路径。
- `report_timing -help` 明确提供 `-data_delay`，并说明只报告由 data-delay assignment
  覆盖的路径。`set_max_skew` 存在但针对 clock skew；`set_bus_skew` 不存在，故没有把
  它们误当作这五条 register datapath 的替代方案。

help/loaded-DB 主报告：

```text
build/agents/T-20260909-006/runtime/remote/t006_help_loaded_extended2.stdout.log
sha256=24a9f81d02fa18e1420fec46b108ce291a663f237c9a2d199fc877b487147bef
```

## source/target cardinality

所有候选在 final snapshot 中均用 `get_collection_size` 计数，未使用 opaque collection
的 `llength` 作为证明：

| pair | source pattern | target pattern | source | target |
| --- | --- | --- | ---: | ---: |
| request_wr | `*request_fifo\|wr_ptr_gray_q*` | `*request_fifo\|wr_ptr_gray_rd1_q*` | 3 | 3 |
| request_rd | `*request_fifo\|rd_ptr_gray_q*` | `*request_fifo\|rd_ptr_gray_wr1_q*` | 3 | 3 |
| response_rd | `*response_fifo\|rd_ptr_gray_q*` | `*response_fifo\|rd_ptr_gray_wr1_q*` | 3 | 3 |
| response_wr | `*response_fifo\|wr_ptr_gray_q*` | `*response_fifo\|wr_ptr_gray_rd1_q*` | 3 | 3 |
| T-045 poison | `*emif_adapter\|emif_poisoned_q*` | `*emif_adapter\|emif_poisoned_cpu_meta_q*` | 1 | 1 |

3-bit count 与 RTL 的 `PTR_WIDTH=ADDR_WIDTH+1=3` 一致；poison 是单 bit 两级同步链。

## 候选结果（3_slow_900mv_0c）

所有路径均来自同一 fitted final snapshot；`report_timing` 每 pair 使用 `-npaths 20`，
因此覆盖了每个 3-bit collection 的全部 3 条 bit path及 poison 的 1 条 path。

| candidate | SDC 顺序/选项 | read_sdc / exceptions | normal setup | normal hold | datapath-only setup |
| --- | --- | --- | --- | --- | --- |
| baseline | clocks only | no exceptions | request_wr `3/-11.026`、request_rd `3/+9.289`、response_rd `3/-10.916`、response_wr `3/+9.565`、poison `1/+9.195` | wr/rd=`3/+9.208`/`3/-11.108`、response rd/wr=`3/+9.110`/`3/-11.567`、poison=`1/-10.967` | none |
| A_hold_datapath | `-hold` false + `set_max_delay -datapath_only` | rc=1；unknown option；Quartus exit=3 | not applicable | not applicable | rejected |
| B_hold_setup | `set_false_path -hold` then ordinary `set_max_delay` | 5 false `Complete`；5 max `Complete`；ignored=0 | request_wr `3/-10.276` (3 violated)、request_rd `3/+10.039`、response_rd `3/-10.166` (3 violated)、response_wr `3/+10.315`、poison `1/+9.945` | all five `No hold paths` | ordinary max, not datapath-only |
| C_full_false_max | full false then ordinary `set_max_delay` | 5 false `Complete`；5 max `Fully overridden`；ignored=5 | all `No setup paths` | all `No hold paths` | bound lost |
| D_hold_only | `set_false_path -hold` only | 5 false `Complete`；max rows=0；ignored=0 | same as baseline | all `No hold paths` | bound absent |
| E_max_first | ordinary max then `set_false_path -hold` | same as B；all 10 `Complete`；ignored=0 | same as B | all `No hold paths` | ordinary max; order invariant |
| F_setup_flag | `set_max_delay -setup` syntax probe | rc=1；unknown option；Quartus exit=3 | rejected | rejected | rejected |
| G1_full_false_data | full false then `set_data_delay 2.000` | 5 false `Complete`；`report_exceptions -ignored` no entries；data-delay independently reported | all `No setup paths` | all `No hold paths` | all pass, see below |
| G2_hold_data | `set_false_path -hold` + `set_data_delay 2.000` | 5 false `Complete`；ignored=0；data-delay independently reported | same as baseline | all `No hold paths` | all pass, see below |

报告中的 normal max-delay slack 是普通 clocked setup slack，不应与 pure data slack 混淆。
例如 B 的 request_wr 报告同时显示 `Max Delay Exception ; 2.000`、clock skew `-11.221`
和 slack `-10.276`；G1 的 datapath 报告显示 `Max Delay Exception (Datapath Only) ;
2.000`、clock skew `0.000`。

## G1 推荐方案的 actual datapath 状态

G1 的 `report_timing -setup -data_delay` 均 `Found N setup paths (0 violated)`，且每条
报告都有 `Max Delay Exception (Datapath Only) ; 2.000`：

| pair | paths | worst data slack (ns) | worst data delay (ns) | normal setup/hold |
| --- | ---: | ---: | ---: | --- |
| request_wr Gray | 3 | +1.145 | 1.046 | setup/hold 均无 normal path（full false） |
| request_rd Gray | 3 | +1.158 | 1.036 | setup/hold 均无 normal path（full false） |
| response_rd Gray | 3 | +1.365 | 0.880 | setup/hold 均无 normal path（full false） |
| response_wr Gray | 3 | +1.327 | 0.874 | setup/hold 均无 normal path（full false） |
| T-045 poison | 1 | +0.984 | 1.209 | setup/hold 均无 normal path（full false） |

G1/G2 的 data-delay report 是独立 proof；`report_exceptions` 本身只列出 SDC timing
exceptions，不列出 `set_data_delay`，因此不能只看 exceptions summary 判断 data-delay
是否应用。

关键报告及 SHA：

```text
G1_full_false_data_exceptions.rpt  7dc90dc827eb4cb7f3adbb5198974ceef0308f6e8c90fb5addaaf7695828948e
G1_full_false_data_ignored.rpt     805d64c7c067e161b1b48df7ac4b33c879355d036cbe4c2335d3cda4ef4db7f3
G1_full_false_data_0_request_wr_data_delay.rpt  e862acfc3d40762cd9b6800bf450b57437072642f1b41c00b4ea3390109ccb96
G1_full_false_data_1_request_rd_data_delay.rpt  004f5b97f5206c41c04332f67fd772e9ed7c29fafd550c51639c169f8da8ed2a
G1_full_false_data_2_response_rd_data_delay.rpt 362f2c91b5a4a6a976167361f492d21c33bb5349cee10415e7a54bc0c83cd87f
G1_full_false_data_3_response_wr_data_delay.rpt 593a7c5018adcec21cf47bc1d6358d6eb7559051935df99a332a0ee65d022ced
G1_full_false_data_4_poison_data_delay.rpt     af1a5944407c7a0027701fd8db8c0d5ddfcf874f5a4b81a11683158b7f3e8cae
```

## Gray coherence 与 poison 判定

### 四组 Gray pointer

每组是 3-bit source 与 3-bit first-stage synchronizer 的跨域采样。Gray 编码只保证每
次计数变化一 bit；要把同一编码的 bit-to-bit routing skew 限在 2 ns 内，必须保留
2 ns datapath bound。G1 的 12 条 Gray bit paths 全部 resolve，data delay 最大值分别
为 1.046/1.036/0.880/0.874 ns，slack 均为正。因此 **2 ns 不得删除**。

### T-045 single-bit poison

`emif_poisoned_q -> emif_poisoned_cpu_meta_q` 是单 bit；multi-bit coherence 本身不适用，
两级 `ASYNC_REG` 是主要 metastability 机制。但当前 T-045 contract 明确要求该 pair
保留 `2.000 ns` bound，且 poison 控制 late-response drain/epoch re-arm，不能因为它是
single-bit 就静默丢掉 bound。G1 实测该独立 data-delay path 为 1.209 ns、slack
`+0.984 ns`。在另行批准 contract/SDC 变更并有新的 reset/timeout 证据前，**仍保留
2 ns**；本任务不建议移除。

## 建议的 future SDC exact regions（本任务未写入正式 SDC）

下面只给出 sections 2/3/4c 的未来替换文本；现有 `if` guard 可保留，但集成验证必须
用 `get_collection_size` fail-closed 检查 source/target。推荐采用 G1，不使用
`-datapath_only`/`-setup`（两者对 `set_max_delay` 在 Quartus 21.4 都非法）。

### Section 2：四组 Gray source -> first synchronizer

保留现有四条 full false path（示例）：

```tcl
set_false_path -from [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*request_fifo|wr_ptr_gray_rd1_q*}]
set_false_path -from [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*request_fifo|rd_ptr_gray_wr1_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*response_fifo|rd_ptr_gray_wr1_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*response_fifo|wr_ptr_gray_rd1_q*}]
```

### Section 3：四组 Gray 2 ns datapath bound

把现有四条 `set_max_delay ... 2.000` 原位替换为：

```tcl
set_data_delay -from [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*request_fifo|wr_ptr_gray_rd1_q*}] 2.000
set_data_delay -from [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*request_fifo|rd_ptr_gray_wr1_q*}] 2.000
set_data_delay -from [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*response_fifo|rd_ptr_gray_wr1_q*}] 2.000
set_data_delay -from [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}] \
               -to   [get_registers -nowarn {*response_fifo|wr_ptr_gray_rd1_q*}] 2.000
```

### Section 4c：T-045 poison

保留 reset/CPU-reset 两组现有 full false path；把 poison pair 改成：

```tcl
set_false_path -from [get_registers -nowarn {*emif_adapter|emif_poisoned_q*}] \
               -to   [get_registers -nowarn {*emif_adapter|emif_poisoned_cpu_meta_q*}]
set_data_delay -from [get_registers -nowarn {*emif_adapter|emif_poisoned_q*}] \
               -to   [get_registers -nowarn {*emif_adapter|emif_poisoned_cpu_meta_q*}] 2.000
```

如果集成者因其它设计原因选择 hold-only fallback，唯一已证明可读入的形式是
`set_false_path -hold ...` 后接普通 `set_max_delay ... 2.000`；这会保留 bound 但把
clock skew 带入 setup，不能替代 G1 的 datapath-only proof。

## Future verification Tcl 与 fail-closed 标准

可重放脚本（本任务未在四角执行，避免把正式 SDC 改动与本次审计混合）：

```text
build/agents/T-20260909-006/prep/t006_future_verify.tcl
sha256=1047fcb5d44c4c5d0d8a0928f05b5cdf0cf87f5a9b107c3f40e1e8faac400330
```

它会在同一 final fitted project 中逐一加载
`3_slow_900mv_0c`、`3_slow_900mv_100c`、`MIN_fast_900mv_0c`、
`MIN_fast_900mv_100c`，对每个 pair：

1. 用 `get_collection_size` 要求 source/target 均非零且相等（预期 Gray=3/3、poison=1/1）。
2. 要求 `report_exceptions` 中恰有 5 个 `Complete` false paths；default 和
   `-ignored` 报告不得出现 `Fully overridden`、ignored 或 unresolved。
3. 写出 normal setup/hold 报告；full-false 推荐方案下二者为 no path 是预期，但必须
   同时有独立 data-delay 报告，不能把 no path 当 pass。
4. 用 `report_timing -setup -data_delay` 要求 path count 等于 source count、`0 violated`、
   worst slack ≥ 0，且报告含 `Max Delay Exception (Datapath Only) ; 2.000`。
5. 任一 corner 缺失、count=0/mismatch、normal/data report 缺失、SDC read error、
   ignored/override、negative data slack 或 marker 缺失均 fail-closed。

普通 B fallback 的验收另须要求 setup path 全量可见且无负 slack；不能只看 max exception
`Complete`。

## fitted DB/output_files provenance 与限制

远端 preflight（UTC `2026-09-09T02:41:20.9033211Z`）确认 final project、QDB 227 files、
output_files 存在、EDA=0；最终 postflight（UTC `2026-09-09T04:17:18.0526632Z`）确认：

```text
output_files file_count=13
output_files_manifest_sha256=26251a54458cb5283161ac296b7ee87827c24aa9bf68e55f7e92f9b85f18d7c7
QPF=38ac01ac2dfc0dbf28fc5bb2be22e2323606c18716b46ec6c5d048e5fe4ec1dd
QSF=1deb0042c54485e04a72bea71846718d3011ffb2ae7803d19f5a3485bc5bfa46
SDC=b16247b74c6b07c7d0c4a0a50d4787072299b8b73e0caccce5fb273307ac078f
EDA_COUNT=0
FORBIDDEN_ARTIFACT_COUNT=0
```

`output_files` 的 13-file manifest 与 T-002 frozen report hashes 一致；该部分可判定为
unchanged。QDB 最终 manifest 为 227 files、SHA=`c64214e79a373e0bc81facf7dc085576b28e31f83c19d2d46fbc7cd42a4ba73b`，但初始只记录了
文件数（首次目录 listing 的 mtime 约为 `2026-09-09T02:04:32Z`），最终观察到目录 mtime
为 `2026-09-09T04:19:55.8927244Z`。QDB 在同一远端 fitted probe 被多个 sibling
report-only task 共享期间推进，且本任务
没有在任何 Quartus query 前保存 pristine 的 227-file content/mtime manifest。因此不能
把 QDB unchanged 作为已证明事实；严格 provenance 状态为 **indeterminate**，不是静默
宣称 untouched。没有执行恢复/删除/覆盖动作，也没有修改 `output_files`。

postflight artifacts：

```text
build/agents/T-20260909-006/runtime/remote/t006_postflight_final.stdout.log
sha256=b4483af25b9d3fe5b2cb699dc81101fe757c7cdd7af9bb081efeaa8eec146482
build/agents/T-20260909-006/runtime/remote/t006_postflight_qdb_sha256.txt
sha256=c64214e79a373e0bc81facf7dc085576b28e31f83c19d2d46fbc7cd42a4ba73b
build/agents/T-20260909-006/runtime/remote/t006_postflight_output_files_sha256.txt
sha256=26251a54458cb5283161ac296b7ee87827c24aa9bf68e55f7e92f9b85f18d7c7
```

若下一轮要求绝对证明 fitted DB 未被 query touched，应先在独立 fresh read-only clone 或
文件系统 snapshot 上保存 QDB 全量 manifest，再运行上述 future verifier；不得在共享
fitted probe 上把 report-only query 的目录 mtime 当作 unchanged 证据。

## 证据路径

完整报告和原始 lock capture 均保留在：

```text
build/agents/T-20260909-006/runtime/remote/
build/agents/T-20260909-006/runtime/local/
build/agents/T-20260909-006/prep/
```

本交接只写 audit evidence/handoff；正式 `catapult_a10.sdc` 未修改，后续应由独立 SDC
任务评审并从新的 candidate SHA 重跑四角 TimeQuest、CDC、recovery/removal 与 Gate D。
