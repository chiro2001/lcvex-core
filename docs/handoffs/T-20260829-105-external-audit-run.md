# Handoff T-20260829-105: 外部静态审计执行

## 元数据

- task: T-20260829-105
- parent: T-20260829-104
- state: review
- base_sha: `2edc7573551bcd8e7ab2408858d011aed58fed2c`
- result_head_sha: `dd4add4a80890c6084a45258fe7f8df5970668bc`
- branch: `verify/T-20260829-105-external-audit-run`
- worktree: `/home/chiro/projects/mycpu/lcvex-wt-T-20260829-105`
- sent_at: `2026-08-29T22:49:29+0800`
- received_at: `2026-08-29T22:49:29+0800`
- reported_at: `2026-08-29T23:14:51+0800`
- evidence: `docs/tasks/evidence/T-20260829-105.json`

## 目标与边界

按 `docs/audit/` 材料包的 9 个方向，对当前基线做独立审计。用户在执行中将口径
调整为“静态审计优先，不主动运行动态回归”；因此最终结论来自源码、测试设计、
任务/evidence、Git 历史、构建/CI/Gate 入口和平台约束的静态核验。

- 未修改 RTL、testbench、sim、QEMU、FPGA、Makefile、CI 或参考结果。
- 未启动 Quartus、远端实验、Gate D、长 Linux、多核锁步或板测。
- 未读取/复制密码、私钥、license 内容或其他敏感信息。
- 未访问或修改其他任务的 worktree、构建现场和失败现场。

## 结果

结果提交 `dd4add4` 包含：

- `docs/audit/external-results/README.md`
- `docs/audit/external-results/findings.md`
- `docs/audit/external-results/action-items.md`

共 9 条 finding：高 1、中 6、低 2。高严重项 `EXT-05-003` 指出 Gate D 在
baremetal-C 工具链缺失时可静默跳过并仍返回全绿；该路径必须在下一次发布 Gate
前关闭。

其余发现：

- `EXT-01-001`：done 任务 evidence 未定稿，T-104 head/merge/artifact 不一致。
- `EXT-01-002`：T-099/T-104 时间线逆序或晚于承载提交。
- `EXT-02-001`：QEMU patch combined SHA256 无法按内容串接复算。
- `EXT-03-001`：async FIFO CDC/公共异步 reset 缺完整仓库约束。
- `EXT-05-001`：T-099 Gate 产物只有 worktree build URI，retention 已到期。
- `EXT-05-002`：ci-difftest/nightly 前置失败未纳入 fail 状态。
- `EXT-04-001`：logical ROR 已实现，但审计摘要仍写为 blocked。
- `EXT-05-004`：test registry 未登记后续 P7、多核、FPGA/CDC 入口。

06 多核和 08 安全边界没有发现超出材料已披露范围的新问题。已知的 checkpoint
v4、C3/C4、B5 full flow、FP 综合、CORE_COUNT=1 回归、Gate F-BOARD 等限制没有
重复包装成新 finding。

## 执行记录

静态机器检查通过：工具版本、117 行 V82 manifest、22 项 registry schema、50 个
FPGA 平台文件 hash、skeleton、任务 JSON 语法、敏感形态/大文件扫描。

用户调整口径前发生的动态记录：

- `make compile` 在 `MemoryMax=15G`、`MemorySwapMax=0`、`CPUQuota=600%` 下 PASS，
  Verilator 5.050，约 26.6 秒、报告分配 386.9 MB。
- `make test` 在同一限制下启动；完成 core smoke 后，在 backpressure build 开始时
  按新口径中止，exit 130。它没有总体结果，不能作为 PASS 或 FAIL 证据。
- Catapult skeleton lint 产生完整 Verilator report，但外层会话没有取得最终退出码，
  记录为 inconclusive，不进入审计结论。

精确命令、日志 hash、结果文档 hash 和限制见 evidence JSON。

## 动态移交

`findings.md` 第 6 节列出 DYN-01 至 DYN-08。应由原领域 Agent 另立任务执行，重点是：

1. 当前固定 SHA 的 `make test`、Gate D 与 CORE_COUNT=1 回归。
2. checkpoint v4 QEMU/DUT 联合恢复。
3. TimeQuest/Report CDC、复位释放和 calibration/in-flight 压力。
4. Gate/CI 缺工具、前置失败和陈旧产物的负向测试。
5. QEMU fresh replay/canonical combined hash 与 Gate artifact 取回。
6. B5 full flow、DDR 和板级门。

## 集成注意

- 集成者合入结果后，更新 `docs/tasks/active/T-20260829-105.json` 的状态、真实
  `merge_sha` 和 integrator review，并补 evidence 的合并复核记录。
- action item 需要修复时新建内部任务；不要直接在 external-results 中修改功能代码。
- T-104/T-099 的历史证据纠错使用新的 correction record，不覆盖已归档 handoff。
