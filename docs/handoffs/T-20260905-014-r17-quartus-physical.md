# T-20260905-014：R17 A10 physical validation handoff

```text
task=T-20260905-014
state=accepted-for-timing-observation-setup-and-directional-open
source_sha=738cc142c0dae5269dffe9b8020094cb77ec8094
physical_rtl_parent_sha=0166ede4abab06aff35c06159acdde7570cafa6e
branch=verify/T-20260905-014-r17-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-014
probe=D:\Projects\fpga-altra\lcvex\build\T-20260905-014-r17-fp-acc-control-probe\real_a10_full_fp
quartus=Quartus Prime Pro 21.4.0 Build 67
device=10AX115N4F40E3SG
```

## 结论

T-014 在全新隔离 probe 上完成了受保护的 synthesis、fitter、signoff STA、custom
STA、方向性查询、报告下载、strict top-50 parser 和最终 postflight。物理结果必须
如实解释为：`sys_clk_50` setup 仍未收敛，但 hold/recovery/removal/min-pulse、DDR
和 metastability 摘要通过；这不是 Gate F-BOARD，也不授权 assembler、SOF、JTAG 或
板级测试。

全流程没有运行 assembler/bitstream、`quartus_pgm`、JTAG/Flash 写入、上电或板测；
最终 guard 确认 EDA=0、禁止扩展名产物=0，`jtagserver` PID 5476 只观察未触碰。

## 输入与可复现性

- formal/platform RTL 与 project payload 绑定 source `738cc142`；相对 physical
  parent `0166ede` 的 `rtl`/`fpga` diff 为空。
- payload 为 47 个 formal RTL、2 个 platform RTL、QPF/QSF/SDC，共 **52 项**。
  最后一次远端 manifest：52/52，missing=0、extra=0、bad=0。
- canonical QSF 外部依赖 closure：**19/19**，missing=0；实测记录见
  `build/agents/T-20260905-014/runtime/preflight/canonical_ip_closure.txt`。
- Quartus 兼容副本从 `738cc142:rtl/lcvex_fp_scalar.sv` 重新生成，只移除四个
  默认端口值（`iter_kill`、`iter_pause`、`divider.kill`、`divider.pause`），不复用
  T-008 patched blob。
- generator 已改为内置 strict parser、custom STA 进程树 monitor、custom-only
  control-script sync、正确的 output_files 下载路径和 21.4 collection API 适配。
  `prepare.py` 两次重生成的 141 项 hash chain 一致，排除了
  `__pycache__/*.pyc` 和 runtime 历史日志。

## 阶段结果

| 阶段 | 时间/墙钟 | 结果 | 峰值私有内存 |
| --- | ---: | --- | ---: |
| synthesis (`ipgenerate→synthesis`) | 13765.209 s | exit 0，safety=false，timeout=false，postguard PASS | 11788.7 MB |
| fitter | 1852.397 s | exit 0，safety=false，timeout=false，postguard PASS | 12608.3 MB |
| signoff STA | 42.766 s | exit 0，safety=false，timeout=false，postguard PASS | 6494.8 MB |
| custom STA 四个 Tcl | 约 129 s | 四个脚本 exit 0，postguard PASS | 各脚本受 monitor 保护 |

所有 synthesis/fitter/STA/custom 脚本均使用 `MaxRunSeconds=43200`、
`MinFreeMb=16384` 的进程树监控；每阶段仅运行一个 Quartus 进程。

## STA 数值

`real_a10_full_fp.sta.summary` / `.sta.rpt` 是数值权威来源：

```text
sys_clk_50 Fmax                 43.00 MHz
sys_clk_50 setup slack          -3.256 ns
sys_clk_50 setup TNS            -21736.217 ns
sys_clk_50 failing endpoints     18309
sys_clk_50 hold slack             0.016 ns
sys_clk_50 recovery slack         1.396 ns
sys_clk_50 removal slack          0.194 ns
sys_clk_50 minimum pulse slack    9.396 ns
```

