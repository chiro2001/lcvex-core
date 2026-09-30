# T-20260830-007 Disable GitHub Actions Automatic CI

## 变更
- `.github/workflows/ci.yml` 的 `on:` 改为仅 `workflow_dispatch`。
- 移除了 `push`、`pull_request`、`schedule` 自动触发。
- 保留现有 CI 脚本和手动触发能力。

## 原因
用户指令：CI 测试时间过长，已耗尽 GitHub 额度；本地测试完善，本地任务和合入已经足够可靠。

## 验证
- YAML 可解析。
- git diff --check 通过。
- 已推送 `origin/feature/p7-final`。

## 恢复方式
用户明确授权后，恢复 `push/pull_request/schedule` 触发条件即可。
