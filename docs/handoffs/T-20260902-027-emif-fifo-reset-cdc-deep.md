# Handoff T-20260902-027: EMIF FIFO/reset CDC deep fix

```text
task=T-20260902-027
state=review
base=87354542f502e1ec74971b5d63435e9590601b89
head=5eb36e93ac99731d7a0df2cb60fc8de20c288169
branch=fix/T-20260902-027-emif-fifo-reset-cdc-deep
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-027
sent_at=2026-09-03T13:18:30+08:00
received_at=2026-09-03T13:18:35+08:00
reported_at=2026-09-03T14:10:00+08:00
```

## 结论

继续闭合 T-20260902-025 指出的 EMIF↔sys 异步 FIFO/复位同步器真实 CDC 问题：

1. **灰码跨域 hold**
   - 在 adapter 文件内新增 `lcvex_async_fifo_cdc` 硬化异步 FIFO，替代仅靠
     外部只读 `lcvex_async_fifo.sv` 的实例化。两套 FIFO 的指针/同步器
     寄存器均加 `(* keep = "true" *)`，防止 Quartus 把源域 Gray 寄存器
     重定时/合并到目的域首级同步器；源域已寄存的
     `rd_ptr_gray_q` / `wr_ptr_gray_q` 仍是唯一被跨域采样的指针值。
   - CPU 响应 FSM 不再直接消费 response FIFO 的 `is_write/id/resp`
     控制字段；只取必要的 512-bit 读数据。写/读响应类型由本域
     `txn_write_q` 决定，响应 code 固定为 Avalon 无错误语义下的 OKAY，
     从而切断 `response_fifo mem -> cpu_state/read_beat` 的组合路径。

2. **复位同步器 recovery**
   - 将每域复位释放链改为“本地异步断言 + 远端复位数据两拍同步”：
     CPU 侧首级 async reset 只用 `cpu_rst_n`，EMIF 侧首级 async reset
     只用 `emif_rst_n`；另一域复位作为普通数据进入本域两拍链。
   - 因此 `logic_rst_n_q` 不再直接驱动 EMIF 域 `emif_rst_sync*` 的
     async reset 引脚，recovery/removal 不再是 sys→EMIF 跨域路径；
     `emif_fsm_rst_n`/`emif_fifo_rst_n` 由 EMIF 域本地产生的同步器输出
     驱动，继续保持公共复位/epoch 清空语义。
   - SDC 增加一条 guarded false path，切断 `logic_rst_n_q` 到 EMIF 复位
     同步器首级数据输入的新 CDC 首级路径（async reset 保持 local）。

功能语义不变：校准失败仍本地 DECERR；复位后 FIFO/FSM 清空；Avalon
协议/持有/读延迟/重复响应回归通过。

## 改动摘要

1. `rtl/lcvex_axi4_avalon_adapter.sv`
   - 删除公共 `cpu_domain_rst_n` 作为两域 async reset 的用法。
   - FSM/FIFO 各两套复位同步器改为 local async reset + remote data sync。
   - request_fifo/response_fifo 改用本文件内新增的
     `lcvex_async_fifo_cdc`（Gray 指针 + keep + 同接口）。
   - CPU_WAIT_RESPONSE 仅从 response FIFO 取 readdata；不再用 FIFO
     is_write/id/resp 驱动 CPU FSM。

2. `fpga/catapult_a10/quartus/catapult_a10.sdc`
   - 增加 `logic_rst_n_q -> emif_rst_sync0_n*` 的 first-stage false path，
     配合 RTL 复位桥。

3. `docs/handoffs/T-20260902-027-emif-fifo-reset-cdc-deep.md`
4. `docs/tasks/evidence/T-20260902-027.json`

## 验证

- `make compile`：PASS
- `fpga/catapult_a10/tools/lint_soc.sh`：PASS（`LCVEX_CATAPULT_A10_SOC_LINT_PASS`）
- `fpga/catapult_a10/tools/lint_platform.sh`：PASS（`LCVEX_CATAPULT_A10_SKELETON_LINT_PASS`）
- B2 AXI4→Avalon SV regression：PASS（`writes=0 reads=0`）
- `git diff --check`：PASS
- 未运行：完整 Quartus/Qsys synthesis/fitter/signoff STA、TimeQuest Report CDC、
  assembler/SOF、FP-P4/FP-P5；这些应由集成者/后续 physical 任务在合并 SHA 上重跑。

## 已知限制 / 下一步

1. 本地只做 RTL/SDC 静态修复与 Verilator 回归；未做真实 post-fit STA。
2. 新增 `lcvex_async_fifo_cdc` 位于 adapter 文件内，未修改只读
   `rtl/lcvex_async_fifo.sv`；若后续审计要求统一 FIFO 实现，可在单独任务
   合并该硬化版本。
3. 下一步：集成者合并后在原 FP-P5 source/QSF/SDC 基线上重跑
   synthesis→fitter→signoff STA 和 FP-P4；确认 `emif core_usr_clk`
   hold/recovery、`sys_clk_50` 相关 CDC 路径转正后才允许 assembler/SOF。
