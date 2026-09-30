# FPGA-G6-PROV：Catapult A10 provenance 重锁

```text
task=T-20260831-002
label=FPGA-G6-PROV
base=4764d834c33055814846db46dc29c6fc74290358
branch=infra/T-20260831-002-a10-provenance-relock
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-002
date=2026-08-31
```

## 结论

Catapult A10 平台的来源与目标 provenance 已重新闭合：参考仓锁定提交的 50/50
个 raw Git blob 均与 `platform_manifest.json`、`source.lock` 中的 source hash/字节
数一致；当前工作树的 50/50 个 target payload 均与 manifest 和 `SHA256SUMS`
一致。没有修改任何平台 payload，只更新了 provenance metadata、校验脚本和文档。

校验入口现在有两个明确层级：

```sh
# 离线；不会访问 /home/chiro/projects/a10-linux-riscv
python3 fpga/catapult_a10/tools/check_platform.py

# 严格来源门；所有 git 操作只读
python3 fpga/catapult_a10/tools/check_platform.py \
  --strict-source \
  --source-repo /home/chiro/projects/a10-linux-riscv \
  --source-commit 3db828e74651fda377a33d84f2a2ca0e69901d72
```

两条命令在本任务中都返回 0，并报告 `files=50`。严格模式还确认来源仓 clean、
HEAD 与完整 40 位 commit 一致，并通过 `git cat-file blob <commit>:<path>` 逐条
计算 raw bytes；不会读取来源工作树文件，也不会写入参考仓。

## 重锁范围

来源仓及提交固定为：

```text
repo=/home/chiro/projects/a10-linux-riscv
commit=3db828e74651fda377a33d84f2a2ca0e69901d72
status=clean; HEAD matches locked commit
```

此前预检发现 50 项中 27 项匹配、23 项不匹配。本任务将那 23 项按上述提交的
raw blob 重锁；路径、target path、role 均保持原值。变更集中在 SFL 的 clk、rst、
EPCQ component/generated HDL 及顶层 `sfl_sys` 生成文件：

- `hw/ip/sfl/ip/sfl_sys/clk.ip`、`clk/clk.cmp`、`clk/clk_bb.v`、`clk/clk_inst.v`、
  `clk/clk_inst.vhd`、`clk/synth/clk.v`；
- `hw/ip/sfl/ip/sfl_sys/epcq/` 下的 `rmd4qmi.v`、两个 controller HDL、
  `epcq.cmp`、`epcq_bb.v`、`epcq_inst.v`、`epcq_inst.vhd`、`synth/epcq.v`；
- `hw/ip/sfl/ip/sfl_sys/rst.ip`、`rst/rst.cmp`、`rst/rst_bb.v`、`rst/rst_inst.v`、
  `rst/rst_inst.vhd`、`rst/synth/rst.v`；
- `hw/ip/sfl/sfl_sys.cmp`、`sfl_sys_inst.vhd`、`synth/sfl_sys.v`。

来源锁仍是五列 TSV：

```text
source_sha256<TAB>source_bytes<TAB>source_path<TAB>target_path<TAB>role
```

source 字段描述 Git raw blob；target 字段描述当前 LCVEX checkout 的 payload。
两者字节数不同是允许的，常见原因是生成物/换行差异，不能用 target hash 代替
source provenance。

## 当前 target 摘要

目标集合仍为 50 项，包含 Quartus/Qsys、SFL/EPCQ、JTAG-UART 和 Quartus 约束输入。
本次重新计算了 target metadata；其中预检识别出的两项漂移为：

| target | 当前 SHA-256 | 当前 bytes |
| --- | --- | ---: |
| `quartus/catapult_a10.qsf` | `78032dc5634dc08bf15e916fb70e9f2f6ddefd6b2dd5d59600b3c4c3a236f19d` | 13647 |
| `quartus/catapult_a10.sdc` | `caf847755a8c42f2e88ea09e434888938ad4382193400593ddcc986f26154a8c` | 5656 |

QPF、Qsys、SFL 和 JTAG-UART 其余项的 target bytes/hash 保持当前 payload 原值，
并全部由 `SHA256SUMS` 复核通过。QSF/SDC 的 source bytes/hash 仍然单独描述锁定
参考仓原文件，不能据此声称当前约束与参考仓内容相同。

## skeleton manifest 补锁

集成复核发现 B0 skeleton manifest 中顶层 shell 的 metadata 已过期。本次只更新
`fpga/catapult_a10/skeleton_manifest.json` 的该条 bytes/SHA，不修改
`rtl/lcvex_catapult_a10_top.sv`、reset gate、QPF/QSF/SDC 或其它 skeleton 文件：

| 文件 | SHA-256 | bytes |
| --- | --- | ---: |
| `rtl/lcvex_catapult_a10_top.sv`（payload，未修改） | `e72d81427c4426ceab8093e6c2666c1b2bc38e21b077ffa120150f8c10811678` | 10593 |
| `fpga/catapult_a10/skeleton_manifest.json`（metadata 文件） | `f97a0f723c0d573cf1b8624322e958ee4853e1e39dee221c773dfd599deb7ec0` | 4189 |

