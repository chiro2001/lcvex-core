# T-20260831-006 PE-F1A-NEXTSETTLE handoff

```text
task=T-20260831-006 state=review/partial
base=87d26890f75e69b4cf74cd75925094aa1bc8a86f
head=见本提交（source functional baseline=87d26890f75e69b4cf74cd75925094aa1bc8a86f）
branch=feature/T-20260831-006-f1a-next-settled
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260831-006
owner=luna-f1a-next-settled / t042_checkpoint_protocol_luna
model=gpt-5.6-luna reasoning_effort=max
sent_at=2026-08-31T12:56:30+08:00
received_at=2026-08-31T12:56:30+08:00
reported_at=2026-08-31T17:24:00+08:00
files=rtl/lcvex_core.sv; tb/sv/lcvex_fetch_fifo_tb.sv; sim/difftest/test_program.py;
      docs/handoffs/T-20260831-006-f1a-next-settled.md;
      docs/tasks/evidence/T-20260831-006.json
tests=pre-fix first-trace; correction SV old-pending/old-translated/old-normal/old-fault;
      SCTLR disable negative; old-fault-FIFO→SCTLR.M=0; FIFO-off SCTLR probe;
      d0/d2 probes; H-04; feature-off
blockers=cache/delay2 L2 strict matrix未运行（达到180分钟 budget stop）；correction 后
         d0/FIFO-off 已重建，d2/coordinator 仍需集成者在合并 SHA 重建并补矩阵
next=集成者 review correction commit；重建最终 artifacts 后补 cache/delay2 L2 再决定 done
```

## 结论

本任务已完成目标范围内的窄 RTL 修正和可审计 L0/L1 以及 base-L2 验证，但由于
资源预算到达 180 分钟，`cache/delay2` strict lockstep 未运行，因此 acceptance 是
**partial，不能直接标记 done**。随后 correction 已闭合 context refresh 与 merged
MSR write-effect 边界，但 correction 后的完整 L2 矩阵仍交由集成者重建/复跑。当前
实现没有扩大到 response UID、公共 memory ABI、QEMU/plugin 或 comparator；最终 d0
probe 已覆盖旧 fault FIFO 在 SCTLR.M=0 下被清除且不产生 `sys_fetch_merge`。

## 根因 first-trace

在 87d 基线，`0x44000ffc` 的编码 `d5181005` 是 ID-level `MSR SCTLR_EL1`。MMU
fault image 的关键 pre-fix 行为如下：

```text
cycle=114 ifid_pc=0x44000ffc ifid_insn=0xd5181005 sys_op=3 sys_reg=5
  d_next_pc=0x44001000 fetch_pc_r=0x44001000
  fetch_pending=1 fetch_translated=0 fetch_fifo_has_target=0 fetch_faulted=0
  fetch_next_settled=1 sys_commit_ready=1 sys_commit=1 sys_fetch_merge=0
cycle=142 head_pc=0x44001000 head_epoch=6 head_seq=18 FSC=0x07
  fifo_count=1 pop=0 fetch_faulted=1
```

也就是说，pending request 被错误当成 settled，MSR 先普通提交；真正匹配的 MMU
fault outcome 直到 cycle 142 才进入 FIFO。first-trace log SHA256 为
`71ea2862ead3445207d69510debebfa0469c3293c9c15133e13e7292cd939984`。

## 实现摘要

`rtl/lcvex_core.sv` 的修改保持在 F1a core-local 语义：

- FIFO-on 的 `fetch_next_settled` 只接受 current-epoch `fetch_fifo_has_target`，或
  current-epoch、PC 匹配的 `fetch_faulted` context；pending/translated 单独不再
  打开栅栏。
- 新增内部 `sys_fetch_context_change`，识别 SCTLR/TCR/TTBR0/TTBR1/MAIR 的 ID-level
  MSR。已有 `sys_fetch_redirect` 在上下文切换时 quarantine 旧的 matching
  pending/translated/fault/FIFO，下一次请求按 `mmu_en_eff` 重新取指。
- `sys_fetch_context_refresh_needed` 绑定 IFID token epoch：同一 epoch 的旧
  normal/fault FIFO、pending 或 translated outcome 均不能 settle；当 effective
  MMU 开启时强制一次 redirect/epoch bump，refresh 后的新 epoch 才能 settle。SCTLR.M=0
  是负对照，不触发 refresh。
- 若 fresh fault 与五个 translation-context MSR 合并，`sys_exc` 分支仍显式保留
  SCTLR/TCR/TTBR0/TTBR1/MAIR 的 MSR 写效果；新增 SVA 在 commit 下一拍核对状态。
