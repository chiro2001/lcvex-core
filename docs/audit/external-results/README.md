# 外部审计结果接收区

> 任务：T-20260829-104（external-audit）
> 用途：外部审计结果、外部证据、发现与 action items 将落入此目录，并保持同一
> 任务编号，便于后续去重、评估和转内部任务。
> 审计执行任务：T-20260829-105（父任务 T-20260829-104）
> 审计基线：`2edc7573551bcd8e7ab2408858d011aed58fed2c`
> 审计方式：静态审计优先；动态回归列为可选移交项

本目录已接收第一轮独立静态审计结果。结果不构成 Arm 架构认证、DO-254、
ISO 26262 或产品级签核，也不替代 Gate D、Quartus、板测和长 Linux 回归。

## 当前结果

| 文件 | 内容 |
| --- | --- |
| [findings.md](findings.md) | 审计基线、方法、9 个方向结论、9 条发现和动态可选移交项 |
| [action-items.md](action-items.md) | 1 高、6 中、2 低共 9 条结构化整改项 |

本轮没有修改 RTL、testbench、QEMU、FPGA、构建入口或参考结果。需要实现/修复的
条目必须另行登记内部任务，并由原领域开发 Agent 完成回归和 bug 复现。

## 使用说明

1. 外部审计方或内部审计负责人把结论写为 `findings.md`、
   `action-items.md`，或按需要添加子文件。
2. 每条发现尽量带方向编号（01–09）、严重级别、证据引用和复现/验证方式。
3. 不把远程主机密码、license 内容、私钥或其他敏感信息放入此目录。
4. 本目录不是功能代码修改区；发现需要 RTL/验证修改时，先在内部任务 DAG 中
   登记新任务，不在外部结果目录直接改代码。
5. 大文件不要直接提交到 Git；只记录 URI/SHA256/retention。

## 建议的文件命名

| 文件 | 内容 |
| --- | --- |
| `README.md` | 本说明 |
| `action-items.md` | 结构化 action item 模板/列表 |
| `findings.md` | 可选：外部审计发现的自由格式汇总 |
| `external-evidence/` | 可选：小型证据/摘要（禁止含敏感信息） |

## 接收流程

1. 收到外部结果 -> 抄送到 `external-results/` 并用时间戳记录。
2. 内部负责人逐条对照 `docs/audit/self-assessment.md` 和 `evidence-index.md`
   去重、确认严重级别。
3. 可复现的发现转为 `docs/tasks/proposed/` 或由集成者登记新任务；不可复现
   的列为待外部澄清。
4. 关闭项在 `action-items.md` 中标记状态，并在完成时写 handoff/evidence。
