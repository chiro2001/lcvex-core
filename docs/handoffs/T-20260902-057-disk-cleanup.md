# T-20260902-057 磁盘清理交接

```text
task=T-20260902-057 state=review base=5bb2208af27b170ab2286029a0f497460c2ec026 head=cac192ca615eb90696a7eb671760620be13d2091
branch=infra/T-20260902-057-disk-cleanup worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-057
sent_at=2026-09-04T21:36:55+08:00 received_at=2026-09-04T21:39:37+08:00 reported_at=2026-09-04T21:51:46+08:00
files=docs/handoffs/T-20260902-057-disk-cleanup.md,docs/tasks/evidence/T-20260902-057.json
tests=未运行测试或构建；仅执行存储、Git registry、realpath、status、进程和 df/du 只读核验
blockers=无；第一次生成目录命令在删除 obj_dir* 后因脚本变量拼写错误安全中止，已修正并完成剩余白名单清理
next=integrator verify
```

## 结论

本任务已按登记的白名单完成清理，状态为 `review`。共移除 202 个经 registry
登记、clean、ref 可保留且无进程占用的历史 worktree，以及 96 个集成根一级可重建
目录。按逐项 `du -sx --bytes` 之和，逻辑回收约 **189,812,377,410 bytes**：

- 历史 worktree：202 个，169,885,733,839 bytes；
- `obj_dir*`：31 个，4,800,276,788 bytes；
- `sim/cocotb/sim_build*`：31 个，5,294,389,948 bytes；
- `build/verilator*`、`microbench_runner*`、`dbg_*_work`、`lcv_dbg`、
  `c2_dual_default`：34 个，9,831,976,835 bytes。

只删除了可由 Git 分支/ref 或构建入口重建的内容；不可恢复部分仅为这些构建
产物和 worktree 工作目录。源码仍由保留的 local branch/ref 恢复，且没有删除任何
branch/ref。

## 前置检查与执行记录

完整阅读了本 worktree 的 `AGENTS.md`、`docs/MULTI_AGENT_WORKFLOW.md`、集成根的
`docs/tasks/active/T-20260902-057.json` 和 `docs/HANDOFF_20260904_TO_CODEX.md`。
集成根在操作期间的 HEAD 为 `576acaaa61882aaa6535ce97721ae35e02ce5357`
（21:37:26+08:00 的 dispatch 提交）；本 owner worktree 按任务登记仍以
`5bb2208af27b170ab2286029a0f497460c2ec026` 为 base。

关键检查时点（Asia/Shanghai）：

| 时点 | 事实 |
| --- | --- |
| 21:39:37 | 初始 df：used `173,018,787,840`，available `94,076,325,888`；集成根 du `31,891,067,070` bytes。 |
| 21:40:14 | registry 209 项；按 direct sibling 名称筛出 208 候选；202 clean、2 dirty、1 detached 无 local ref、3 protected。 |
| 21:44:09–21:44:12 | 删除 gate：非保护 worktree 无进程 cwd/fd/命令行使用；无 Verilator/Quartus/QEMU/Cocotb/pytest/make 等活动进程。 |
| 21:45:29–21:46:03 | 逐项执行 `git -C /home/chiro/projects/mycpu/lcvex worktree remove -- <exact-path>`，无 `--force`，202 成功、6 跳过。 |
| 21:46:56 | 生成目录清理首段：df used `144,017,829,888`，du 根 `31,871,202,542` bytes；31 个 `obj_dir*` 已逐项删除。 |
| 21:47:37–21:47:40 | 修正脚本后删除剩余 65 个 sim/build 目录；df used `138,704,551,936`，du 根 `11,944,558,971` bytes。 |
| 21:48:39–21:48:40 | 最终 registry/保护路径/状态核验；df used `135,895,453,696`，available `129,934,159,872`，du 根仍 `11,944,558,971` bytes。 |

`du` 逻辑字节总量显著高于 df 的可用空间变化，符合任务已知的 hardlink/sparse/
重复工作树计量差异。21:48 最终 df 相对 21:47:40 又下降了
`2,809,098,240` used bytes；当时观测到另一个仓库 `/home/chiro/projects/lcvo`
的独立清理进程（PID 49204），该外部路径不在本任务写集，故不计入本任务回收量。

