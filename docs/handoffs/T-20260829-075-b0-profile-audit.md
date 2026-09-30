# T-20260829-075 B0 V82 非 SVE Profile 审计 handoff

- 状态：review（owner 交付完成，等待集成者 G1/profile 批准）
- 任务 ID：T-20260829-075（B0）
- base SHA：`3d6fdfc4bfde7d9a0ebeb3609badffbdaa0bf6a2`
- head SHA：`a4050c002087582fd74bfc82cb904cb44eefffcb`
- 分支：`feature/T-20260829-075-b0-profile-audit`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-075`
- sent_at：2026-08-29T01:47:44+0800
- received_at：2026-08-29T01:52:29+0800
- reported_at：2026-08-29T01:52:29+0800

## 交付物

| 文件 | 说明 |
| --- | --- |
| `docs/V82_PROFILE_MANIFEST.md` | 机器可检查 V82 非 SVE profile 清单（内嵌 JSON） |
| `scripts/v82_profile_check.py` | 清单生成/校验器；内置同一份权威 ROWS |
| `docs/ISA_SCOPE.md` | 仅修正 FP/NEON 过时表述并增加 manifest 指针 |
| `docs/ISA_GAPS.md` | 仅修正“P7 全缺”过时表述并增加 manifest 指针 |
| `docs/tasks/evidence/T-20260829-075.json` | 证据 JSON |

## 清单概要

- 总行数：117
  - V82-BASE：68（66 implemented，1 udef，1 blocked）
  - V82-SELECTED-EXT：28（27 implemented，1 blocked）
  - V82-SVE-EXCLUDED：5（1 shim，4 deferred）
  - POST-V82-DEFERRED：16（7 shim，9 deferred）
- 状态分布：
  - implemented：93
  - shim：8
  - udef：1
  - blocked：2
  - deferred：13
- blocked 行：
  - `BASE-DP-018`：logical shifted-register ROR（B1 标量闭合候选）
  - `EXT-FP-012`：scalar FP16 `LDR/STR H`（P7-5 明确不实现，待 B2 决策）
- 每行均有 `qemu_oracle` 字段；blocked/deferred 行均有明确 notes。

## 审计边界

- 未新增任何指令实现、RTL、QEMU 补丁或顶层 Makefile 修改。
- 不把 shim/deferred 计入完成度；不把 Linux 动态观察当作静态完整支持。
- 数据源包含 ISA_SCOPE/ISA_GAPS/P7 协议文档、RTL 测试名、QEMU 11.1.0
  锁步/探针证据和现有测试程序命名。未生成新的 QEMU 系统寄存器全量 JSON
  （现有 probe 入口可作为后续 B3 输入）。

## 已执行校验

```text
python3 -m py_compile scripts/v82_profile_check.py
python3 scripts/v82_profile_check.py --emit-manifest docs/V82_PROFILE_MANIFEST.md
python3 scripts/v82_profile_check.py --validate-manifest
python3 scripts/v82_profile_check.py --summary
```

结果：manifest 生成成功、嵌入 JSON 与内置 ROWS 一致、117 行校验通过。

## 阻断 / 不适用

- 无实现层面阻断。
- 外部等待项：集成者批准 V82 profile（G1）后方可进入 B1 实现任务。

## 下一步

1. 集成者复核 manifest/校验器并批准 profile。
2. B1 可基于 `BASE-DP-018` 与 `EXT-FP-012` 决定是否补实现/后置。
3. B3 可用 `scripts/qemu_sysreg_inventory.py` 进一步细化系统寄存器 oracle。
