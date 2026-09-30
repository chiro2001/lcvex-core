# T-20260908-008：B25 SYNTHESIS 宏语义审查交接

```text
task=T-20260908-008 state=blocked-candidate
decision=macro-semantics-approve-with-conditions; current-candidate-BLOCK
base=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
head=bdb764a5bd7bb0b5b74f9918e8aa6b86994318a7
dispatch_parent=005a8984be951479a878b1c55740c90fe37ca7b6
dispatch_commit=7d87a943fb159512874f1d1cba726d7ef8ed763f
branch=verify/T-20260908-008-b25-synthesis-macro-review
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-008
sent_at=2026-09-08T23:26:27+08:00 received_at=2026-09-08T23:26:27+08:00
reported_at=2026-09-08T23:41:41+08:00
files=docs/tasks/evidence/T-20260908-008.json,docs/handoffs/T-20260908-008-b25-synthesis-macro-review.md
tests=read-only/static only; no build, Quartus or remote action
blockers=checker rejects VERILOG_MACRO; fresh alias/MIF closure and synthesis rerun pending
evidence=docs/tasks/evidence/T-20260908-008.json
```

## 结论

建议 T-007 的宏语义为 **approve with conditions**：QSF 增加唯一的

```text
set_global_assignment -name VERILOG_MACRO SYNTHESIS
```

会选择现有、已经设计好的 Quartus 分支，并绕开 T-006 首错所在的行为级
`lcvex_bram_boot_behav`。但当前 candidate 仍为 **BLOCK**，因为
`check_platform.py:481` 把任意 `VERILOG_MACRO` 列为 forbidden text；若直接加入宏，
现有平台检查必然失败。当前 QSF 的宏 assignment 数为 0，且当前 checkout 没有生成的
`boot.mif` 和 29 个 QSF 相对路径 alias。

## SYNTHESIS 条件闭包

对 Catapult QSF 的 49 个 assignment 做了只读解析（48 个 source assignment 加 1 个
MIF assignment），将 `../../rtl/*.sv` 映射到 canonical 根 `rtl/*.sv` 后，扫描到全部
6 个可达条件：

| 文件:行 | 条件 | 定义 `SYNTHESIS` 时 | 未定义时 |
| --- | --- | --- | --- |
| `fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv:58` | `ifdef` | `../boot/build/boot.mif` | `fpga/catapult_a10/boot/build/boot.hex` |
| `rtl/lcvex_bram_boot.sv:57` | `ifdef` | `lcvex_bram_boot_altsyncram` | `lcvex_bram_boot_behav` |
| `rtl/lcvex_bram_boot.sv:94` | `ifndef` | 行为级模块排除 | byte-array、`$readmemh`、`prog_we` 行为级实现保留 |
| `rtl/lcvex_bram_boot.sv:214` | `ifdef` | `altera_syncram`、`BIDIR_DUAL_PORT`、M20K、MIF init | synthesis-only 模块排除 |
| `rtl/lcvex_cache_data_ram.sv:40` | `ifdef` | `altera_syncram`、`SINGLE_PORT`、M20K | packed-line 行为级 memory |
| `rtl/lcvex_fp_scalar.sv:5914` | `ifndef` | R20 route assertions 排除 | 6 个 R20 route assertions 保留 |

因此，宏定义不会切换 FP 功能 datapath；它只排除 synthesis 不适用的断言，并选择
BRAM/cache 的显式 M20K 实现和物理 MIF 路径。T-006 的 Error 19544 位于
`lcvex_bram_boot.sv:165` 的 `ifndef SYNTHESIS` 行为级加载过程，结构上会被排除；这
是静态结论，不是新的 Quartus 通过证据。

## 文件、MIF 与重复定义检查

- 当前 QSF 直接引用 29 个 `../../rtl/*.sv`。在仓库 checkout 中它们会解析到不存在的
  `fpga/rtl`；候选同步必须按 `docs/FPGA_A10_REMOTE_CANDIDATE_SYNC.md:37-43` 生成
  29 个逐字节 alias，不能把 alias 当成新的 RTL 实现。
- `fpga/catapult_a10/quartus/catapult_a10.qsf:12` 和
  `lcvex_catapult_a10_top.sv:59` 使用同一 `../boot/build/boot.mif` 路径；顶层在
  `:241` 把它作为现有 `BOOT_HEX_FILE` ABI 传给 SoC，BRAM synthesis wrapper 的
  `INIT_FILE` 再使用该值。`build.sh` 生成的契约为 WIDTH=64、DEPTH=8192、8192 条
  record。
- MIF 是 ignored/generated physical input。T-006 记录的 MIF 为 204942 bytes，SHA-256
  `614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7`，但 T-006 synthesis
  失败，只有 `User-Specified_Memory_Initialization_File` 识别，不能声称已完成 M20K
  consumption 或 fitter/STA 签核。
- QSF 直接 HDL assignment 对应的 canonical HDL 共 52 个 module declaration、52 个唯一
  名字、0 个重复；QIP 仅携带平台 vendor sources，不包含 LCVEX BRAM wrapper。
  `rtl/lcvex_bram_boot_altsyncram.sv:23` 另有同名
  `lcvex_bram_boot_altsyncram`，但不在 Catapult QSF 或 `rtl/filelist.f` 中；禁止 T-007
  把该 standalone wrapper 追加到 QSF。`lcvex_bram_boot_shim` 是不同名字，不构成重复。

## 边界风险

显式 M20K wrapper 已知不支持跨 8-byte word 的拆分访问：综合路径返回 fault，行为级
模型仍支持逐字节跨 word 访问。这是 T-20260830-031 已记录的 bounded known risk；当前
B25 boot/cache 路径以对齐 refill、writeback 和取指为合同，因此不阻止 selector contract，
但不能据此宣称非缓存未对齐 BRAM 与仿真完全等价。综合 wrapper 的 `prog_we` 也只保留
接口，不执行运行时加载；板级 top 在 `:226-229` 将其 tie-off，启动内容必须来自 MIF。

## 给 T-007 / 集成者的最小边界

1. QSF 只加入一个精确的 `SYNTHESIS` 宏；不得带入参考工程的 `C_ALIAS_ENABLE`、
   `FLASH_DIAG`、SignalTap 或任何 RISC-V source path。
2. 将 `check_platform.py` 的禁止规则收窄为“恰好一个 `SYNTHESIS` 宏，拒绝其他宏和
   重复宏”，并更新相关 manifest/hash；`check_skeleton.py` 当前没有宏策略，若其作为
   独立 build-contract 检查器，应补一个宏 anchor，否则它可能在宏缺失时仍通过。
3. 重新生成 boot MIF、materialize alias 并绑定新 candidate manifest；不把 standalone
   `lcvex_bram_boot_altsyncram.sv` 加入 QSF。
4. 在不定义 `SYNTHESIS` 的行为路径上完成平台/skeleton/hash 和既有 focused checks，
   再以同一 fresh candidate 做一次 Quartus synthesis；只有 synthesis 成功后才可进入
   fitter、STA、M20K/resource 和 assembler 判断。

本任务没有修改 RTL/QSF/manifest/test/active task，也没有运行任何 build、Verilator、
Quartus、GamePC、assembler、JTAG、板卡或 Flash 操作。精确输入 hash、静态命令与决策
见 [`T-20260908-008.json`](../tasks/evidence/T-20260908-008.json)。
