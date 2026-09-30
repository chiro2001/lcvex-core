# T-20260905-011：R17 FP accumulator control cut 交接

```text
task=T-20260905-011
state=review
base=4816285977748596d3ede6b72ac1e8cc5c4cd3ff
upstream_candidate=b9b1121ffc2c8fff0da9f752a4172159e8d95e62
head=final-documentation-tip (see final branch HEAD below)
implementation_head=2d0d43e737ec1d9f837c345ded90242c49d59a12
test_head=0f39b61b0a31ca5a4d905edb869618cd363263d9
test_correction_commit_at=2026-09-05T10:10:21+08:00
test_window_correction_commit_at=2026-09-05T11:20:07+08:00
branch=timing/T-20260905-011-r17-fp-acc-control-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-011
owner=codex-r17-fp-acc-cut
sent_at=2026-09-05T09:26:26+08:00
received_at=2026-09-05T09:26:26+08:00
reported_at=2026-09-05T10:15:00+08:00
files=rtl/lcvex_neon_fp.sv; sim/cocotb/test_p7_3_neon_fp.py; docs/handoffs/T-20260905-011-r17-fp-acc-control-cut.md; docs/tasks/evidence/T-20260905-011.json
next=integrator 在 T-009 完成后的 batch candidate 上运行联合 FP L0-L2，并重新执行 physical flow/STA
```

## 结论

本 lane 针对 T-008 retry3 raw top-50 中进入 `fp_exec.acc[*].ena` 的共享控制锥，完成
一个局部、等价的结构切点：`lcvex_fp_exec::TX_DONE` 响应握手后不再清除非架构
`acc/acc_flags`。响应 payload 本来就保持到下一次 `TX_DONE`，现在 accumulator/flags
也保持到下一请求；下一次 `TX_IDLE` request accept 仍在任何 slot 运行前清零，reset
和 kill 路径仍清零。

## STA 输入与精确路径

只读输入为 T-008 retry3 raw report：
`/home/chiro/projects/mycpu/lcvex-wt-T-20260905-008/build/agents/T-20260905-008/retry3/sta/extended/t008r3_sys_clk_50_setup_top50.rpt`
（SHA256 `07236136ddb69b73c2bc7e30d61e647b1738baa4e52683c90e18a26c51d594cf`）。

50 条路径全部违反 setup，时钟关系 20 ns、Slow 900mV 100C、无 SDC exception。
其中 `exmem_valid→fp_exec.acc` 18 条（slack `-4.767..-4.685 ns`），
`memwb_wb_rd[4]~DUPLICATE→acc` 3 条（`-4.706 ns`），
`exmem_wb_rd[3]→acc` 3 条（`-4.698 ns`），均为 27 logic levels。

三类路径的共同 raw chain 为：

```text
exmem_valid / memwb_wb_rd[4]~DUPLICATE / exmem_wb_rd[3]
 -> reduce_nor_229~1 或 reduce_nor_230~3
 -> gprv[22][0]~49 -> gprv[22][0]~842 -> gprv[22][0]~843
 -> decode i16159~199/~207/~208 -> Mux_5958~0
 -> shift_left_18~14 -> add_48~57/125/113/117/161/165/177/181
 -> d.mem_addr[0]~228/~398 -> LessThan_16~9/~10/~11/~14
 -> LessThan_35~1 -> i107614~3 -> d.exc_code[2]~2 -> i1060
 -> i21303~42/~43/~51 -> sys_commit_ready~0 -> i22625~0
 -> fp_rsp_ready~0 -> fp_exec i8721~2 -> fp_exec.acc[*].ena
```

RTL 中对应的共享控制是 `sys_commit -> fp_tx_kill -> fp_rsp_ready`；FP wrapper
的 `rsp_ready` 只应控制 `TX_DONE` response release，不应清除已完成的
accumulation payload。删除 TX_DONE 的两条 `acc/acc_flags` 清理赋值后，accumulator
的写点只剩 reset、kill、TX_IDLE 新请求和 TX_SLOT 非最终 slot，故该控制语义不再
由 response-ready 驱动。

