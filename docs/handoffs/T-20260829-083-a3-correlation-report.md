# T-20260829-083 A3 开源代理与 A10 基线相关性报告（handoff）

## Metadata

```text
task=T-20260829-083
state=review
base=54d1ccf0c2c67e504d5b8528eac37a249bc45221
head=2ddd7236bb801bd6d587685757f3f7d8d2b2d812
branch=feature/T-20260829-083-a3-correlation-report
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-083
sent_at=2026-08-29T03:04:00+0800
received_at=2026-08-29T03:04:00+0800
reported_at=2026-08-29T03:04:00+0800
files=docs/handoffs/T-20260829-083-a3-correlation-report.md,docs/tasks/evidence/T-20260829-083.json,fpga/opensynth/a3_correlation_report.md,fpga/opensynth/a3_correlation_data.json
tests=python3 -m json.tool fpga/opensynth/a3_correlation_data.json; git diff --check
blockers=无新增阻断；不替代Quartus；不解除T-067
next=集成者复核；A线如继续可进入A4趋势回归（可选）；Gate F-BOARD仍由T-067/Quartus负责
```

## 结论

- 本任务是 **A3 相关性报告**，只比较 A1 通用 Yosys/ABC 模块统计、A2 SoC boundary/stub 清单与 T-064 A10 真实资源/STA 的**模块占比、排序和趋势**。
- **没有做 ECP5/Yosys/ABC → A10 的线性换算**，没有生成或声称新的 A10 Fmax。
- A1 代理内部排序稳定：`lcvex_axi4_master` > `lcvex_mem_delay` > `lcvex_mem_arb`（LUT/FF 均一致）。
- A1 代理整体呈寄存器偏重、DSP 未映射、RAM 未映射；T-064 A10 fit 也显示 registers > ALMs、0 DSP，但二者单位不同，只作定性趋势。
- A2 stub 是 0-cell 边界清单（109 ports / 2627 port bits），与 A10 141 pins 不可直接比较；ECP5/nextpnr 因 IO 超限 Fmax N/A。
- T-064 A10 fit/STA 作为外部方向参考引用；A3 不替代 Quartus，不解除 T-067。

## 产出文件

- `docs/handoffs/T-20260829-083-a3-correlation-report.md`
- `docs/tasks/evidence/T-20260829-083.json`
- `fpga/opensynth/a3_correlation_report.md`
- `fpga/opensynth/a3_correlation_data.json`

## 工具版本

- A1 Yosys 0.66 / ABC 1.01
- A2 Yosys 0.68+136 / Verilator 5.050 / nextpnr-ecp5 0.11.1-18
- T-064 Quartus Prime Pro 21.4.0 Build 67
- Python 3.12.10

## 输入 SHA

见 `fpga/opensynth/a3_correlation_data.json` 与 `fpga/opensynth/a3_correlation_report.md`。关键输入为：

- `fpga/opensynth/a1_generic_synth_stats.json`: `a5c27ff87bc78a55a940326abf91155762538d645e4529b7e155cb25ad4da300`
- `fpga/opensynth/a2_soc_stub_stats.json`: `d8c66aac65b0fbdeba99e4c22a3922b59a5b0aaa042a920ca0a670e4c059db6f`
- `docs/tasks/evidence/T-20260828-064.json`: `29c18485dc2d94941c8a778601abc3380f7f23b346a2bb5aa6a7a7c29259a4e6`

## 验证

- `python3 -m json.tool fpga/opensynth/a3_correlation_data.json`：PASS
- `git diff --check`：PASS
- 本任务为只读分析，未运行 Quartus/Yosys/nextpnr。

## 限制

- A1 未包含 `lcvex_core`/`lcvex_l2`，不是完整 SoC 开源资源代理。
- A2 是 boundary stub，0-cell，不代表真实面积。
- T-064 fit 无模块级 A10 资源分解，无法验证 A10 模块排序。
- 本报告非 A10 signoff、不替代 Quartus、不解除 T-067。

## Next

- 集成者复核 handoff/evidence；A 线如需继续，进入 A4 趋势回归（可选）。
- Gate F-BOARD 仍由 T-067/Quartus/板级负责，A3 不提供放行依据。
