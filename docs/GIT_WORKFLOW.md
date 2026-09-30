# Git 和 QEMU Patch 工作流

## 分支

- `main`：稳定、可复现、通过 CI 的版本。
- `feature/<topic>`：RTL/功能开发。
- `verify/<topic>`：测试、差分和覆盖率。
- `infra/<topic>`：仿真、脚本、文档和 CI。
- `qemu/<release>`：对应固定 QEMU release 的 patch 开发。

多 Agent 的任务、写集、资源预算和状态以
[`docs/MULTI_AGENT_WORKFLOW.md`](MULTI_AGENT_WORKFLOW.md) 为准。任务定义放在
`docs/tasks/active/T-*.json`，`docs/tasks/TASKS.md` 是索引；当前 A0 尚无
`taskctl`，由集成者静态派单并手工维护，不能让多个 worktree 同时改索引。

## Worktree 生命周期

主/集成 Agent 使用仓库 root worktree；每个子 Agent 使用仓库外 sibling worktree，
并从任务记录中的已提交 `base_sha` 创建唯一 topic 分支。创建前必须检查 root 工作区：

```sh
test -z "$(git status --porcelain)" || {
  echo "integration worktree 有未提交改动，先由负责人处理" >&2
  exit 1
}
BASE_SHA="$(git rev-parse HEAD)"
TASK_ID="T-YYYYMMDD-NNN"
TASK_SLUG="short-slug"
WORKTREE_ROOT="${LCVEX_WORKTREE_ROOT:-..}"
# 集成者先用上面的 BASE_SHA 登记并提交任务记录。
git worktree add -b "feature/${TASK_ID}-${TASK_SLUG}" \
  "${WORKTREE_ROOT}/lcvex-wt-${TASK_ID}" "$BASE_SHA"
```

A2 尚未统一 QEMU 路径前，worktree 必须是 `/home/chiro/projects/mycpu/` 的直接
sibling，使现有 `$REPO/../qemu` 仍指向真实 fork；override 后还要 canonicalize 并
拒绝更深路径。完成所有 runner/toolcheck/plugin 入口参数化后，才可改用更深的
`.worktrees/` 层次。

不自动 stash、reset 或覆盖用户改动。一个 worktree 只能由一个 owner 使用，两个
worktree 不得 checkout 同一分支；任务记录必须保存 `base_sha`、绝对 worktree 路径
和 branch。纯只读审阅可共享指定快照；任何写入、构建或测试都必须进入独立
worktree。当前 QEMU linked worktree 尚不受全部脚本支持，QEMU 修改/构建串行，
最终导出 patch；不能共享可写的 `../qemu` 构建目录。

任务完成后先提交代码、handoff 和 evidence，集成者在 root 合并并重跑任务要求的
L0–L2；确认失败现场已归档后才执行 `git worktree remove` 和
`git worktree prune`。worktree
路径不要过深，锁步 Unix socket 路径必须小于 108 字节；可把 `RUN_ROOT` 指向仓库
外的短 sibling 目录。

所有 worktree 共享同一 Git 对象库。并行任务存活时禁止子 Agent 执行 `git gc`、
`git prune` 或仓库级 maintenance；集中 `fetch`/对象维护由集成者在仓库锁下执行，
并确认没有 checkout/fetch/测试清理正在使用对象库。

topic 分支默认只在本机共享对象库中协作；长任务、跨主机协作或远端备份由集成者
批准后推送。未推送分支不能替代 handoff/evidence 中的 commit 和 artifact 记录。

## 合并队列和不可变 Gate 快照

并行分支都基于同一个 `base_sha` 时，第一条合入后其余分支通常已落后，不能假设
所有分支都能直接 `--ff-only`。需要 rebase 时由 owner 在自己的 worktree 完成；
集成者在 root 按队列 cherry-pick/显式 merge，解决冲突后跑任务要求的 L0–L2，再
处理下一条。不能在 root rebase 一个仍被其他 worktree checkout 的 topic 分支，
也不得在子 Agent worktree 偷偷改集成基线。

Gate D、Linux 长跑和发布回归必须针对 immutable merge candidate SHA：可用
`git worktree add --detach` 创建短命 gate worktree，运行前记录 SHA、QEMU release/
patch hash、RTL `filelist.f`/配置 hash 和工具版本，运行后把结果与 artifact manifest
关联到该 SHA。不能在一个仍会继续修改的 Agent worktree 中后台跑 Gate D。

合并顺序、测试命令、结果、已知限制和失败现场路径写入合并提交或 handoff；只有
candidate 本地 Gate D 全绿，并在 CI 可信时 CI 也通过，才允许快进进入 `main`；
CI 未可信前仍以本地 Gate D 为准。

## 提交原则

提交信息格式：

```text
<scope>: <summary>
```

示例：

```text
decode: add ADD immediate decoder
pipeline: handle load-use stall
difftest: export QEMU post-step state
docs: define unified L2 baseline
```

一个提交只解决一个逻辑问题。功能、测试和文档可以在同一功能提交中完成，但不要混入无关格式化或重命名。

## 合并前检查

1. 编译和 lint 通过。
2. 单元测试通过。
3. 对应级别 QEMU 差分测试通过。
4. 失败测试有固定随机种子和重现命令。
5. 文档中的架构范围与代码一致。
6. 说明已知限制和未覆盖项。

## QEMU patch 管理

QEMU 不直接把大量私有逻辑散落在主仓库中。推荐流程：

1. 在本地 fork 中检出固定 release tag。
2. 每个逻辑修改形成一个独立提交。
3. 使用 `git format-patch` 导出到 `qemu/patches/`。
4. 通过脚本从干净 release 重新应用 patch。
5. 记录 release tag、commit、补丁顺序和构建参数。
6. 升级 QEMU 时建立新分支，重新应用并运行完整差分回归。

禁止直接依赖未记录的本地 QEMU 工作区状态。

## Tag 和版本

建议使用：

- `v0.1-difftest`
- `v0.2-scalar-pipeline`
- `v0.3-exception`
- `v0.4-mmu-cache`
- `v0.5-linux-boot`
- `v0.6-neon`
- `v0.7-sve256`

每个 tag 都应关联一份仿真回归结果。