## RTL 语义边界

- `TX_DONE` 在 `rsp_ready` 握手时仍转到 `TX_IDLE`、清除 `req_r`、复位
  `slot_idx/slot_result_valid`；held response 的 `rsp_r` payload 保持不变。
- `acc/acc_flags` 在 `TX_DONE` 握手后保持，属于非架构状态，不能直接产生 V/FPSR
  effect；下一次 `req_valid && req_ready` 在 `TX_IDLE` 同拍清零，再进入 `TX_RUN`。
- 异步 reset 与 `kill` 分支继续清除 state、request、response、slot capture、
  accumulator 和 flags；没有新增 latency、接口或 public typedef。
- `TX_SLOT` 的中间 slot 累加、最终 `rsp_comb`、单 outstanding、tag、response
  backpressure 和 core commit ordering 均未改动。

## 定向测试变更

`sim/cocotb/test_p7_3_neon_fp.py` 新增
`test_p7_3_accumulator_cleanup_and_consecutive_fmla`：

- restore 后先保持 `commit_ready=1`，等待 `IF/ID=FMLA (BASE+8)`、
  `ID/EX=第二条 MOVZ (BASE+4)`、`EX/MEM=第一条 MOVZ (BASE)` 的自然窗口；
  再在该窗口边沿前拉低 ready，下一拍确认 MEM/WB 与 EX/MEM 同时占用、FMLA
  已进入 ID/EX，并断言 `exmem_can_accept=0`；
- FMLA `V2.2S` 使用 `V2` 作为 `operand_c`（`1 + 2*3 = 7`），随后连续 FADD
  `V3.2S = V2 + V2`，覆盖 captured addend 和 V RAW 依赖；
- held response 期间检查 `rsp_valid`、accumulator/flags 稳定且无架构提交；
- response release 后检查 TX_DONE 不清除 acc/flags，下一 transaction 进入
  `issued` 后 acc/flags 已清零，并检查 V2/V3 raw packet。

### Review correction

初始测试提交 `0031082` 只有一条前置 `MOVZ`。T-012 的 elastic EX/MEM 语义允许
MEM/WB 背压时向空 EX/MEM 接收 FP response，因此该前置条件不能证明
`rsp_ready=0`。修正提交 `4cbc5ae` 增加第二条 older `MOVZ`，但过早降 ready
又使 FMLA 未进入 ID/EX；最终提交 `0f39b61` 先等待上述三阶段窗口，再在下一拍
确认 `memwb_valid=1`、`exmem_valid=1`、`idex_pc=BASE+8`、
`exmem_can_accept=0`。RTL `2d0d43e` 未修改。

## 静态验证与限制

本 lane 遵循 T-009 重型队列约束，仅执行：

- `git diff --check 7f11664..0f39b61`：PASS；
- `python3 -m py_compile sim/cocotb/test_p7_3_neon_fp.py`：PASS；
- source/test 写集与 active task 约束人工核对：PASS；`rtl/lcvex_core.sv` 未修改。

未运行 Verilator、Cocotb、SV、QEMU、锁步、生成器、Quartus 或 physical flow；因此不
宣称功能或 timing 已验收。`merge_sha`、batch candidate source、联合 FP/P7 测试和
新的 top-50/STA 必须由 integrator 在 T-009 完成后统一产生。

## Integrator 待填字段

- active task JSON 的最终 `source_sha/head_sha/merge_sha/merged_at` 与
  `integrator_validation`（active JSON 只能由集成者更新）；
- batch candidate merge SHA、Verilator/Cocotb/SV/QEMU artifact 与日志 SHA；
- P7-1/P7-3/P7-4/P7-5 及受影响 IRQ/fault/restore 联合结果；
- physical synthesis/fitter/signoff STA 中 `fp_exec.acc[*].ena` 原路径是否离开
  top-50、面积/功耗/时序代价和任何新路径。