第一次生成目录命令在完成 31 个 `obj_dir*` 后由于校验分支中误写了未定义变量
`simp ar ent`，在 `set -u` 下退出；没有越过白名单，也没有半删除目录。随后从
`find -P` 重新枚举剩余路径并完成 sim/build 65 项；该脚本失误和两段执行时间均已
保留在 evidence 中。

## worktree 操作

所有下列路径均来自操作前的
`git -C /home/chiro/projects/mycpu/lcvex worktree list --porcelain`，真实路径经
`realpath -e` 验证仍是 `/home/chiro/projects/mycpu/lcvex-wt-*` 或
`/home/chiro/projects/mycpu/lcvex-gate-*` 的 direct sibling。每项均执行
`git status --porcelain --untracked-files=all`；branch worktree 只移除 worktree，
detached worktree 仅在 HEAD 被 local ref 包含时移除。

已移除路径（同一组的逐项原因均为 `registry-listed + realpath-ok + clean + no-process + ref-safe`）：

- gate：`lcvex-gate-T-20260827-061`、`lcvex-gate-T-20260828-067`、
  `lcvex-gate-T-20260828-069`、`lcvex-gate-p7-final`。
- `T-20260826`：`004`、`006`–`027`（不含 `028`）、`029`–`037`、`039`–`049`。
  其中 `038` 未移除，原因见下表。
- `T-20260827`：`051`、`051-wiring`、`051-wiring-repair`、`053`、`054`、
  `055`、`056`、`058`、`059`、`060`。
- `T-20260828`：`065`、`067`、`069`。
- `T-20260829`：`074`–`092`、`095`、`100`、`106`–`108`、`110`–`112`、
  `114`、`115`、`117`、`118`；`099` 未移除，原因见下表。
- `T-20260830`：`001`–`006`、`008`、`010`–`023`、`026`、`028`–`031`、
  `035`–`046`。
- `T-20260831`：`001`、`002`、`003`、`005`、`006`、`007`、`008`；`004` 未移除，
  原因见下表。
- `T-20260901`：`001`、`002`、`003`、`004`、`005-gate`、`006`、`007`、
  `008-gate`、`009`、`010`、`011`。
- `T-20260902`：`001`、`002`、`004`–`011`、`013`–`049`、`051`、`052`、`053`。
- 其它 direct sibling：`lcvex-wt-fpga-catapult-a10`、
  `lcvex-wt-review-T-20260830-043`、`lcvex-wt-review-T-20260830-044`、
  `lcvex-wt-review-T-20260830-046`、`lcvex-wt-review-T-20260831-002`。

上述分组中的数字范围仅是阅读压缩；evidence 的 `removed.worktrees.items` 保存
了每个被移除 basename 的精确清单，原始命令逐项记录了删除前 du 字节和 HEAD。

跳过项如下，均保持原路径和现场：

