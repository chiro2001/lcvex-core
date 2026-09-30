# T-20260902-055：STXR same-COMMIT IRQ monitor sidecar

```text
task=T-20260902-055
state=review
base=c2fd2c7e6ea5b09491ee76f9dbe73586a87848e9
head=d15961752a6ecc53837ba51aa599ca3bb2c628d9
branch=infra/T-20260902-055-stxr-irq-mon-we
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-055
sent_at=2026-09-04T22:29:35+08:00
received_at=2026-09-04T22:29:35+08:00
reported_at=2026-09-05T00:01:33+08:00
files=qemu/plugins/lcvex_difftest.c; qemu/plugins/lcvex_protocol.py; sim/difftest/run_p6_irq_atomic_overlap.sh; sim/difftest/run_p6_stxr_irq_mon_we.sh; sim/difftest/run_stxr_irq_mon_we_probe.sh; sim/difftest/stxr_irq_mon_we_fixture.py; Makefile; scripts/test_registry.json
tests=plugin build/syntax/hash; 560B ABI fixture; same-COMMIT STXR success/fail base/delay2; sync STXR DABT; IABT; WFI WAIT/ASYNC; hard IRQ/DAIF/WFI/exclusive/LSE/LSE128; T-054 CASP/STXR/DC-ZVA base/delay2; scope audit
blockers=无；完整 make、T-054 companion base/delay2、SV FIFO off/on x delay0/2 均已实际退出0
next=集成者 cherry-pick 6316c51、d159617 与本 metadata commit，在合并 SHA 复跑任务要求子集并补 merge_sha
```

## 实现摘要

- `qemu/plugins/lcvex_difftest.c` 保存 `qemu_lcvex_difftest_take_exception()` 的
  `kind`：`kind=2` 异步 IRQ/FIQ 才把当前已退休指令的 monitor effect 带进 COMMIT；
  `kind=1` 同步异常仍不更新 monitor，EC=0x20/0x21 取指 fault merge 和 ERET
  清除例外保持不变。WFI 唤醒继续走独立 ASYNC，未调用 monitor effect。
- `qemu/plugins/lcvex_protocol.py` 补齐 C wire 的 `mon_data2`，COMMIT/ASYNC
  payload 从错误的 552B 镜像修为 560B，并同步 `store_count`/store tuple 偏移。
- `stxr_irq_mon_we_fixture.py` 中的 `build_stxr_sync_abort_image()` 在只读页上
  执行 LDXR→STXR，验证 STXR 权限 DABT 的异常 COMMIT `mon_we=0`；same-COMMIT
  success/fail 使用真实 Generic Timer PPI30，分别验证
  `mon_we=1, mon_valid=0, stores=1/0`。生成逻辑不再修改通用
  `sim/difftest/test_program.py`。
- 新增 560B wire fixture、WFI ASYNC 独立协议 peer 和串行 T-055 runner；runner
  覆盖 LDXR/CLREX、同步 DABT/IABT、ordinary IRQ、WFI ASYNC、hard IRQ/DAIF、
  LSE/LSE128/exclusive 以及 T-054 base/delay2 严格矩阵。没有修改 QEMU fork、
  QEMU binary、coordinator 或 RTL。

## 验证结论

- 修复前 T-054 same-COMMIT STXR success 现场：`seq=28` 的 DUT 为
  `mon_we=1`，QEMU 为 `mon_we=0`，协调器报 `mon_we 不一致`；保存现场摘要见
  `docs/tasks/evidence/T-20260902-054.json` 的 `resolved_failures`。
- 修复后 `RUN_T054=0 RUN_REGRESSIONS=0 ... bash
  sim/difftest/run_p6_stxr_irq_mon_we.sh` 通过 same-COMMIT success/fail
  base/delay2、同步 DABT、IABT、fixture 和协议回归。
- 修正后按指定命令
  `systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- sh -c
  'VERILATOR_JOBS=1 make p6-stxr-irq-mon-we'` 实际退出 0；日志包含 fixture、
  same-COMMIT base/delay2、WFI ASYNC、hard 回归和 T-054 direct base/delay2
  全部 PASS。
- 修正后的 canonical `run_p6_irq_atomic_overlap.sh` 实际退出 0；base/delay2
  各 5 场景的 probe/strict/trace 均 PASS，CASP match probe 明确报告
  `irq_stores=2`。随后 `systemd-run ... VERILATOR_JOBS=1 make
  sim-sv-irq-atomic-overlap` 实际退出 0，FIFO off/on × delay 0/2 全部 PASS。
- WFI peer 观察到 `WAIT=1, ASYNC=1`，ASYNC 的 `exc_code=0x40`、`mon_we=0`、
  `store_count=0`；T-054 QEMU 与 SV companion 均已在独立 cgroup 下完整退出 0。

精确命令、source/artifact hash、QEMU 版本和资源约束见
[`docs/tasks/evidence/T-20260902-055.json`](../tasks/evidence/T-20260902-055.json)。
