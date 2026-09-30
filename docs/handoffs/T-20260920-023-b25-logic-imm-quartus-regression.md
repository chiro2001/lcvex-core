# T-20260920-023：B25 logical-immediate Quartus 回归交接

```text
task=T-20260920-023
state=done-owner-review
branch=verify/T-20260920-023-b25-logic-imm-quartus-regression
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-023
base=836f7fd884c5561abf2238a27f99e54ede8dc4e0
functional-baseline=1ce74e9c81c40812ea93a161d52cad8dda807a0d
remote-root=D:/Projects/fpga-altra/lcvex/build/T-20260920-023-b25-logic-imm-quartus-regression
```

## 结论

任务专属的行为 oracle、Quartus 最小综合工程、post-map netlist 尝试和 fail-closed
runner 已完成。没有修改 RTL、固件、公共 expected、公共 registry 或任务 JSON。

行为 oracle 在 Verilator 5.050 下通过了两个 T-021 精确指令，并完整枚举了 16,384
个逻辑立即数编码：

```text
0x12003C06: W0=0x0000A43F -> W6=0x0000A43F
0x12001C00: W0=0x0000A43F -> W0=0x0000003F
```

枚举维度为 `sf=0/1`、`N=0/1`、`immr=0..63`、`imms=0..63`。其中合法 11,328 项逐一
比较 `d.valid`、`d.exc`、`d.operand_b` 和 `d.is_32`，保留 5,056 项逐一要求
`d.valid=0` 且 `d.exc=1`。参考函数独立实现 AArch64 DecodeBitMasks，没有复用 RTL
函数的 output argument。通过标记为：

```text
LOGIC_IMM_BEHAVIORAL_ORACLE_PASS exact=A43F/3F exhaustive=16384 legal=11328 reserved=5056
```

## 旧 RTL 负控

在全新 task-owned GamePC variant 下，从功能基线 `1ce74e9c` staging，而不是把
T-017 旧报告当作本轮证明。使用 Quartus Prime 21.4.0 Build 67，命令由
`resource-lock run gamepc` 持锁执行，且只运行 synthesis 和 EDA netlist writer：

```text
quartus_sh --flow compile lcvex_logic_imm_probe -c lcvex_logic_imm_probe \
  -start synthesis -end synthesis
quartus_eda --simulation --tool=modelsim --format=verilog \
  --output_directory=eda_output lcvex_logic_imm_probe -c lcvex_logic_imm_probe
```

结果：

- synthesis exit=0，`Successful`，0 errors，3 warnings；
- 新报告中 `Warning (16788)` 出现 2 次（报告摘要和详细行各一次），唯一问题为
  `Net "imm[63]_2" does not have a driver`，源为 `lcvex_decode.sv(1806)`；
- `quartus_eda` exit=0，并生成 `lcvex_logic_imm_probe.vo`，4,126,462 bytes，SHA256
  `e16c6a2e51ed9f5e3d697a60314179a23c653777b6ca52d886b739d28a4f7145`；
- GamePC 没有可兼容的 `iverilog/vvp` 或厂商 primitive 仿真路径；本地直接尝试该
  netlist 也明确失败于缺少 `twentynm_lcell_comb` 模型。因此 post-map 语义状态记录为
  `UNAVAILABLE_NO_COMPATIBLE_SIMULATOR`，没有把 netlist 生成误报成语义证明。

旧控 runner 只在 fresh synthesis 成功且 16788 存在时报告
`PASS_SYNTHESIS_WARNING_CONTRACT_POSTMAP_LIMITED`。固定候选模式则把 16788 视为
失败条件；因此它不能通过“过滤/豁免 warning”掩盖问题。

为验证这个硬失败条件，使用当前旧 RTL 做了一次 `--fixed` 自检；synthesis 仍然
复现 16788，runner 以 exit=1、`fixed-candidate-warning-16788` 失败。该失败现场已
改名保留在 task-owned quarantine variant，不占用后续合并 candidate 的 `fixed`
variant 名称。

## 写集与复用

新增文件均在 T-023 登记写集：

- `fpga/catapult_a10/tb/sv/lcvex_logic_imm_quartus_tb.sv`：行为 oracle；
- `fpga/catapult_a10/tb/filelist_logic_imm_quartus.f`：任务专属 filelist；
- `fpga/catapult_a10/tools/quartus_logic_imm/`：最小 QPF/QSF、Quartus top、post-map
  TB 和远端 PowerShell probe；
- `fpga/catapult_a10/tools/run_logic_imm_quartus_regression.sh`：行为、old-negative、
  fixed 三种模式的 runner；
- 本任务 evidence/handoff。

T-024 合入批次 candidate 后，集成者在该 SHA 的 worktree 运行：

```bash
/home/chiro/projects/.resource-locks/resource-lock run local lcvex \
  T-20260920-023 logicimm_test -- \
  fpga/catapult_a10/tools/run_logic_imm_quartus_regression.sh --behavioral

/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex \
  T-20260920-023 logicimm_test --meta stage=fixed-synthesis \
  --meta source_sha=<merged-sha> -- \
  fpga/catapult_a10/tools/run_logic_imm_quartus_regression.sh --fixed
```

`--fixed` 要求全新 variant、synthesis report 成功/0 errors 且 warning 16788 为零；
缺少报告、stale output、semantic mismatch 或配置产物都会 fail closed。若 GamePC
仍没有兼容仿真器，结果必须保留明确的 post-map limitation；一旦有可兼容的 vendor
model，runner 会执行 `lcvex_logic_imm_quartus_postmap_tb.sv`，并把 semantic mismatch
作为硬失败。

## 安全边界

本任务未运行 fitter、STA、assembler、quartus_pgm、JTAG、板卡配置、Flash/JIC/EPCQ、
reset 或 power-cycle；未停止标准 `jtagserver` 或未知进程。所有 GamePC SSH/SCP/
Quartus 动作均在 `gamepc` 锁内，行为编译在 `local` 锁内。

精确 artifact/hash、命令和 limitation 见
[`T-20260920-023.json`](../tasks/evidence/T-20260920-023.json)。