- FIFO-off 分支保留原有 pending/translated settled 语义；无公共 response ID、无
  commit/pop/space/stall 反向依赖，新增 SVA 要求 settled 必须有 matching FIFO/fault
  outcome。

`tb/sv/lcvex_fetch_fifo_tb.sv` 增加 T-006 first-trace 字段、MMU-off branch
negative-control 收尾和旧 fault FIFO→MMU-off fresh target 观测；探针兼容 FIFO
head pop 与 IFID 进入的相邻时序，不改变 DUT 接口或架构状态。

## 结果

- d2 pre-fix：cycle 114 错误 `settled=1/sys_commit=1`，cycle 142 fault head。
- d2 post-fix：cycle 114–141 `settled=0/sys_commit=0`；cycle 142
  `fetch_fifo_has_target=1/fetch_faulted=1/sys_commit=1/sys_fetch_merge=1`；cycle
  143 单次 `EXC=0x21/ESR=0x86000007/FAR=0x44001000` 提交，`H03_POST_FIX_PASS`。
- d0 post-fix：同样 `H03_POST_FIX_PASS`（fault cycle 52）。
- MMU-off branch negative control：cycle 16 由既有 `fetch_merge_wb` 合并
  `EXC=0x21/ESR=0x86000010/FAR=0x5000`，`H03_NEGATIVE_PASS`，无 Fatal。
- H-04 d2 probe 仍观察到 WB-empty ready-low 时 FIFO pop 和 IFID→ID/EX 原子转移。
- feature-off system/commit backpressure smoke PASS；Cocotb d0/d1/d2 均 `TESTS=2
  PASS=2 FAIL=0`。
- base strict lockstep：`hard_sys_fetch_fault` 25/25、`hard_neon_fetch_fault` 20/20，
  QEMU `PRE/COMMIT` 与 RTL commit 一一对应，异常分别在 `0x44000ffc` 和
  `0x44000028` 合并；cache/delay2 未运行。

## Correction 结果（16a549d 之后）

受限 d0 correction binary 对以下四类旧 context 均通过，且每个非 disable 用例均
只观察到一次 `sys_fetch_redirect`、一次 epoch refresh 和一次 fresh outcome：

| 类别/寄存器 | 定向镜像 | 结果 |
| --- | --- | --- |
| old pending / SCTLR.M=1 | `hard_sys_fetch_fault` | cycle 41 redirect，cycle 52 fresh fault merge；SCTLR=`0xc50839` 写效果保留 |
| old translated / TCR | `tcr_normal.bin` | refresh 后空 FIFO 仍发 fresh request；TCR normal commit 写效果保留 |
| old normal FIFO / TCR、TTBR1、MAIR | `*_fifo.bin`（MUL 填充 FIFO） | 三项均 `old_normal=1, redirects=1, refresh=1, fresh=1`，对应 sysreg 写效果保留 |
| old fault FIFO head / TTBR0 | `ttbr0_fault.bin`（旧/新页表均 fault） | old fault head 被丢弃，fresh fault 走 `sys_fetch_merge`；TTBR0=`0x44018000` 写效果保留 |
| SCTLR.M=0 negative | `sctlr_disable.bin` | `refresh_needed=0, redirects=0`，普通 MSR commit 且无异常 |
| old fault FIFO head / SCTLR.M=0 | `sctlr_disable_fault_fifo.bin` | `old_fault=1`；commit 后 `sys_fetch_merge=0`、`mmu_en_eff=0`，fresh normal target 通过 |
| FIFO-off old-fault image / SCTLR.M=0 | `sctlr_disable_fault_fifo.bin` | 普通 commit，`sys_fetch_merge=0` 且无异常 |

关键日志 SHA256：`old_pending_final2.log`
`f0e7a309eede5c2996c427ea17a7c4fdff593743488f0b743f68d7040975975c`，
`tcr_translated.log` `145fc25c2226f7ddfdc46e9f34769a8f0c6b07c08ee6f4d8cc3ec4c2793cd658`，
`tcr_fifo.log` `e69195c0981c22d39638e0c7ff0476d36c503c7fc57edc77f9f40107f535208c`，
`ttbr0_fault.log` `ee46e59196dcd350916f2e269ec59c062f66b1b6976e809cc67d1195681c498f`，
`ttbr1_fifo.log` `250c4ccee17e8afeb5d0b55bca9bfc031093b0f424a54bc360468f6f68ea9640`，
`mair_fifo.log` `94f591c603ac130b152b2394f8deb0e03531f1fd7d72a6de2fb18dab10b1614a`，
`sctlr_disable_final2.log`
`e43174d958b0f7e91653271865f654f91f9e8107c5070b1f62c5046782d1379a`。
最终 d0 old-fault-FIFO `sctlr_disable_oldfault_fifo_final4.log`
`0aac939f1adc820fd7f5b6393c05bddef1d28517eb309bb4c5c5646fc8d1d50b`，普通
disable `sctlr_disable_final3.log`
`4f79bf9bd63156dbaf576dabcfa58c5cb457f061143fe5527b4d6a85539bc50a`；FIFO-off
old-fault `sctlr_disable_oldfault_fifo_off.log`
`d82430a878f3762aec1dbbfd9b04c515aaf4a3efac080cf18b726854742e2f6a`。
精确命令、unit、peak、image/binary hash 和 SVA/状态检查见 evidence。

