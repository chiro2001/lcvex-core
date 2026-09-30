# T-20260909-013：B25 final fresh physical 交接

```text
task=T-20260909-013 state=done
acceptance_status=fresh-synthesis-fitter-sta-and-v2-invariant-physical-signoff-pass
base=d2f5cfdd2791945a82d47300b94debd0e40a96d6 candidate=d2f5cfdd2791945a82d47300b94debd0e40a96d6
candidate_tree=b6b576ada19381d958375d5088d8dc468b99e5d4 owner_evidence=72712675ff588b49a538f4567411abb9e4f76174 initial_integration=c1484c43f762d99b54f58a5d0bc0d357c6f453cb
final_integration=2e7974db34b075f66dc9430de641c470e8b22d7b resolution=T-20260910-001
branch=verify/T-20260909-013-b25-final-fresh-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-013
sent_at=2026-09-09T14:38:51+08:00 received_at=2026-09-09T14:40:29+08:00
reported_at=2026-09-10T00:18:57+08:00 timezone=Asia/Shanghai
remote_probe=D:/Projects/fpga-altra/lcvex/build/T-20260909-013-b25-final-fresh-physical
evidence=docs/tasks/evidence/T-20260909-013.json
correction=T-20260910-002 documentary-only; measured results unchanged
finalized_at=2026-09-10T10:53:13+08:00
```

## 结论

以候选 `d2f5cfdd2791945a82d47300b94debd0e40a96d6` 建立了原先不存在的 GamePC
probe，并按 synthesis → fitter → STA 串行完成。三个 Quartus 阶段均 exit 0；
25 MHz timing、DDR、metastability、六组 FIFO payload 和 20 组 data-delay 均通过。
T-010 固定 waiver 合同最初在 fresh fitted netlist 上 fail-closed：UCP 输入路径为
61（合同 63），reset recovery/removal 为
626/626（合同各 627）。该结果在同一 fitted clone 和只执行 UCP 的第二个全新 clone
上完全复现，不能归因于 report-only 查询污染，也不能使用 T-011 的旧 inventory
冒充 fresh 结果。

T-20260910-001 随后新增独立 v2 invariant policy，保持 v1 字节不变，并从两套 raw
report 重新导出完整规范化成员集合。T-011/T-013 均严格得到 TDI/TMS/TDO
`25/35/4`、reset 624，成员 digest 完全相同；合并 SHA 上 fixture 2/2 正例和
27/27 负例、actual T-011/T-013 exporter+checker 全部通过。因此该差异现已确认只由
fitter `~DUPLICATE` 选择造成，T-013 physical signoff 最终接受。

本交接中的 `candidate` 是被测 RTL/约束候选，`owner_evidence` 是最初写入证据的提交，
`integration` 是主 Agent 接收该证据的提交，三者不得互相替代。原始
`t007_summary.tsv` 内的 `task=T-20260909-007` 与 `fitted_source_sha=702bd8ee...`
属于复用查询脚本携带的 v1 合同 lineage，不是 T-013 测量身份；T-013 身份由
candidate/tree/manifest、user SDC 和 generated EMIF SDC 的哈希联合确定。

## 阶段与时序

- synthesis：`2026-09-09T15:04:50.5598832+08:00` –
  `2026-09-09T21:27:12.4567990+08:00`，exit 0；Quartus synthesis elapsed
  `06:20:46`，最低 free physical `31343.6 MiB`。
- fitter：runner `21:30:13.0409749` – `22:10:15.1341109`，exit 0；Quartus
  fitter elapsed `00:26:01`，最低 free physical `32334.6 MiB`。
- STA：runner `22:11:28.6046174` – `22:31:30.2627513`，exit 0；Quartus
  elapsed `00:00:39`，最低 free physical `41986.4 MiB`。

`sys_clk_25` 为 40 ns/25 MHz，setup/hold/recovery/removal 为
`+8.085/+0.019/+13.608/+0.181 ns`，Fmax `31.33 MHz`。全局最差
setup/hold/recovery/removal/min-pulse 为 `+0.320/+0.000/+0.656/+0.174/+0.120 ns`，
0 violation。DDR 五项为 `0.027/0.063/0.368/1.177/0.220 ns`；metastability
为 4 corners、27 chains、最短 2 registers、0 timing-violation chains、23 excluded、
MTBF `1e+09` years。

