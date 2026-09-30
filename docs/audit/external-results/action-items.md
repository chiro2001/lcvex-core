# 外部审计 Action Items

> 来源：T-20260829-105 静态审计
> 基线：`2edc7573551bcd8e7ab2408858d011aed58fed2c`
> 详细依据：[findings.md](findings.md)

## 字段说明

| 字段 | 说明 |
| --- | --- |
| ID | `EXT-<方向编号>-<序号>`，例如 `EXT-03-001` |
| 方向 | 01-governance / 02-reproducibility / ... / 09-risks |
| 严重级别 | 高 / 中 / 低 / 信息 |
| 状态 | open / in-progress / resolved / wontfix / external-clarify |
| 发现 | 一句话描述 |
| 证据引用 | 仓库路径 / handoff / evidence / 外部报告 |
| 建议动作 | 具体下一步 |
| 复现/验证 | 静态复核命令或后续动态验收方式 |
| 负责人 | 内部或外部 |
| 截止/备注 | 日期或备注 |

## 当前列表

| ID | 方向 | 严重级别 | 状态 | 发现 | 证据引用 | 建议动作 | 复现/验证 | 负责人 | 截止/备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| EXT-05-003 | 05-verification | 高 | resolved | Gate D 缺交叉工具链时跳过 baremetal-C 仍可全绿，toolcheck 又检查了不同 GCC | `docs/handoffs/T-20260829-106-aud-01.md`、`docs/tasks/evidence/T-20260829-106.json` | 发布模式强制 baremetal-C；统一并固定 GCC/objcopy toolchain | 原 Agent 在隔离 PATH 下做缺工具负测，必须非零退出 | T-20260829-106 | 2026-08-30 resolved |
| EXT-01-001 | 01-governance | 中 | resolved | 多个 done 任务 evidence 未定稿；T-104 head/merge/artifact hash 互相不一致 | `docs/tasks/evidence/T-20260829-104.json`、`docs/tasks/active/T-20260829-104.json`、`docs/tasks/TASKS.md` | 新建 correction record，补 result head、merge、artifact hash | `git ls-tree 5f78319 docs/audit`；核对 `4214a5e/8e3bfb5` | T-20260829-113 / T-20260830-025 | 2026-08-30 resolved；T-104/T-099 evidence 已定稿并保留修正记录；历史 handoff 未改写 |
| EXT-01-002 | 01-governance | 中 | resolved | T-099/T-104 的 dispatch/run/review/commit 时间逆序 | T-099/T-104 active/evidence 与 `git show -s --format=%cI` | 分离事件时间/回填时间并加单调性校验 | 检查 `review >= dispatch`、`run >= dispatch` | T-20260829-114 / T-20260830-025 | 2026-08-30 resolved；点名记录已修正，脚本继续暴露其他历史残留 |
| EXT-02-001 | 02-reproducibility | 中 | resolved | QEMU patch 组合 SHA 曾不可复算（12 patch） | `docs/audit/02-reproducibility.md`、`docs/handoffs/T-20260830-023-aud-13-fix.md` | AUD-06+ AUD-13FIX 重生成 13-patch canonical 集并验证干净 replay/构建/锁步 | canonical `b6b820249650b92ec9842da4e6492bdc8fb5dc12e2f2fc1ed0090069294e1119` | T-20260830-023 | 2026-08-30 resolved |
| EXT-03-001 | 03-rtl-quality | 中 | open | 两组 async FIFO 的 CDC/公共复位静态设计与约束已补（每域复位同步）；TimeQuest/Report CDC 与板级复位压力仍待 | `rtl/lcvex_axi4_avalon_adapter.sv`、`rtl/lcvex_async_fifo.sv`、`fpga/catapult_a10/quartus/catapult_a10.sdc`、`docs/handoffs/T-20260830-026-ext-03-fix.md`、`docs/tasks/evidence/T-20260830-026.json` | 补 CDC/reset 设计与约束，保存 Report CDC/STA；执行 post-fit TimeQuest 复核真实时钟/寄存器名 | 原 FPGA Agent 跑 TimeQuest/Report CDC、reset/calibration 压力 | EMIF/FPGA owner | 阻塞 Gate F-MEM/F-BOARD；静态部分已由 T-20260830-026 交付，动态验证未完成 |
| EXT-05-001 | 05-verification | 中 | resolved | T-099 Gate 产物仅指向 task worktree `build/`，retention 已到 review complete | `docs/tasks/evidence/T-20260829-099.json:96`、`docs/evidence/artifacts/T-20260829-099/` | 迁移关键日志/manifest 到持久 artifact root | 已取回并逐项核对 SHA256 | T-20260829-110 | 2026-08-30 已持久化小日志/摘要/哈希，大产物保留可重建引用 |
| EXT-05-002 | 05-verification | 中 | resolved | ci-difftest/nightly 前置 apply/build/image 失败未纳入 fail 状态 | `docs/handoffs/T-20260829-112-aud-07.md`、`docs/tasks/evidence/T-20260829-112.json` | 所有前置步骤 fail-fast/进入 run_step，隔离陈旧产物 | 原 CI Agent 注入前置失败并验证非零退出 | T-20260829-112 | 2026-08-30 resolved |
| EXT-04-001 | 04-isa-architecture | 低 | resolved | 审计摘要把已实现 logical ROR 误写为 blocked | `docs/handoffs/T-20260829-116-aud-11.md`、`docs/audit/04-isa-architecture.md` | 更新 04/self-assessment/manifest 摘要 | 静态核对 BASE-DP-018、decode、SV/Cocotb 路径 | T-20260829-116 | 2026-08-30 resolved |
| EXT-05-004 | 05-verification | 低 | resolved | test registry 缺 P7、多核、FPGA/CDC 已有入口 | `docs/handoffs/T-20260829-115-aud-10.md`、`docs/tasks/evidence/T-20260829-115.json` | 补入口并增加与 Makefile/runner 的反向检查 | `rg -n 'p7\|fp\|neon\|cluster\|cdc' scripts/test_registry.json` | T-20260829-115 | 2026-08-30 resolved；registry 明确为部分清单 |