## 资源与 provenance

所有重型命令使用 `MemoryMax=15G`、`MemorySwapMax=0`、`CPUQuota=50%`、
`MAKEFLAGS=-j1`、`VERILATOR_JOBS=1` 并串行执行。精确命令、unit、峰值、时间、
artifact/log SHA256 见 [`docs/tasks/evidence/T-20260831-006.json`](../tasks/evidence/T-20260831-006.json)。

本地登记 JSON 在 87d worktree 中仍显示注册时的 `base_sha=2baa063...`；正式派发
消息和 `feature/p7-final` 的 active record 已绑定 `base_sha=87d2689...`。本任务以
后者为实际 base，并在 evidence 中保留 mismatch 说明。

最终 correction d0 binary（`obj_d0_final2`）SHA256 为
`8e846c33068a137bafaac235a49e01d399229e1b9cd4a4f84c0aa75565930ec1`，FIFO-off
binary SHA256 为 `36f471fc6b53f24a67e6f1fa6be3ec5ca4796452aca9dfd0dd37548c4dbb69e9`，
两次构建 peak 均 3.2G；最终 source 仍需在合并 SHA 重建 d2 binary/coordinator。
完整 source 静态 lint、Python generator compile、JSON 和 diff check 均通过。

早先 `sctlr_disable_oldfault_fifo_final3.log` 的失败是 testbench 要求 FIFO head
与 IFID target 同拍造成的观测窗口问题（实际为相邻两拍）；修正探针后 final4
通过。FIFO-off 的首个 `disable_fault` 运行同样只触发了 FIFO 专用收尾断言，改用
`kind=disable` 复跑并确认 commit 无 `sys_fetch_merge`。

## 边界与后续

本任务未修改 `rtl/lcvex_pkg.sv`、MMU/arbiter/mem ABI、QEMU/plugin/comparator，
未新增 synthetic IFID packet 或 response UID。未跑 F1c、Gate D、Linux、Quartus。

建议集成者先 review 当前 partial commit，重建 final d0/d2 SV/coordinator，并补
`hard_sys_fetch_fault`/`hard_neon_fetch_fault` 的 cache 与 delay2 strict lockstep；
完成后才可将任务置 `done`。若新矩阵发现相同 epoch/PC 无法区分 response，另立
H-01/UID 协议任务，不在本写集内扩展。

## 集成者最终验收

稳定技术/文档 tip 为 `48f8e7de1f897bc50611f8edb586e270016db731`。集成者在
该 RTL/TB 内容上串行重建 FIFO-on d0/d2、FIFO-off d0、feature-off backpressure 以及
base/cache/delay2 三份 coordinator。所有作业使用 `MemoryMax=15G`、
`MemorySwapMax=0`、`CPUQuota=50%`、`-j1`；最高 peak=`4.7G`，全部
swap=`0B`。

最终定向结果：

- d0/d2 的标准 smoke、H-04、T-046 duplicate、MMU fault merge 全部通过；
- 原 old-fault 镜像在 d2 未触发前件，将 MUL 移至页尾 MSR 前一条后，
  d0/d2 均真实观察 old fault FIFO 并通过 SCTLR.M=0 正常提交/重取；
- FIFO-off old-fault 镜像与 system/commit backpressure 通过；
- `hard_sys_fetch_fault` 25/25 和 `hard_neon_fetch_fault` 20/20 在
  base/cache/delay2 六案 strict lockstep 中全绿。

首次 6-case 编排因工具层将 `${cfg}` 提前处理成空字符而在 DUT/QEMU
启动前退出；改用 `$cfg` 并只读确认三份 coordinator 路径后，同一矩阵全绿。
该编排失败与 d2 镜像前件失败均保留在 evidence，未删除或当作通过。
