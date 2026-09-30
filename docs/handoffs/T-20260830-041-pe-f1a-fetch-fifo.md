# T-20260830-041 PE-F1A handoff

task=T-20260830-041 state=review
base=0f4b4a18970219e719674edd6cb3ff91d4c7ac38 head=8e91df54ae251869779b3e7ebcaaf735df158aa0 content_sha=d14aab0025acbd6a347b7f8c5ef0759ccaba2e49
branch=feature/T-20260830-041-pe-f1a-fetch-fifo worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-041
sent_at=2026-08-30T16:15:06+08:00 received_at=2026-08-30T16:16:16+08:00 reported_at=2026-08-30T18:49:13+08:00
followup_sent_at=2026-08-30T16:51:53+08:00 followup_received_at=2026-08-30T16:52:32+08:00 test_slot_released_at=2026-08-30T16:51:53+08:00
files=rtl/lcvex_core.sv; tb/sv/lcvex_soc_tb.sv; tb/sv/lcvex_fetch_fifo_tb.sv; sim/cocotb/test_fetch_fifo.py; sim/cocotb/Makefile.fetch_fifo; sim/difftest/test_program.py; sim/difftest/run_f1a.sh; Makefile; docs/tasks/evidence/T-20260830-041.json
tests=L0/L1/L2 通过（含 feature-off 回归与额外 MMU/TLBI/IC/IRQ/WFI/ERET）；详见 evidence runs
evidence=docs/tasks/evidence/T-20260830-041.json
blockers=无实现阻断；等待集成者在合并 SHA 复跑并完成 review/done 门
risks=公共 mem_rsp_t 无 response ID，enabled 路径仍严格单 MMU/单 I-L1 在途；standalone reset-vector fetch fault 仍沿用既有 merge-only 边界；未宣称 F1b 或性能收益
next=集成者核对提交/证据后合并，按任务要求在合并 SHA 复跑受影响子集

## 实现摘要

- 在 `lcvex_core.sv` 增加默认关闭的 `FETCH_FIFO_ENABLE`、depth/epoch 参数和固定
  2-entry ring。entry 保存 valid/epoch/seq/VA PC/指令/fault/FSC；FIFO head 供给现有
  IF/ID，commit packet、单发射和顺序提交接口未改。
- enabled 路径仍只接受一个取指翻译和一个 I-L1 request；request fire 时保存本地
  epoch/seq/context，响应进入 FIFO。FIFO 满时对 current response 施加 backpressure，
  同拍 push+pop 保持 occupancy；`commit_ready=0` 时禁止 FIFO pop。
- `frontend_kill` 聚合分支、系统/维护、TLBI、异常、IRQ、WFI/wake、restore 等原因；
  kill 优先于 push/pop 并 bump 一次本地 generation。旧 MMU/IMEM response 通过
  `fetch_stale_mmu`/`fetch_stale_imem` quarantine 消费丢弃，quarantine 清空前禁止新
  fetch/data translation。TLBI 对被 MMU 同步取消的 walk 不等待不存在的 done。
- 修复 F1a 与 MMU data translation 的边界：fetch `mmu_done` 与 IF/ID 数据指令同拍
  时，`data_wait_for_translation`/`trans_done_pc_r` 阻止错误 FIFO pop 和未翻译指令进入
  EX/MEM；该回归曾在 MMU store/TLBI 用例中复现，修复后严格锁步通过。
- 新增 `tb/sv/lcvex_fetch_fifo_tb.sv`、Cocotb 独立入口和 `run_f1a.sh` 镜像矩阵骨架，
  实际覆盖 branch flush、FIFO bound、延迟响应、reset、commit backpressure；额外
  feature-on 锁步覆盖 MMU/data、TLBI/IC、self-modifying、IRQ、WFI 和 ERET。

## 边界和已知限制

本提交不修改 `lcvex_pkg.sv`、I-L1、MMU 或仲裁器，不实现 F1b early-restart/critical-
word-first，也不引入多 outstanding 或 response sideband。FIFO/debug 状态是非架构
状态，默认关闭路径继续复用原有单 context FSM。任何 later-beat fault/无身份多事务
问题仍需另立协议任务，不在本任务扩大写集。

精确命令、源码 SHA、测试槽释放、运行结果和 evidence 事实以
[`docs/tasks/evidence/T-20260830-041.json`](../tasks/evidence/T-20260830-041.json) 为准；
本 handoff 不复制测试日志；详细 PASS/FAIL 及失败现场链接见 evidence，未宣称性能收益。

## 集成者元数据纠正

owner 持久 handoff 初值 `reported_at=2026-08-30T18:35:38+08:00`，evidence 后续值为
`2026-08-30T18:43:32+08:00`，两者均早于内容提交 `d14aab0` 和最终证据提交
`8e91df5`。集成者按 harness 实际收件时间纠正为
`2026-08-30T18:49:13+08:00`；owner 最终 branch tip 为
`8e91df54ae251869779b3e7ebcaaf735df158aa0`，技术内容提交为
`d14aab0025acbd6a347b7f8c5ef0759ccaba2e49`。