## 后续状态补充（2026-08-30）

- 表中已标记 `resolved` 的项：
  - `EXT-05-003`：Gate D baremetal-C 假绿/工具链检查，由 T-20260829-106 修复并
    通过负测。
  - `EXT-05-002`：CI 前置失败 fail-fast，由 T-20260829-112 修复并通过 9 个负向场景。
  - `EXT-02-001`：QEMU patch canonical/fresh replay，由 T-20260830-023 完成。
  - `EXT-05-001`：Gate D 产物持久化，由 T-20260829-110 完成。
  - `EXT-04-001`：ROR 文档纠错，由 T-20260829-116 完成。
  - `EXT-05-004`：test registry 补全/反向检查，由 T-20260829-115 完成，
    registry 明确为部分清单。
  - `EXT-01-001`：T-104/T-099 evidence 定稿与 correction record，由
    T-20260829-113/114 提供 correction、T-20260830-025 回填并保留旧值完成。
  - `EXT-01-002`：T-099/T-104 时间戳逆序修正与单调性校验脚本，由
    T-20260829-114 定义/实现、T-20260830-025 回填并验证完成。
- 外部审计 DAG 中的 `AUD-12`（checkpoint v4 联合恢复）已由 T-20260829-117
  关闭：QEMU/DUT `-incoming` + `CONTEXTIDR_EL1` 对齐 PASS。
- `AUD-13`（QEMU fresh replay）初查未通过，随后由 T-20260830-023 以 13-patch
  canonical 集完成干净 replay/build/锁步修复；`AUD-13` 与 `EXT-02-001` 均已关闭。
- `AUD-14`（B5 full flow / DDR / 板级）仍为 proposed/open，受 FPGA-F3/F4 blocked
  与外部主机资源限制。
- 仍保持 open 的项：`EXT-03-001`（静态约束已补，TimeQuest/板级动态验证仍待）、
  以及原表中未列出的外部/后置项。EXT-01-001/002 虽然 action item 状态已为
  resolved，但历史 live 台账中仍有其他 evidence/时间戳不一致，作为已知残留
  由后续 evidence-finalization/timestamp cleanup 任务继续处理，不在本次审计
  action item 中重新打开。本补充仅记录已由内部任务证据确认关闭的项。

> 上述状态只表示审计处置状态。任何实现、回归或关闭动作都必须在本目录之外登记
> 内部任务，并以新的 handoff/evidence 证明；不得在本表中直接宣称未经验证的修复。
