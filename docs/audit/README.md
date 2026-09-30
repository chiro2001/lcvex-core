# LCVEX 外部审计材料包导航

> 任务编号：T-20260829-104（external-audit）
> 分支：`feature/T-20260829-104-external-audit`
> 仓库 SHA：`5f78319234a603f522af407e5378b7ef786fa1d1`
> 生成时间：2026-08-29T21:06+08:00（材料落盘时间，见 handoff/evidence）
> 适用方向：外部审计 9 个方向 + 外部结果接收区

本目录用于向外部审计方提供 LCVEX 当前事实快照。所有内容仅基于仓库中已有
文档、任务记录、handoff、evidence、RTL 静态浏览和已经归档的验证结果整理；
**本材料包未重新运行重型 Verilator/Quartus/Gate 回归**，也未修改
RTL/tb/sim/qemu 功能代码。

## 状态标注约定

| 标注 | 含义 |
| --- | --- |
| 完成 | 仓库中有实现/证据/已合入结果 |
| 部分 | 有实现，但仍有明确未闭合项或未完成集成/复验 |
| 未完成 | 当前没有实现或没有通过证据 |
| 风险 | 已识别但尚未解决或需要外部确认 |
| 后置 | 明确不在当前 V82 非 SVE / F 单核发布范围内 |

## 材料清单

| 文件 | 内容 |
| --- | --- |
| [01-governance.md](01-governance.md) | 任务/DAG/subagent/写集/证据链/ADR/暂停恢复/cgroup 流程现状 |
| [02-reproducibility.md](02-reproducibility.md) | 工具链、Makefile/filelist/manifest、QEMU patch hash、可复现构建、CORE_COUNT |
| [03-rtl-quality.md](03-rtl-quality.md) | RTL 结构/命名、Verilator lint、参数化、FP/NEON gate、fp_scalar 综合、资源热点、CDC/复位 |
| [04-isa-architecture.md](04-isa-architecture.md) | V82-BASE+SELECTED-EXT 矩阵、SVE/POST-V82 后置、系统寄存器/异常/权限/barrier/maintenance、QEMU 锁步绑定 |
| [05-verification.md](05-verification.md) | 测试层级、定向/随机/覆盖率、Gate D 13/13、checkpoint v4、baremetal-C、负测、失败保存 |
| [06-multicore.md](06-multicore.md) | 目录 MSI、CORE_COUNT 参数化、C2/C3/C4 状态、单事务/单 outstanding 局限、C4 baseline、ACE/CHI/SVE 边界 |
| [07-fpga.md](07-fpga.md) | Catapult A10 工程可重生成、T-064/T-067、OOM 定位、L2 writeback、fp_scalar、partition/incremental、板级未完成项 |
| [08-security-boundary.md](08-security-boundary.md) | 远端写集/许可/清理规则、cgroup 限制、数据边界、禁止事项 |
| [09-risks.md](09-risks.md) | 开放风险清单：POST-V82、SVE、EL2/EL3、RCpc、LSE128、Linux SMP、CI/main、Gate E/F-BOARD、running-reset-restart、full-core fault、CORE_COUNT=1 回归等 |
| [evidence-index.md](evidence-index.md) | 每个方向对应的证据文件/commit/handoff/evidence JSON 索引 |
| [self-assessment.md](self-assessment.md) | 每个方向现状/已做未做/已知限制/建议审计问题 |
| [external-results/](external-results/) | 外部审计结果接收区：README 与 action-items 模板 |

## 外部审计建议阅读顺序

1. 先读 `README.md`、`self-assessment.md`，了解整体成熟度和声明边界。
2. 按审计方向阅读对应 `01`–`09` 文档。
3. 需要精确命令、SHA、seed、资源和 artifact 时，跳到
   `docs/tasks/evidence/` 下的 JSON 文件；本包只做索引和摘要。
4. 外部审计发现/结论请落入 `external-results/`，使用其中的模板。

## 本材料包的边界

- 对 RTL 的观察是静态阅读和已有验证记录，不是新的形式化证明或重跑。
- 所有“完成”均指仓库文件/已有 evidence 所显示的范围，不代表完整 ARMv8.2-A、
  完整多核、完整物理板级或产品级签核。
- 不包含远程主机密码、license 文件内容、内部权限信息或敏感密钥。
- 当前主线仍为 `feature/p7-final`，正式 `main` 晋级、可信 CI、Gate E/F-BOARD
  等仍然后置。
