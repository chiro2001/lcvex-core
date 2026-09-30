# T-20260830-038 FPGA-G5：L1D/L2 cache data 显式 M20K RAM wrapper

```text
task=T-20260830-038 state=review
base=fb41e24be449394615498c2ff72257954ddf28a8 head=62ae1bd99b26de26933ff6733689831dfc8dfe93
branch=feature/T-20260830-038-fpga-cache-ram worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-038
sent_at=2026-08-30T15:10:45+08:00 received_at=2026-08-30T15:12:16+08:00 reported_at=2026-08-30T16:12:27+08:00
content_sha=08b359dae2e9dfc2230551fecb40862e20c805af evidence_sha=62ae1bd99b26de26933ff6733689831dfc8dfe93
model=gpt-5.6-luna reasoning_effort=max
followup_received_at=2026-08-30T16:14:59+08:00 followup_reported_at=2026-08-30T16:16:25+08:00
```

本次元数据纠正保留原 reported_at，并以原主动 FINAL 报告的实际时间为准：
`old_reported_at=2026-08-30T16:09:27+08:00` →
`corrected_reported_at=2026-08-30T16:12:27+08:00`。`content_sha` 是实现/技术内容
提交，`evidence_sha` 是原证据提交；最终 branch tip 以纠正后 FINAL 报告的 `head`
为准。

## 结论

- `lcvex_l1_d_wb` 与 `lcvex_l2_wb` 已移除行为级 byte-array data 阵列，统一实例化
  `lcvex_cache_data_ram`：一条 64B line 对应一个 packed 512-bit RAM word。
- Verilator/非综合路径是同步读 packed-line 行为模型；`SYNTHESIS` 路径显式实例化
  `altera_syncram`，`SINGLE_PORT`、`WIDTH_A=512`、`WIDTH_BYTEENA_A=64`、
  `RAM_BLOCK_TYPE=M20K`。RAM 内容不复位，cache metadata 的 valid/tag/dirty 是可见性边界。
- L1/L2 增加同步 data read request/wait 状态。命中读、dirty victim 写回和 probe payload
  在 `rd_valid` 后才使用 line；写命中、refill/ZVA/由 L1 下刷合并在 masked line-write
  状态采样。现有 hit/miss、dirty victim、refill fault、probe hold/abort、maintenance、
  checkpoint drain 的提交边界保持。
- L2 命中/替换选择改为按 `WAYS` 循环，消除 WAYS=1 的常量 way[1] 越界；WAYS=1/2
  均完成检查。

## 文件

- `rtl/lcvex_cache_data_ram.sv`：同步读、逐字节 line mask、M20K 显式 wrapper。
- `rtl/lcvex_l1_d_wb.sv`、`rtl/lcvex_l2_wb.sv`：cache data RAM 接入和等待状态。
- `tb/sv/lcvex_cache_data_ram_tb.sv`：整行/稀疏 byte-enable/不同地址/同步读定向 TB。
- `rtl/filelist.f`、opensynth/Catapult filelist、Catapult QSF、L1D/L2 Cocotb Makefile：
  已补齐 wrapper；L1D Cocotb 入口同时补齐 `lcvex_cluster_pkg.sv` 依赖。
- `docs/L1_COHERENCE.md`、`docs/L2_WRITEBACK.md`：记录 RAM 时序、复位和碰撞语义。

## 验证结论

以下均在 `systemd-run --user --scope -p MemoryMax=15G -p MemorySwapMax=0` 下串行执行，
Verilator 5.050，`-j 1`：

- wrapper SV TB：PASS。
- L1D-WB SV TB：PASS（10 operations，66 downstream accepts）。
- L2-WB SV TB：PASS（seed `0x05512026`，93 operations，903 accepts）。
- L2↔L1 probe/drain SV TB：PASS（11 operations，3 probes，2 drain）。
- L1D-WB Cocotb：PASS，9190 ns。
- L2-WB Cocotb：PASS，2490 ns。
- Catapult SoC lint：`LCVEX_CATAPULT_A10_SOC_LINT_PASS`。
- Catapult boot smoke：`SOC_SMOKE_ALL_PASS`（正向 JTAG/DDR 跳转及 calibration-blocked）。
- WAYS=1 参数 lint：PASS，无越界 selector warning。

精确命令、退出码、资源限制、source SHA、seed、Quartus report/hash 见
[`docs/tasks/evidence/T-20260830-038.json`](../tasks/evidence/T-20260830-038.json)。

## 远端 standalone synthesis

在 `192.168.101.5` 的隔离目录
`D:\Projects\fpga-altra\lcvex\build\T-20260830-038` 只运行 synthesis：

- L1D `SETS=64, LINE_BYTES=64`：PASS；`NUMWORDS_A=64`、`WIDTH_A=512`、
  `WIDTH_BYTEENA_A=64`、M20K Single Port、Block Memory Bits=32768、MLAB=0，
  ALM estimate=9665，报告位于 `l1d_actual\output_files\l1d_actual.syn.rpt`。
- L2 `SETS=64, WAYS=1, LINE_BYTES=64`：PASS；同样出现 M20K Single Port、
  Block Memory Bits=32768、MLAB=0，ALM estimate=9720，报告位于
  `l2s64w1_actual\output_files\l2s64w1_actual.syn.rpt`。
- Quartus 为 21.4.0 Build 67；最终远端命令退出码均为 0。Quartus 日志只给出
  peak virtual memory（L1D 751 MB、L2 819 MB），RSS 未提供，因此未作 RSS 声明。
- 曾验证 `OLD_DATA` 在 Quartus 21.4 Single Port primitive 不合法，改用合法的
  `DONT_CARE` collision mode；控制器严格串行化读写，测试和架构语义不依赖碰撞值。

## 风险与边界

- 本任务没有启动真实 SoC Quartus synthesis/fitter/STA/assembler/SOF，也没有板测；
  后续需由集成者另立授权任务复核系统级资源/时序。
- `lcvex_cache_data_ram` 的同址并发读写在 M20K 中为 `DONT_CARE`；若将来引入并发
  client 或多 outstanding，必须先重新定义 read-during-write 契约。
- data RAM 上电内容不保证为零；所有 cache 访问必须继续遵守 metadata valid 边界。

## Correction record

- `reported_at`: old `2026-08-30T16:09:27+08:00`; corrected
  `2026-08-30T16:12:27+08:00`。
- `followup_received_at=2026-08-30T16:14:59+08:00`，
  `followup_reported_at=2026-08-30T16:16:25+08:00`。
- correction commit message: `docs: correct T-038 report metadata`；纠正提交会再次改变
  branch tip，故不得将 `08b359d` 或 `62ae1bd` 称作最终 branch tip。

## 建议的集成动作

1. Cherry-pick `08b359dae2e9dfc2230551fecb40862e20c805af` 及本 handoff/evidence 提交。
2. 在合并 SHA 串行复跑 wrapper、L1D/L2/probe、Cocotb 和 Catapult lint/smoke 子集。
3. 另立任务执行真实 A10 SoC synthesis→fitter→STA→assembler；本任务不自动续跑。
