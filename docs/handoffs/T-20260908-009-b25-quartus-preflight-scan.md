# T-20260908-009：B25 Quartus 21.4 preflight scan 交接

```text
task=T-20260908-009
state=done
base=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
head=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
branch=verify/T-20260908-009-b25-quartus-preflight-scan
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-009
sent_at=2026-09-08T23:26:27+08:00
received_at=2026-09-08T23:26:27+08:00
reported_at=2026-09-08T23:45:13+08:00
files=docs/tasks/evidence/T-20260908-009.json,docs/handoffs/T-20260908-009-b25-quartus-preflight-scan.md,build/agents/T-20260908-009/**（ignored）
tests=QSF reachable scan + conditional/macro/always_ff/module/vendor static classification
resource=read-only/light；未取得 local/gamepc；未连接 Quartus/JTAG/板卡
evidence=docs/tasks/evidence/T-20260908-009.json
```

## 更正记录

原始扫描为核对一行候选宏时曾只读访问
`/home/chiro/projects/mycpu/lcvex-wt-T-20260908-007/fpga/catapult_a10/quartus/catapult_a10.qsf`，这超出 T-009 的 worktree 边界；没有写入、构建或远端动作。修订后的 selector 结论不把该未提交文件当作验收输入，而是基于本 worktree baseline QSF 在内存中插入一行
`set_global_assignment -name VERILOG_MACRO SYNTHESIS` 的 hypothetical overlay，
再与只读参考工程 QSF 对照。精确路径、命令、hash 和时间见 evidence 的
`scope_deviation`/`correction_record`。

## 结论

扫描基于 `catapult_a10.qsf` 的 50 个直接 assignment，解析出 42 个现存 SV/V
文件和 5 个 QIP 递归依赖。仓库布局中的 28 个 `../../rtl` 路径需要 physical
同步时建立 `fpga/rtl` byte-identical alias；`boot.mif` 是由 T-006 生成的单独
physical 输入，不能因本地扫描 worktree 没有它而误判源 RTL 缺失。

T-006 的 Error 19544 位于 `rtl/lcvex_bram_boot.sv:165`，其所在
`lcvex_bram_boot_behav` 块为 `ifndef SYNTHESIS`。定义 `SYNTHESIS` 后，94–206
行和行为模块不可见，214–367 行的 `lcvex_bram_boot_altsyncram` 及其
`altera_syncram` 可见；`lcvex_cache_data_ram.sv:40–100` 同样选择显式
`altera_syncram`。baseline QSF 的 hypothetical 第 15 行与参考工程 QSF 第 12 行完全同形；这不是 T-007 未验收 worktree 的合入或 Quartus 通过证明。
这证明该错误在宏选择后结构上不可达，但不构成 Quartus PASS。

扫描得到：0 个 input declaration initializer、149 个合法 parameter default、
49 个异步 `always_ff` 中 0 个在 `SYNTHESIS` 活跃路径上的条件顺序错配、0 个活跃
重复 module。唯一错配正是被宏排除的 BRAM behavior block。

## 分级发现

当前没有足够证据在宏选择之后再指定一个“确定的下一个 elaboration blocker”。
以下项目必须保留在下一次 fresh physical report 的观察清单中：

- `rtl/lcvex_decode.sv:1806`：Warning 16788，逻辑立即数函数 output argument
  `imm` 的 Quartus dataflow warning；最小潜在写区是 logical-immediate block
  `1802–1828`，本任务不修改。
- `rtl/lcvex_core.sv` 的 Warning 16746/16749（隐式/提前使用声明）以及
  `rtl/lcvex_axi4_avalon_adapter.sv:322`；若处理，只做声明顺序最小改动。
- `rtl/lcvex_decode.sv:3158` 的 19651/16750（`dup_size` latch/non-comb）;
  需先有宏启用后的复现，不能仅凭 warning 改语义。
- reset gate、25 MHz divider、adapter CDC retention bits 的 10 个 synthesis-visible
  logic initializer：是有意的 FPGA power-up 设计，尚未被 T-006 判为语法 blocker，
  但需要 post-fit/配置观察。
- `fpga/catapult_a10/flash/sfl/sfl_sys.qip:12` 引用缺失的
  `../sfl_sys.qsys`：T-006 IP generation 已通过，暂列 provenance high-risk，
  由平台 owner 决定最小闭合方式。
- Warning 13469 的固定宽度截断（L1 refill、adapter mask、Qsys 生成代码）保留
  做 physical review，不升级为 blocker。

完整 file list、条件可见性、哈希和分级 JSON 见 evidence；扫描脚本及所有输出均在
`build/agents/T-20260908-009/`，没有修改 source/QSF/manifest/test 或任何 active
task/status 文档。

## 下一步

等待 T-007 synthesis-selector 和 T-008 macro review 串行集成。若接受一行
`VERILOG_MACRO SYNTHESIS`，只对新的精确候选做一次 fresh Quartus synthesis，
重新分类上述高风险项；synthesis 通过后才可进入 fitter/STA。不得以本扫描代替
Quartus、时序、SOF、JTAG 或板测结论。
