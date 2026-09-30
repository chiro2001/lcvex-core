# Handoff T-20260826-001：分层测试 registry 与查询入口

## 元数据

- task: T-20260826-001
- owner: root/integrator
- date: 2026-08-26
- base_sha: 7e1e457bbcebe2e49585a95cb2605d0f3d238a09
- head_sha: f2c750aadd28d7a2dacb82e11e95975cad774d9b
- branch: infra/T-20260826-001-test-registry
- worktree: /home/chiro/projects/mycpu/lcvex-wt-T-20260826-001
- dependencies: none
- qemu_release: not used
- qemu_commit: not used
- qemu_patches_sha: not used
- rtl_filelist_sha: 5adf9f91bc31c27c4dfbdf466a21f0a013c51689860d605a11fe5fca26534cbb
- config/toolchain: Python 3.12.10；未启动 RTL/QEMU
- evidence: docs/tasks/evidence/T-20260826-001.json

## 目标与边界

为五个稳定子域建立统一的 L0–L4 测试入口清单和只读查询接口。第一版不执行测试、
不申请资源、不替换现有 runner，也不把 `--only`/`MB_ONLY` 等旧入口强行改写。

## 实现摘要

- `scripts/test_registry.json`：18 项现有/计划验证入口，记录唯一 ID、域、层级、
  类型、标签、命令、状态和资源建议。
- `scripts/test_registry.py`：JSON 校验、按 ID/title、域、层级、标签、状态筛选，
  text/JSON 输出和单项 `show`。
- `scripts/test_registry_test.py`：无外部依赖的 registry/CLI 单测。
- `Makefile`：增加 `make test-registry-check` 与 `make test-list ARGS=...`，默认
  `make test`、Gate D 和锁步行为不变。
- `docs/TEST_ENHANCEMENT_PLAN.md`：记录 registry 的只读定位和后续接入条件。

## 验证证据

| Evidence run ID | 层级 | 结论/说明 |
| --- | --- | --- |
| owner-l0-001 | L0 | registry 校验、Python 单测、CLI 查询通过 |
| owner-l1-001 | L1 | Make 查询入口和 JSON 输出断言通过 |

精确命令、版本和输出摘要以 evidence JSON 为准。

## 失败现场/重现

本任务未产生 RTL/QEMU 失败现场。重现：

```bash
python3 scripts/test_registry.py --check
python3 scripts/test_registry_test.py
make test-registry-check
make test-list ARGS='--tag p6'
```

## 已知限制与后续任务

- registry 目前是手工维护的描述层，未自动从 Makefile/shell 数组生成；入口重命名时
  需同步修改 JSON。
- 尚未根据 registry 自动生成 L0–L2 执行套餐；需先观察 A0 手工队列是否成为瓶颈。
- T-20260826-002 的 checkpoint/trace 工作保持 ready，顺序可由集成者调整。

## 集成说明

集成者应 cherry-pick `f2c750aadd28d7a2dacb82e11e95975cad774d9b`，在合并 SHA 上重跑
evidence 中的 L0/L1 命令；确认通过后将任务 JSON 从 `active/` 移至 `archive/`，补齐
`merge_sha`，再释放该任务写集。
