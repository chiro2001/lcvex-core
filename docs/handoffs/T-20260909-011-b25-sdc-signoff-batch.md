# T-20260909-011：B25 SDC signoff batch 交接

```text
task=T-20260909-011 state=done acceptance_status=local-union-and-isolated-fitted-overlay-pass
base=fcb61cb9ebff2f389f43b0f0a3973d9314176779 candidate=4618c17f85a3a84f28824a9d5964d8600c3d966d
remote_overlay_sha=17faa2b9cbc746290963d078985e115574d54088 physical_source_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089
branch=batch/T-20260907-037-b25-bringup worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-037
reported_at=2026-09-09T14:26:32+08:00 timezone=Asia/Shanghai
evidence=docs/tasks/evidence/T-20260909-011.json
next=one final fresh synthesis/fitter/STA; no assembler, configuration or board action
```

## 结论

B25 的三个物理 blocker 已在独立 fitted-DB clone 上收口：六组 FIFO payload CDC
路径被精确切除，真实剩余 hold WNS 为 `+0.018 ns`；四个 operating corner 的五组
`set_data_delay 2.000` 共 20 组全部 0 violation，最差 slack 为 `+0.927 ns`；两个
unconstrained clock 及 reserved JTAG I/O 由冻结 source SHA、精确 hierarchy/count 和
627/627 recovery/removal 正 slack 的结构化 waiver 覆盖。

合并后的 SDC 为 14,384 bytes，SHA-256
`7ab96f705ffc81d1046d23ce704c0c55f0a8df7c1bd4c137b2ae13fe421eebd5`，manifest 与
`SHA256SUMS` 已同步。父 SHA 上的静态/fault matrix、SV/SVA、Cocotb 7/7、平台骨架和
哈希闭包全部通过。

## 物理结果

- `sys_clk_25`：setup `+7.949 ns`、hold `+0.018 ns`、recovery `+13.596 ns`、
  removal `+0.187 ns`；min-pulse `+0.120 ns`，均 0 violation。
- data-delay 最差点是 Slow 900 mV 100 °C 的 poison crossing，slack `+0.927 ns`；
  四组 Gray crossing 每个 corner 都是 3 paths，poison 是 1 path，均有 2 ns datapath
  marker。
- UCP fast/slow 都只有 `altera_reserved_tck` 与
  `soc|emif_adapter|emif_rst_sync1_n` 两个目标；TDI/TMS/TDO 路径数为 26/37/4。
- 实际报告导出的 inventory 通过 hardened T-010 checker；inventory SHA-256 为
  `b42e16f6de2bc40620122bdca9111c1cd4e5fa60be7d9b03a61caf6b7afde9f8`。

全部远端操作都持有 `gamepc` 锁。冻结 T-002 源树查询前后 manifest 同为
`3d54e392aa3e7dd0620b6b7a45824b69f2baa6dcd135880fa019afdca09595d2`，0 行变化；
Quartus 的 report-only 查询只改写可丢弃 scratch clone 内的 report/cache 行。未运行
synthesis、fitter、assembler、`quartus_pgm`、JTAG、板卡配置或 Flash，也未生成
SOF/JIC/RBF/POF。

## 仍需完成

本批是对冻结 fitted netlist 的 SDC overlay 验证，不替代 fresh compile。下一步应在
新任务/新远端 probe 上，以最终 candidate 运行一次 synthesis → fitter → STA，并复用
本批 checker 做验收；仍不得进入 assembler 或上板。正式 SDC 中另有历史遗留的
reset/EMIF broad ignored/invalid rows，本批没有新增或扩大它们，五条目标 CDC bound
均已单独证明 Complete/non-ignored；后续物理清理应继续对这些历史行做精确 inventory。
