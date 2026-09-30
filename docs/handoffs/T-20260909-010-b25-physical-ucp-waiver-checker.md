# T-20260909-010：B25 physical UCP waiver checker 交接

```text
task=T-20260909-010 state=implementation-complete acceptance_status=pass-integrator-corrected-hermetic-ucp-reset-waiver-contract
base=fcb61cb9ebff2f389f43b0f0a3973d9314176779 head=cebb871a3b6ffa362a6e7c1fb5877f36fce4190d
source_branch=infra/T-20260909-010-b25-physical-ucp-waiver-checker source_head=daf0104a77d9988da7dbc50a53225490d01950e1
integration_branch=batch/T-20260907-037-b25-bringup
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-037
batch=T-20260909-011
sent_at=2026-09-09T12:48:32+08:00 received_at=2026-09-09T12:48:32+08:00
reported_at=2026-09-09T13:24:34+08:00 timezone=Asia/Shanghai
files=fpga/catapult_a10/physical_waivers.json,fpga/catapult_a10/tools/check_physical_waivers.py,fpga/catapult_a10/tools/run_physical_waivers_fixture.py,docs/tasks/evidence/T-20260909-010.json,docs/handoffs/T-20260909-010-b25-physical-ucp-waiver-checker.md
tests=py_compile；structured positive inventory；18 negative fixtures；hermetic cwd invocation；git diff --check
blockers=none for this local checker；physical Quartus/STA sign-off remains outside scope
next=integrator 在 T-20260909-011 合并 SHA 复跑 checker 与 synthetic matrix
evidence=docs/tasks/evidence/T-20260909-010.json
```

## 交付结论

`fpga/catapult_a10/physical_waivers.json` 将 T-007 的物理 waiver 收敛为 schema v1
合同。`check_physical_waivers.py` 只读取 policy 和显式传入的结构化 inventory；它不
解析 Quartus 文本报告、不打开 fitted database、不访问 DUT 输出、不调用网络或依赖
调用者的当前目录。

checker 对以下内容 fail-closed：

- inventory provenance 必须精确绑定 T-007 冻结 physical source
  `702bd8ee5295efe8a2ad9e094d6c12471a1d3089`，不能把其它 fitted DB 的相似计数
  冒充本次 waiver 证据；JSON object 中的重复 key 也会被拒绝。
- unconstrained clocks 必须精确为 `altera_reserved_tck` 与
  `soc|emif_adapter|emif_rst_sync1_n`；ports 必须精确为
  `altera_reserved_tdi`/`altera_reserved_tms`（input）和
  `altera_reserved_tdo`（output）。输入为 2 ports/63 paths，输出为 1 port/4 paths，
  每个端口的 path group 和计数也逐项闭合。
- JTAG path hierarchy 只能落在 `alt_jtag_atlantic`、`auto_fab_0|alt_sld_fab_0`
  或 EMIF `jtag_phy_embedded_in_jtag_master` vendor pattern；三类 vendor hierarchy
  均必须实际出现。reserved TDO loop 只允许其专用 path class。
- `altera_reserved_tck` 不允许 arbitrary period 或 `create_clock`。policy 不会把
  cable-driven TCK 伪造为固定功能时钟。
- `soc|emif_adapter|emif_rst_sync1_n` 必须标为
  `synchronized_active_low_reset_control`。fast/slow 两个 corner 的 recovery 和
  removal 各自必须为 627 paths、0 violations，且 `worst_slack_ns > 0`；policy 记录
  baseline recovery/removal slack 为 1.202/0.191 ns。整个 waiver inventory 的
  `exceptions` 必须精确为空；任何 reset false-path 或其它未审计例外均拒绝。

## Synthetic 验证

`run_physical_waivers_fixture.py` 在被 `.gitignore` 忽略的
`build/agents/T-20260909-010/physical-waivers-fixture/` 生成独立 inventory，并从
fixture 目录启动 checker。正例返回 exit 0；下列 18 个负例全部返回 exit 1：

`extra-user-clock`、`extra-user-port`、`extra-user-path`、`input-path-count-change`、
`missing-emif-vendor-hierarchy`、`missing-alt-jtag-hierarchy`、
`missing-auto-fab-hierarchy`、`recovery-path-count-change`、
`removal-path-count-change`、`zero-recovery-slack`、`negative-removal-slack`、
`arbitrary-jtag-period`、`reset-false-path`、`source-sha-mismatch`、
`unexpected-exception`、`wrong-clock-kind`、`wrong-port-direction`、
`duplicate-json-key`。

精确命令、时间戳、schema、fixture 路径和 SHA-256 见
[`docs/tasks/evidence/T-20260909-010.json`](../tasks/evidence/T-20260909-010.json)。

## 写集与边界

本任务只新增 policy、checker、task-specific fixture runner 及 evidence/handoff；未
修改 RTL、SDC、QSF、`platform_manifest.json`、`source.lock`、`SHA256SUMS`、test
registry、`TASKS.md`、`PROJECT_STATUS.md`、`ROADMAP.md`、QEMU 或其他 worktree。未
运行 Quartus、GamePC、synthesis/fitter/STA、JTAG、board、Flash 或任何物理动作。

原始实现 commit 为 `daf0104a77d9988da7dbc50a53225490d01950e1`。只读交叉审查发现冻结
SHA 未绑定、exception schema 过宽及 metadata 不一致，集成者在
`cebb871a3b6ffa362a6e7c1fb5877f36fce4190d` 修正并将 fault matrix 扩至 18 项；
证据保留了修正前后的实现 SHA、时间和重跑结果。远端 fitted-DB inventory 验证仍归
T-20260909-011，不由本任务宣称物理闭包。
