# T-20260829-087 A4 OpenSynth 趋势/差分回归与阈值守卫（handoff）

## Metadata

```text
task=T-20260829-087
state=review
base=7c847561d3de3edeee0f7f8937fd3929fc101ba6
head=3a1c66e7786391d8f3cde287c72c7e986115e384
branch=feature/T-20260829-087-a4-trend-regression
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-087
sent_at=2026-08-29T08:09:00+0800
received_at=2026-08-29T08:09:00+0800
reported_at=2026-08-29T08:09:00+0800
files=docs/handoffs/T-20260829-087-a4-trend-regression.md,docs/tasks/evidence/T-20260829-087.json,fpga/opensynth/a4_trend_report.md,fpga/opensynth/a4_trend_thresholds.json,fpga/opensynth/README.md,scripts/opensynth/trend_diff.py
tests=python3 -m json.tool fpga/opensynth/a4_trend_thresholds.json; python3 -m py_compile scripts/opensynth/trend_diff.py; git diff --check
blockers=无新增阻断；不替代Quartus；不解除T-067；时间趋势为N/A
next=集成者复核；后续可把本A4阈值JSON作为首个baseline，再跑真正的时间趋势；Gate F-BOARD仍由T-067/Quartus负责
```

## 结论

- **A4 是轻量、只读的趋势/差分守卫**：脚本只读取 `a1_generic_synth_stats.json`、
  `a2_soc_stub_stats.json` 和 `a3_correlation_data.json`，输出运行间差分、输入 SHA、
  工具版本和阈值检查结果。
- **未运行任何重型综合/布局布线/Quartus/Yosys/nextpnr/Verilator**；所有工具版本均取自
  既有 A1/A2/A3 artifact。
- **A1 三个模块和 A2 boundary-stub 的两跑重复性全部通过**：指标一致、netlist SHA256
  一致。
- **A1/A2 当前统计与 A3 记录一致**，A3 记录的 A1/A2/A2-manifest 输入 SHA 未变化。
- **时间序列趋势为 N/A**：本 worktree 没有更早的 A4 快照；当前输出作为首个 A4
  baseline 保存，不编造趋势/百分比。
- **阈值只限定在代理内部不变量**：两跑确定性、A1/A2-vs-A3 一致性和输入 SHA 稳定性；
  **没有设置任何 A10 资源/Fmax 阈值**，不替代 Quartus，不解除 T-067。

## 主要产物

- `scripts/opensynth/trend_diff.py` — 可复跑 A4 轻量分析/生成脚本。
- `fpga/opensynth/a4_trend_report.md` — A4 报告（含差分表、阈值表、限制和边界声明）。
- `fpga/opensynth/a4_trend_thresholds.json` — 结构化阈值/趋势输出，可作为后续 baseline。
- `docs/handoffs/T-20260829-087-a4-trend-regression.md`
- `docs/tasks/evidence/T-20260829-087.json`
- `fpga/opensynth/README.md`（新增 A4 小节与复跑说明）

## 复跑命令

```sh
python3 scripts/opensynth/trend_diff.py \
  --base-sha 7c847561d3de3edeee0f7f8937fd3929fc101ba6 \
  --head-sha 3a1c66e7786391d8f3cde287c72c7e986115e384 \
  --branch feature/T-20260829-087-a4-trend-regression
```

以后做真正趋势时，把上一次 `a4_trend_thresholds.json` 传给 `--baseline`：

```sh
python3 scripts/opensynth/trend_diff.py --baseline fpga/opensynth/a4_trend_thresholds.json ...
```

## 阈值守卫结果概览

| ID | 状态 |
| --- | --- |
| `a1-two-run-determinism` | pass |
| `a2-two-run-determinism` | pass |
| `a1-vs-a3-consistency` | pass |
| `a2-vs-a3-consistency` | pass |
| `a3-input-hash-stability` | pass |
| `no-a10-resource-or-fmax-threshold` | pass（信息性） |
| `temporal-trend-baseline` | N/A（首次 baseline） |

## 验证

- `python3 -m py_compile scripts/opensynth/trend_diff.py`：PASS
- `python3 -m json.tool fpga/opensynth/a4_trend_thresholds.json`：PASS
- `git diff --check`：PASS
- 本任务未运行 Gate D、Yosys、P&R、Quartus。

## 限制 / 风险

- A4 不是 Arria 10 signoff，不替代 Quartus，不解除 T-067。
- A1 仍未包含 `lcvex_core`/`lcvex_l2`，所以开源代理不是完整 SoC 资源代理。
- A2 是 0-cell 边界 stub，不代表真实面积；ECP5 失败使 Fmax 仍为 N/A。
- 当前只有一份 A4 快照，时间趋势是 N/A；不要把 run-to-run 重复性当作性能趋势。
- 阈值失败只应阻止 proxy 合入/标注漂移，不能作为 A10 放行依据。

## Next

- 集成者复核。
- 后续若 A 线继续，可以把本 JSON 作为 baseline，对比后续 A1/A2 变化，生成真正的
  时间差分/阈值结论。
- Gate F-BOARD 仍由 T-067/Quartus/板级负责。