| 路径 | 删除前 du bytes | HEAD/status | 原因 |
| --- | ---: | --- | --- |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260826-038` | 2,245,561 | `e7b43d8244d61f7af9005f087ceb935f05e5f2a9`，clean detached | HEAD 不被任何 local ref 包含，按规则 skip。 |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260829-099` | 3,059,052,760 | `3dcffe0e6ddd7946c0bf560ca36778c6a1531f28`，status_count=2 | dirty：未跟踪 `docs/handoffs/T-20260829-099-gate-d.md` 和 `docs/tasks/evidence/T-20260829-099.json`。 |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260831-004` | 5,152,739,521 | `74cf7289c9fa630dc583cc612fc3ee3bdcae6901`，status_count=4 | dirty：包含 RTL、文档和 evidence 修改，保留失败/未归档现场。 |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260902-054` | — | final `6df1a92f31421c8fa12309418bf20f06baaa6b7d`，dirty handoff | protected active worktree。 |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260902-056` | — | final `b5df14ecfa478f177407cb45d3a55817b983a3eb`，clean | protected active worktree。 |
| `/home/chiro/projects/mycpu/lcvex-wt-T-20260902-057` | — | `5bb2208af27b170ab2286029a0f497460c2ec026` | protected cleanup worktree。 |

## 集成根可重建目录

目录只由 `find -P` 在固定一级父目录枚举，逐项 `realpath -e`、父目录比较、进程
cwd/fd/命令行检查和 `du -sx --bytes` 后使用明确路径 `rm -rf -- <realpath>` 删除；
没有使用未解析 glob、没有删除父目录、没有运行 `git clean`。

删除类别和逐项 manifest：

- `/home/chiro/projects/mycpu/lcvex/obj_dir*`：31 项，4,800,276,788 bytes；
- `/home/chiro/projects/mycpu/lcvex/sim/cocotb/sim_build*`：31 项，5,294,389,948 bytes；
- `/home/chiro/projects/mycpu/lcvex/build`：34 项，9,831,976,835 bytes。

`build` 类包括 `verilator_lockstep_d1`、`verilator_lockstep_d2`、
`verilator_lockstep_l1d`、`verilator_lockstep_l1i`、`verilator_lockstep_l1di`、
`verilator_lockstep_l2`、`verilator_lockstep_l1dl2`、`verilator_lockstep_l1dl2_d2`、
`verilator_lockstep_kernel.bad`、`.bad2`、`.bad3`、`verilator_lockstep`、
`verilator_lockstep_kernel`、`verilator_lockstep_kernel_nofp`、
`verilator_lockstep_f1a`、`microbench_runner`、
`microbench_runner_nocache_d0`、`microbench_runner_l1i_d0`、
`microbench_runner_l1d_d0`、`microbench_runner_l1id_d0`、
`microbench_runner_l1id_l2_d0`、`microbench_runner_nocache_d1`、
`microbench_runner_nocache_d2`、`microbench_runner_fullcache_d1`、
`microbench_runner_fullcache_d2`、`lcv_dbg`、`c2_dual_default`，以及
`dbg_decode_work`、`dbg_decode2_work`、`dbg_decode3_work`、`dbg_decode4_work`、
`dbg_decode5_work`、`dbg_mvn_work`、`dbg_logic_work`。sim/obj 的完整 basename 和
删除前字节 manifest 在 evidence 中按类别保存。

保护目录 `/build/agents`、`/build/difftest`、`/build/tmp`、`/build/linux-6.6`、
`/build/linux-lite-6.6`、`qemu/plugins` 均未命中 find 白名单，未触碰。

## 最终核验与恢复

- 最终 `git worktree list --porcelain` 仍有效且只剩 7 项：集成根、
  `T-20260826-038`、`T-20260829-099`、`T-20260831-004`、保护的 T-054/T-056、
  cleanup T-057。
- 集成根分支仍为 `feature/p7-final`，未跟踪的两个 HANDOFF
  `docs/HANDOFF_20260902_TO_DSH.md` 和 `docs/HANDOFF_20260904_TO_CODEX.md` 均存在。
- active T-054/T-056/T-057 路径存在；T-054 的 dirty handoff 和 T-056 的源码/文档
  现场未改动。
- 保护目录和外部 `/home/chiro/projects/mycpu/qemu` 均存在且 realpath 正确；外部
  QEMU、`qemu-replay-*`、远端 Quartus probe、Linux 源/镜像、cache、失败现场均未清理。
- 删除的 branch worktree 对应 branch 仍保留；spot-check
  `infra/T-20260826-023-runner-resource`、`feature/T-20260829-079-c1-dualcore-shell`、
  `fix/T-20260902-048-core-fp-operand-c-cut`、`feature/fpga-catapult-a10` 均通过
  `git show-ref --verify`。detached 被删除前仅要求 HEAD 被 local ref 包含；不包含的
  T-038 保留。
- 源码恢复：从保留 branch/ref checkout 或重新创建 worktree 即可恢复源码；构建
  目录由原有 Make/Verilator/Cocotb 入口重建。被删除目录本身不可恢复，但没有架构
  源码或文档内容在本任务中被删除。

精确命令、时间、计量、逐项 skip 和路径 manifest 见
`docs/tasks/evidence/T-20260902-057.json`。

task=T-20260902-057 state=review base=5bb2208af27b170ab2286029a0f497460c2ec026 head=cac192ca615eb90696a7eb671760620be13d2091 branch=infra/T-20260902-057-disk-cleanup worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-057 sent_at=2026-09-04T21:36:55+08:00 received_at=2026-09-04T21:39:37+08:00 reported_at=2026-09-04T21:56:38+08:00 removed=267/189812377410 skipped=6 protected=pass blockers=none next=integrator verify