默认 `python3 fpga/catapult_a10/tools/check_skeleton.py` 已通过 skeleton contract，
仅报告环境缺少 `quartus_sh`、`ip-generate`、`qsys-generate`（`TOOLCHAIN_MISSING`）；
它生成的本地 `build/agents/T-20260827-062/skeleton-toolchain-report.json` 不纳入
Git 写集，也不改变任何平台实体。全量交付写集因此为 9 个文件：原 8 个重锁交付
文件加上 skeleton manifest；correction tip 相对首次交付只包含 skeleton manifest、
本正文、本 handoff 和本 evidence 四个 metadata 文件。

## checker 加固

`check_platform.py` 保留无参数离线兼容路径，并新增显式 `--strict-source`：

1. manifest、source.lock、SHA256SUMS 和实际 payload 必须各自闭合且为 50 项；
2. manifest/source.lock/SHA256SUMS 中的 target/source path 必须是安全的相对 POSIX
   路径；拒绝绝对路径、Windows drive path、反斜杠和 `..`/`.` 穿越；
3. manifest、lock、SHA256SUMS 的重复 target/source path 会报错，不再由字典静默
   覆盖；缺失、额外、malformed 行也会失败；
4. 每个 target 都独立检查 SHA-256 与 bytes；SHA256SUMS 必须与 manifest 的 target
   hash/集合完全一致；
5. strict-source 要求 source repo 可解析为 Git worktree、`git status
   --porcelain --untracked-files=all` 为空、HEAD 精确等于指定完整 commit，且 50 个
   raw blob 的 SHA-256/bytes 与 manifest 和 lock 一致；
6. `--source-repo`/`--source-commit` 只能与 `--strict-source` 一起使用，避免默认
   离线检查隐式访问外部目录。

路径和 provenance 错误会统一以 `PLATFORM_CHECK_FAIL` 和非零退出码报告；成功仍
   以 `PLATFORM_CHECK_PASS files=50` 开头，便于已有脚本兼容。

## 验证证据

以下命令均在本 worktree 执行，完整命令、退出码和负测输出见
[`docs/tasks/evidence/T-20260831-002.json`](tasks/evidence/T-20260831-002.json)：

| 检查 | 结果 |
| --- | --- |
| `python3 -m py_compile fpga/catapult_a10/tools/check_platform.py` | 通过 |
| 默认 `check_platform.py` | `PLATFORM_CHECK_PASS files=50 strict_source=OFF` |
| 显式 strict-source（clean ref + locked commit） | `PLATFORM_CHECK_PASS files=50 strict_source=PASS` |
| `python3 fpga/catapult_a10/tools/check_skeleton.py` | `SKELETON_CHECK_PASS files=6`（TOOLCHAIN_MISSING 仅提示） |
| 50 个参考 raw blob 的 SHA-256/bytes | 50/50 通过 |
| `(cd fpga/catapult_a10 && sha256sum -c SHA256SUMS)` | 50/50 通过 |
| `jq -e . fpga/catapult_a10/platform_manifest.json` | 通过 |
| `git diff --check` | 通过 |

在临时副本中将一行 source.lock hash 改为全零、将一行 SHA256SUMS target hash
改为全零，checker 均返回非零并拒绝；临时副本不会改变真实参考仓或本 worktree
payload。另以重复 source.lock target、manifest 的 `../` target path 和
`../` SHA256SUMS path 做隔离负测，分别命中 duplicate/path traversal 检查；代码对
source.lock 的 source path 也使用同一套 traversal guard。

## 非动作与边界

- 未修改 QPF/QSF/SDC/Qsys/SFL/JTAG-UART/RTL 或任何 payload；QSF/SDC 只重新记录
  当前 bytes/hash；skeleton manifest 只更新顶层 payload 的 bytes/SHA metadata；
- 未运行 Quartus、Qsys、仿真、综合、fit、STA、assembler 或 programming；
- 未向远端工程写入、未读取 license 内容、未操作 JTAG/Flash/EPCQ；
- 参考仓仅执行 clean/HEAD/commit/blob 的只读查询；没有 checkout、reset、写文件或
  修改进程；
- strict-source 只验证 provenance 与内容闭合，不代表 speed grade 不一致已经由
  Quartus 21.4 STA 关闭，也不解除前序预检记录的 full synthesis 资源阻断。

## 风险与下一步

来源 raw blob 与当前 target 的差异仍需在精确 Quartus 21.4 环境中按既定生成流程
解释；本任务没有把参考仓生成物复制回 LCVEX。远端平台工程仍需另立、可审计的
candidate 同步任务，随后才可按预检要求进行资源受控的 reduced/partition synthesis。
full flow、JTAG device identity、DDR 校准和任何 Flash 写入继续遵守前序任务的
WAIT/BLOCKED 门。
