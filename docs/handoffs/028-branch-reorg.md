# LCVEX 交接文档 028：分支整理与 main 合入门槛

日期：2026-08-24（Asia/Shanghai）
前置：handoff 027（BFM）、用户确认“按推荐方案处理分支”。

## 1. 背景

`feature/commit-memory-handshake` 原为 P4/P5 的“提交包+内存握手”专题，
但已承载 R1、M2-4b/5、M3 全部进展（34+ 提交），名字与实际内容脱节；
`main` 按旧规则只收 CI 通过提交，落后 34 个提交成为过时快照；
`feature/p5a-arch-fixes` 与 `verify/p5a-hardening-tests` 的提交已全部
包含在 HEAD 历史中，属被取代的残留。

## 2. 本次变更

1. 当前开发分支更名：`feature/commit-memory-handshake` ->
   `feature/m3-isa`（本地 + 远端，历史不变）；
2. 删除已并入历史的旧分支：`feature/p5a-arch-fixes`、
   `verify/p5a-hardening-tests`（本地 + 远端，合并前已用
   `merge-base --is-ancestor` 确认）；
3. main 合入门槛更新（AGENTS.md 同步）：**本地 Gate D 全绿 + CI
   通过**；CI 未可信前以本地 Gate D 为准。阶段门（如 M3 完成）由
   feature 分支快进合并进 main，避免长期脱节；
4. 本次以阶段门身份把 `feature/m3-isa` 快进合并进 `main` 并推送。

## 3. 当前分支图（预期）

- `main` = `feature/m3-isa`（最新稳定，阶段门合并）；
- `feature/m3-isa`：唯一活动开发分支；
- 远端不再有 `commit-memory-handshake`/`p5a-*` 残留。

## 4. 后续注意

- 每个阶段结束（M3 收尾、Gate D 绿）后快进合入 main 并立即推送；
- 分支名随阶段演进可再更名（如进入 P6 前改名 `feature/pre-linux-isa`）；
- CI 成熟后把“本地 Gate D”降级为兜底门槛，恢复 CI 为主。