相对 T-008 基线（Fmax 40.33 MHz、setup -4.797 ns、TNS -34241.243 ns、20559
failing endpoints），本轮测得 Fmax +2.67 MHz（+6.62%）、setup +1.541 ns、TNS
改善 12505.026 ns、failing endpoints 减少 2250；仍应标记为 setup negative，不能
称为 timing closure。

## 方向性与 EMIF 结果

directional Tcl 使用 indexed/`~DUPLICATE` wildcard，所有 endpoint collection 均
先做真实 cardinality 检查；`acc*` 与 `acc_flags*` 通过 `remove_from_collection`
分离：`acc_all=134`、`acc_flags=6`、`acc=128`。

```text
old pp_pre -> pack_mid             paths=0
pp_pre -> pack_pre                 paths=50
pack_pre -> pack_mid               paths=50
pack_mid -> slot_result            paths=50
slot_result -> acc                 paths=50
exmem_valid -> acc / acc_flags     paths=50 / 50
memwb_wb_rd -> acc / acc_flags     paths=50 / 50
exmem_wb_rd -> acc / acc_flags     paths=50 / 50
```

因此只有旧 pp_pre→pack_mid 目标满足真实 0-path；六组 core-control→acc/acc_flags
并未满足原 directional zero-path 预期，其中 exmem_valid→acc/acc_flags 与
exmem_wb_rd→acc 仍有负 slack。它们虽然已离开全局 top-50，但必须作为 T-018
继续优化，不能把本轮描述成 accumulator 控制锥完全消失。

Quartus 21.4 实测没有 `sizeof_collection`/`get_object_name`，而
`get_collection_size` 是有效 cardinality API；`llength` 对 opaque collection
只返回 token 宽度，已禁止用于 collection 计数。EMIF clock 名称来自同一 final DB
的 `report_clocks` 实测（不是猜测），24 个 canonical 名称逐项解析为 1 个对象。
查询使用 `-from_clock/-to_clock`，cross 只枚举不同 clock pair：

```text
sys_clk_50=1
emif_user=1
emif wildcard=24
distinct EMIF pairs=552
pairs with paths=6
emif -> sys paths=0
sys -> emif paths=0
```

原先失败的 EMIF 查询（exit 24）已保留在 runtime 日志作为诊断证据；修正 API 和
clock 名称后的四脚本重跑全部 exit 0。

## 下载与 parser 硬门

下载脚本明确取得 58 个报告/日志文件（约 46.2 MB），marker 绑定：

```text
source_sha=738cc142c0dae5269dffe9b8020094cb77ec8094
expected_manifest_sha256=4dac97f2612bf19a7fa560b83fe815a0132a003a6203ba0118e5d5750f10794c
sta_signoff_exit_code=0
custom_sta_exit_code=0
top50_report_sha256=b0213270ddcf0c205b42ec570966bdceb348ab1bb97acc3cf265559cfb022c0e
```

strict parser 通过以下硬检查：

- 报告非空且恰好 50 条 setup path；
- summary rank 与详细 `Path #1..#50` 一一对应；
- 50/50 launch/latch clock 都是 `sys_clk_50`；
- 50/50 都有 `logic_levels` 与 `SDC Exception`；
- marker、source、expected manifest 和报告 SHA 全部一致。

本轮 top-50 的 50 条路径都落在一个真实 cone：
`core.idex_valid -> fp_exec.state.TX_DONE`；因此没有人为要求不存在的第二个
cone，`first_new_cone_after_top10=null` 是合法实测结果。

## 关键证据

- 机器可读 evidence：[`T-20260905-014.json`](../tasks/evidence/T-20260905-014.json)
- synthesis/fitter/STA/custom wrapper 日志：
  `build/agents/T-20260905-014/runtime/stages/`
- 下载报告与 parser：`build/agents/T-20260905-014/runtime/downloaded/`
- 最终 guard：`build/agents/T-20260905-014/runtime/final_postflight_guard.stdout`

## 后续边界

下一步回到 RTL timing batch，以 `sys_clk_50` 的 `idex_valid -> TX_DONE` 主 cone 和
方向性结果重新排序。由于 setup 为负，不能推进 assembler、SOF、JTAG、烧写、上电
或板级测试；任何板级动作仍需用户明确授权。
