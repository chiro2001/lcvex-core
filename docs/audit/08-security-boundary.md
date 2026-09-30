# 08 安全与外部数据边界

> 状态：**规则已写入多 Agent 工作流和任务 JSON；本材料包本身也只写 docs/audit +
> handoff + evidence，不读取/复制 license 或敏感信息。**

## 1. 远端写集与许可原则

| 规则 | 现状 |
| --- | --- |
| 远端任务必须限定写集 | 任务 JSON 的 `writes` 明确列出；Quartus 类任务只允许用户指定工程/实验目录和 Quartus 自身生成产物 |
| 不得修改原始工程定义 | 禁止修改原始 QSF/SDC/QPF/RTL 源码；实验用副本 |
| 不得删除未知文件 | 禁止删除或覆盖未知用户文件 |
| 不得读取/复制 license 内容 | 远程环境只验证 license 路径/工具可用性；不读取、不记录、不提交内容 |
| 不得暴露远程凭据 | 材料/evidence 不包含远程主机密码、私钥、内部权限、敏感配置 |
| 本材料包不写远程主机/内部权限 | 仅引用“远端 Quartus 主机/工程”，不展开 IP、路径、账号或口令 |

## 2. cgroup / 资源限制

- 本地重型 Verilator 必须使用 cgroup 物理内存限制 < 16 GiB，
  `systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- <command>`。
- 重型构建一次一个，`-j 1` 或受限并发；禁止无限制启动重型 Verilator。
- 本机默认 <=50% 预算，CI <=75%；Quartus/Gate/Linux 长跑进入同一重型队列。
- evidence 需记录限制方法、峰值 RSS/cpuset/资源数据。

## 3. 数据边界

- **进入 Git 的**：源码、文档、任务/evidence JSON、小型 manifest/hash。
- **不进 Git 的**：大 trace、波形、RAM、checkpoint、QEMU 构建产物、Quartus
  工程 db/output、license 文件、密码/密钥。
- 大产物只记录持久 URI、owner、retention、SHA256 和重建命令。
- 本材料包只新增：
  - `docs/audit/**`
  - `docs/handoffs/T-20260829-104-external-audit.md`
  - `docs/tasks/evidence/T-20260829-104.json`
  未修改 RTL/tb/sim/qemu、Makefile、CI 或既有任务台账。

## 4. 外部审计禁止事项

- 不要求或接收远程主机密码、license 内容、内部权限信息。
- 不通过本材料包启动 Quartus/重型 Verilator；如外部需重跑，应在授权隔离
  环境和资源限制下进行。
- 不把外部结果直接写入 RTL 或功能代码；结果应落入
  `docs/audit/external-results/`，再转内部 action items。
- 不把远端工程凭据、序列号、license 路径/内容复制到审计材料。

## 5. 与外部审计结果接收区的关系

- `docs/audit/external-results/` 是预留接收位置，和本任务 ID 绑定。
- 外部发现应使用 `action-items.md` 模板，标注来源方向、证据引用、建议动作和
  优先级，不包含敏感信息。
- 后续由内部审计负责人去重、评估、转任务；任何需要 RTL/验证修改的动作都必须
  走既有任务 DAG，不在外部审计材料中直接实现。
