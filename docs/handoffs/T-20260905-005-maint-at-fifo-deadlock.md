# T-20260905-005：SYS_MAINT AT/FIFO fetch-owner deadlock 交接

```text
task=T-20260905-005 state=review base=8383cb05808393cc2ad391af261089321d0e2288 dispatch=38d01b996ee8bee362bf49240870a684eb0f6f2e head=5af738f946cb84ae7a46a8c26e0fce3f9d1b986e branch=fix/T-20260905-005-maint-at-fifo-deadlock worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-005 sent_at=2026-09-05T04:52:00+08:00 received_at=2026-09-05T04:52:01+08:00 reported_at=2026-09-05T05:10:05+08:00 files=rtl/lcvex_core.sv; docs/handoffs/T-20260905-005-maint-at-fifo-deadlock.md; docs/tasks/evidence/T-20260905-005.json; build/agents/T-20260905-005/** tests=base pre-fix p6-maint-v82 reproduction; make compile; sim-sv; sim-sv-fetch-fifo; sim-sv-mmu; final p6-maint-v82 six-window lockstep blockers=未运行Cocotb/完整Gate D/Quartus/上板 next=集成者在T-20260905-002 disposable candidate重跑联合L0-L2
```

## 结论

在冻结基线 `38d01b9`（源码基线 `8383cb0`）上先复现了
`hard_maint_v82_mmu` seq=12 的 AT S1E1R 卡死，再以一个 core-only corrective
提交解除 FIFO-on 下的 maintenance/fetch owner 循环等待。最终实现提交为
`5af738f`，未修改 muldiv、FP、PA2、MMU、QEMU、QSF、SDC 或板级路径。

### Pre-fix 根因

`lcvex_soc_tb` 默认 `FETCH_FIFO_ENABLE=1`。AT（`0xd5087800`）进入 ID 后，
数据翻译可完成，流水线排空，但下一条 PC 的 fetch 只完成 VA→PA translation，
未进入 FIFO：

1. `fetch_next_settled` 在 FIFO-on 只接受 current-epoch matching FIFO target 或
   matching fetch fault，不接受单独的 `fetch_translated`。
2. `fetch_imem_req_valid` 被 `!sys_maint_at_id` 阻断，`imem_req_valid` 也继续
   选择 maintenance owner；因此已翻译的 next-PC 无法发 IMEM 请求/push FIFO。
3. `sys_commit_ready = maint_done && fetch_next_settled` 永远为 0，
   `sys_hold/sys_maint_at_id/stall_id` 永久保持。

Pre-fix 现场精确显示：seq=12、PC `0x44000030`、AT S1E1R，流水线为空，
`stall_id=1`、`sys_at_id=1`、`sys_hold=1`、`sys_commit_ready=0`，
`fetch_translated=1`、`fetch_next_settled=0`、MMU idle。

### 最小修复

新增 core-local `maint_imem_owner`：

```systemverilog
assign maint_imem_owner = sys_maint_at_id &&
                          !(mmu_en && maint_state == MS_DONE);
```

`fetch_imem_req_valid` 与 `imem_req_valid/imem_req` mux 均改用该 owner。这样：

- MMU-on maintenance 在 `MS_DONE` 已无 maintenance request 时交还普通 fetch，
  next-PC 可进入 FIFO，随后原有 `sys_commit_ready`/`sys_commit` 路径完成提交；
- AT 数据翻译、`PAR_EL1` pending→commit 时机、MMU fault、fetch epoch/quarantine、
  maintenance `MS_REQ/MS_WAIT` owner 和顺序提交均未改变；
- MMU-off maintenance 保持原 owner 选择，避免扩大行为变化；
- 新增 SVA 要求 MMU-on maintenance 在 `MS_DONE` 且 next-fetch 未 settled 时不再
  持有 maintenance owner。

完整 p6 矩阵中，第一次只放开 AT 的中间尝试在 seq=28 DC CVAP 暴露同型问题；
最终修复扩大到所有 MMU-on maintenance 的 `MS_DONE`，因此完整六窗口均通过。

## 验证结果

所有 Verilator/锁步作业串行执行，`VERILATOR_JOBS=1`，并使用
`systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0`。

| 层级/入口 | 结果 | 证据 |
| --- | --- | --- |
| Pre-fix base `p6-maint-v82` | 预期失败：MMU-on seq=12 超时；MMU-off 19/19×2 通过 | `pre-fix/step_fail.txt`、`post-p6-maint-v82.log` |
| L1 `make compile` | PASS | `post-compile-final.log` |
| L1 `make sim-sv` | PASS | `post-sim-sv-final.log` |
| L1 `make sim-sv-fetch-fifo` | PASS | `post-fetch-fifo-final.log` |
| L1 `make sim-sv-mmu` | PASS | `post-mmu-final.log` |
| L2 `make p6-maint-v82` | PASS：MMU-off 19/19×2、MMU-on 30/30×2、EL0 24/24×2 | `post-p6-maint-v82-r2.log` |

完整命令、退出码、source SHA、artifact/log hash 和资源策略见
[`docs/tasks/evidence/T-20260905-005.json`](../tasks/evidence/T-20260905-005.json)。

## 边界与风险

- owner 停在 `review`；最终 candidate 合并 SHA 仍需由集成者重跑联合 L0-L2，
  任务不能仅凭 owner 结果标记 done。
- 未运行 Cocotb、完整 Gate D、Quartus、assembler/SOF、JTAG 或上板。
- maintenance owner 条件只对 `mmu_en && MS_DONE` 放行普通 fetch；任何后续
  maintenance/FIFO 变化必须保持 current-epoch target/fault settled 约束。