聚合文件 `final-acceptance-summary.json` 的 `metastability` 字段为空，这是聚合器漏采，
不是 STA 未执行；本交接的 4 corners/27 chains/0 timing-violation chains 来自权威
`catapult_a10.sta.rpt`（SHA-256 `c164360a...39a67`），没有向聚合文件伪造补值。

Fitter resource 为 ALM `164,852/427,200 (39%)`、register `98,067`、RAM
`121/2,713 (4%)`、DSP `186/1,518 (12%)`、PLL `3/112 (3%)`。boot 为
8192×64、32 M20K，L1/L2 各 16 M20K，fit report 绑定 `../boot/build/boot.mif`。

## T-011 验收结果

- FIFO payload：24 个 setup/hold report 全部 `Nothing to report`；六个精确
  `mem → endpoint` false-path 各为 1 个 Complete、0 个 ignored，未添加 adapter
  宽 wildcard。
- CDC data-delay：四个 corner × 五个 route 共 20 组，cardinality
  `3/3/3/3/1`，全部 0 violation，全部含 2.000 ns Datapath Only marker；最差
  fresh slack `+1.319 ns`。
- UCP：只保留精确的两个 unconstrained clocks：vendor
  `altera_reserved_tck` 与 synchronized reset-control
  `soc|emif_adapter|emif_rst_sync1_n`。fresh raw report 的 TDI/TMS/TDO path
  数为 `25/36/4`，reset recovery/removal `626/626`，均 0 violation，slack
  `1.308/0.220 ns`。exporter 因 exact T-010 counts 不符而拒绝生成 inventory；
  T-010 checker 未对不存在的 fresh inventory 强行运行。

端点差分见 `build/agents/T-20260909-013/prep/ucp-endpoint-diff.json`：

- reset 旧独有的 duplicate 为
  `emif_state_q.EMIF_WAIT_READ~DUPLICATE` 和 `timeout_count_q[8]~DUPLICATE`；
  fresh 新出现 `timeout_count_q[3]~DUPLICATE`，`timeout_count_q[12]~DUPLICATE`
  保持存在。
- TDI 旧独有 `jtag_hub_gen...|irsr_reg[6]~DUPLICATE`；TMS 旧独有
  `hub_mode_reg[0]~DUPLICATE`、`shadow_jsm|state[13]~DUPLICATE`，fresh 新出现
  `shadow_jsm|state[15]~DUPLICATE`。
- 上述 TMS 名称已直接对照两份 raw UCP report：旧为 `state[13]`，fresh 为
  `state[15]`；`ucp-endpoint-diff.json` 与原始报告一致，但仍只作为诊断，原始报告
  才是权威集合来源。
- 去除 `~DUPLICATE` 后 reset 逻辑 endpoint unique count 两边均为 624；fitter
  report 将差异归类为 `Router Logic Cell Insertion and Logic Duplication /
  Routability optimization`。user SDC SHA `7ab96f...eebd5` 和 generated EMIF
  SDC SHA `32bf047...b4274` 相同，因此没有证据支持 RTL/SDC 修复或放宽 checker。

## provenance 与安全边界

候选 manifest 为 53 canonical + 47 alias + 78 platform payload，远端 source closure
174/174；post-sync/source/stage manifest 均保留。report-only 验收在 task-owned
fitted clone 完成，原 fresh fitted source 的 pre/post manifest diff 为 0；clone
query diff 为 22，UCP-only fresh clone query diff 为 14。第一次 UCP-only clone
因 SSH reset 中断，295 文件 partial scene 被移动并保存在
`attempts/ucp-fresh-interrupted-20260910T000159`，没有删除。

synthesis、fitter、STA warning ID multiset 与 T-002 分别为 `235=235`、`12=12`，
完全一致。全程使用 `resource-lock run gamepc`；未运行 assembler、
`quartus_asm`、SOF/POF/JIC/RBF、`quartus_pgm`、`nios2-terminal`、JTAG、板卡
reset/power 或 Flash。没有 RTL、QSF、SDC、checker、参考结果或任务台账改动。

精确命令、时间、资源、report hash、历史 blocker 及其最终解除证据以
[`T-20260909-013.json`](../tasks/evidence/T-20260909-013.json) 为准；下一步应由
独立 T-043/T-044 权限门控制 assembler、SOF 与上板；本任务本身没有执行这些动作。

T-20260910-002 重新核对所有引用 artifact。唯一需修正的既有 size 元数据是
`data_delay_summary.tsv` 的 `5134 → 5320` bytes，其内容 SHA-256
`b8516424...ed3` 原本正确；该更正不改变 20/20 data-delay PASS 结论。
