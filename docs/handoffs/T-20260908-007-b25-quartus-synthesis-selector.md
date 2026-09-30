# T-20260908-007：B25 Quartus synthesis selector 交接

```text
task=T-20260908-007 state=done-local-hermetic-review-with-bram-blocker-split
base=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
source_head=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
branch=fix/T-20260908-007-b25-quartus-synthesis-selector
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-007
sent_at=2026-09-08T23:26:27+08:00 received_at=2026-09-08T23:26:27+08:00
reported_at=2026-09-09T00:37:30+08:00
files=fpga/catapult_a10/quartus/catapult_a10.qsf,fpga/catapult_a10/platform_manifest.json,fpga/catapult_a10/SHA256SUMS,fpga/catapult_a10/skeleton_manifest.json,fpga/catapult_a10/tools/check_platform.py,fpga/catapult_a10/tools/check_skeleton.py,fpga/catapult_a10/tools/check_synthesis_selector.py,docs/tasks/evidence/T-20260908-007.json,docs/handoffs/T-20260908-007-b25-quartus-synthesis-selector.md,build/agents/T-20260908-007/**（ignored）
tests=selector/preprocess/platform/skeleton/SHA PASS；hermetic default/valid/negative PASS；BRAM boot/cache 2 PASS、bram_init25 stale-expectation FAIL
blockers=bram_init25 test expectation split to T-20260909-001；no Quartus run in this task
evidence=docs/tasks/evidence/T-20260908-007.json
review=T-20260908-008 approved exact SYNTHESIS macro semantics; see docs/tasks/evidence/T-20260908-008.json
```

## 实现结论

T-008 已批准 `SYNTHESIS` 宏的语义边界。本任务在 QSF global assignment 区域加入且仅
加入一条：

```text
set_global_assignment -name VERILOG_MACRO SYNTHESIS
```

并同步更新 QSF target 的 `platform_manifest.json`、`SHA256SUMS`；由于
`check_skeleton.py` 自身属于 skeleton manifest 的 6 项闭包，其新增 required macro
anchor 同步更新了 `skeleton_manifest.json` 中该 checker 的 bytes/SHA。新增的
`check_synthesis_selector.py` 独立核对宏唯一性、参考 QSF 同形、QSF 文件列表、BRAM/
cache 分支、MIF/HEX 路径和 50-file manifest/source.lock target 闭包。

没有修改任何 RTL、QEMU、测试期望或物理约束。当前关键 target hash：

```text
catapult_a10.qsf       3e0ef899e341f92d1fb6468bb34be55e07f5d5591f875b864954cd559171c5fe
platform_manifest.json c87aac08e855fc4ac30ad6ddfa4db19d41644b6ab5f660e80e628063545a5e9d
SHA256SUMS             764d5cf14617ec0a59d5b8ec030a179254594e1555fb8e070130e94670e17bd7
skeleton_manifest.json 35b47fb36402662776ed1e17cda9d2c2bba0c77f2940ae89d38b41ee684acc76
check_platform.py      88812d7a7b2f77f5c4574a7833646b52a1afe504aa6b2452c11c8d6ca9887300
check_skeleton.py      7a5d76f2204b414a51a7da08319fbadc021bcf6649eee9991c32ade06ec9fa1e
check_synthesis_selector.py 03e2159cd7727902384e28213b98bb5ed2c2ba8d10d3de774c638bcad432d305
```

## 条件选择审计

`check_synthesis_selector.py` 与 Verilator `-E/-DSYNTHESIS` 双重核对通过。hermetic
follow-up 已移除 checker 对 `/home/chiro/projects/mycpu/a10-linux-riscv/...` 的硬编码依赖：

- 默认运行完全仓内、从隔离 cwd 执行，reference 不存在也 exit 0；
- `--reference-qsf PATH` 仅在显式提供时读取外部 QSF，并要求 exact single macro；
- 无宏、重复宏、缺失 reference 三个负例分别 exit 1。

精确 positive/negative 命令、stderr/stdout hash 见 evidence。

条件选择审计：

- active `SYNTHESIS` macro 恰好 1 条；无其他或重复 `VERILOG_MACRO`；参考
  `a10-linux-riscv` QSF 同形且恰好 1 条；
- QSF 的 `lcvex_bram_boot.sv` assignment 恰好 1 条，standalone
  `rtl/lcvex_bram_boot_altsyncram.sv` 不在 QSF；main BRAM 的 altsyncram module 恰好
  1 个；
- 未定义 `SYNTHESIS` 时选择 `lcvex_bram_boot_behav`、packed cache model、仿真
  `boot.hex`，并保留 scalar SVA；
- 定义 `SYNTHESIS` 时排除 behavior model/SVA，选择 `lcvex_bram_boot_altsyncram`、
  cache `altera_syncram`/`M20K` 和 `../boot/build/boot.mif`；
- platform manifest/source.lock target closure 50 项、SHA256SUMS 50/50 均通过；
  `check_platform.py` 与 `check_skeleton.py --require-boot-image` 均通过。

精确 JSON 和预处理/ hermetic 输出 hash 见
[`T-20260908-007.json`](../tasks/evidence/T-20260908-007.json)。

## BRAM/cache focused 结果

boot 镜像已从当前候选重建：ELF 68832 B、BIN 957 B、HEX 2871 B、MIF 204942 B，
MIF 为 `WIDTH=64`、`DEPTH=8192`、8192 records，BIN/HEX 首 8 字节均为
`0x9100001f58001700`。

local 锁内、`MemoryMax=16G`、`MemorySwapMax=0`、`-j1` 运行：

- `lcvex_bram_boot_tb`：build/runtime/self-check PASS；
- `lcvex_cache_data_ram_tb`：build/runtime/self-check PASS；
- `lcvex_bram_init25_tb`：编译和 process exit 均为 0，但 TB self-check FAIL，因为
  它固定期望 `0x9100001f580017c0`，而当前同源候选镜像确定生成
  `0x9100001f58001700`。没有修改该测试期望，失败作为 test-contract blocker 保留。

初次运行还确认了新 worktree 未生成 boot.hex 的准备性问题；随后重建 boot 镜像并做了
fresh bram_init 编译/运行，结果仍是上述期望值不一致，而不是文件缺失。runner 已加入
marker 判据，避免 `$finish` exit 0 掩盖 TB 的 FAIL 文本。

## 边界与下一步

- T-007 没有运行 GamePC、Quartus、assembler、SOF/JIC/RBF/POF/JBC/SVF/JAM、
  `quartus_pgm`、JTAG、板卡配置/复位/上电或 Flash/EPCQ；没有读取 license 内容。
- T-009 可独立评估其它 Quartus blocker；本任务不等待也不代替该审计。
- `bram_init25_tb` 的 stale reset-vector 期望已明确拆出至独立
  `T-20260909-001`；T-007 不修改其 test expectation。宏 selector 与 checker hermetic
  contract 已闭合，合并后再进行唯一一次 fresh physical rerun。
