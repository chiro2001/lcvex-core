# Handoff T-20260902-030: EMIF async FIFO gray pointer setup/hold closure (round2)

```text
task=T-20260902-030
state=review
base=896fc46fb4c18d85c0a91c3844c27cd7c0298cbd
head=000c5424a3ed8b2cbed4cdcb39958f2913ce7802
branch=fix/T-20260902-030-emif-async-fifo-gray-cdc2
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-030
sent_at=2026-09-03T19:20:30+08:00
received_at=2026-09-03T19:21:00+08:00
reported_at=2026-09-03T19:26:00+08:00
```

## 结论

继续闭合 T-20260902-028 指出的 EMIF async FIFO 灰码跨域 setup/hold：
- 将 adapter 内 `lcvex_async_fifo_cdc` 的 Gray 指针从“二进制指针的组合 Gray 别名”
  改为**各源域独立的 Gray 计数器**。源域采样给目的域同步器的仍是
  `wr_ptr_gray_q` / `rd_ptr_gray_q` 寄存器，但 RTL 中不再存在
  `rd_ptr_bin_q -> rd_ptr_gray_wr1_q` 或 `wr_ptr_bin_q -> wr_ptr_gray_rd1_q`
  的组合路径。
- 所有指针/同步器寄存器增加 `keep/preserve/dont_retime/dont_merge/noprune`
  组合属性，阻止综合把源域 Gray 寄存器重定时/合并进目的域首级同步器，
  也阻止首级同步器被反向合并。
- SDC 补齐双向四个 first-stage 灰码 crossing 的 `set_false_path` 与
  `set_max_delay`，覆盖 T-028 缺失的
  `request_fifo wr_ptr_gray_q -> wr_ptr_gray_rd1_q`
  和 `response_fifo rd_ptr_gray_q -> rd_ptr_gray_wr1_q`。
  这些约束只命名正确的源域 Gray 寄存器到目的域首级同步器，不掩盖
  二进制指针直接驱动首级的错误路径。

功能语义不变：FIFO 深度/接口/复位/空满/数据路径不变；B2 AXI4→Avalon
SV regression 通过。

## 改动摘要

1. `rtl/lcvex_axi4_avalon_adapter.sv`
   - `lcvex_async_fifo_cdc` 中新增 `gray_inc`，Gray 指针不再由
     `(bin_next >> 1) ^ bin_next` 组合生成；每个源域 Gray 寄存器只依据
     自身 Gray 值递增（Gray→binary→+1→binary→Gray），因此 CDC 发射点与
     二进制指针隔离开。
   - 全部 8 个指针/同步器寄存器从仅 `keep` 扩展到
     `keep + preserve + dont_retime + dont_merge + noprune`。

2. `fpga/catapult_a10/quartus/catapult_a10.sdc`
   - 补齐 `request_fifo|wr_ptr_gray_q -> wr_ptr_gray_rd1_q` 和
     `response_fifo|rd_ptr_gray_q -> rd_ptr_gray_wr1_q` 的 false path；
   - 为四个方向的 Gray 首级 crossing 均保留 2 ns manual-review max_delay。

3. `docs/handoffs/T-20260902-030-emif-async-fifo-gray-cdc2.md`
4. `docs/tasks/evidence/T-20260902-030.json`

## 验证

- `make compile`：PASS
- `fpga/catapult_a10/tools/lint_soc.sh`：PASS（`LCVEX_CATAPULT_A10_SOC_LINT_PASS`）
- `fpga/catapult_a10/tools/lint_platform.sh`：PASS（`LCVEX_CATAPULT_A10_SKELETON_LINT_PASS`）
- B2 AXI4→Avalon SV regression：PASS（`PASS: B2 AXI4/Avalon SV regression writes=0 reads=0`）
- `git diff --check`：PASS
- 未运行：完整 Quartus/Qsys synthesis/fitter/signoff STA、TimeQuest Report CDC、
  assembler/SOF、FP-P5；应由集成者在合并 SHA 上重跑确认 EMIF setup/hold 闭合。

## 已知限制 / 下一步

1. 未做真实 post-fit STA；本任务只完成 RTL/SDC 静态硬化与 Verilator 回归。
2. 若后续 Quadus synthesis 仍显示 `rd_ptr_bin_q -> rd_ptr_gray_wr1_q`
   或 `wr_ptr_bin_q -> wr_ptr_gray_rd1_q`，说明综合未尊重 keep/preserve，
   需进一步把 Gray 发射寄存器/首级同步器拆为独立子模块做物理隔离。
3. 下一步：集成者合并后在原 FP-P5 source/QSF/SDC 基线上重跑
   synthesis→fitter→signoff STA，重点看 EMIF `core_usr_clk` setup 和
   `sys_clk_50` hold 的灰码路径是否转非负；同时继续处理 T-028 指出的
   `mmu|fault_fsc_r` 同域 sys_clk_50 setup 长链。
