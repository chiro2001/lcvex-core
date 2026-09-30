# T-20260905-004：R16 core issue fanout cut 交接

```text
task=T-20260905-004 state=review base=1ccbb3baed633c9c64e7a078df4cad4ece69a2a5 head=169f75cb5690141ad33f1a785ec8590a340189ee branch=timing/T-20260905-004-r16-core-issue-cut worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-004 sent_at=2026-09-05T02:38:19+08:00 received_at=2026-09-05T03:23:27+08:00 reported_at=2026-09-05T03:32:59+08:00 files=rtl/lcvex_muldiv.sv,rtl/lcvex_core.sv,tb/sv/lcvex_muldiv_req_tb.sv,sim/cocotb/test_muldiv_req.py,sim/difftest/test_program.py,Makefile,scripts/test_registry.json,docs/handoffs/T-20260905-004-r16-core-issue-cut.md,docs/tasks/evidence/T-20260905-004.json tests=git diff --check; Python AST/JSON; registry --check --check-consistency; make -n; bash -n; static builder count blockers=未运行 Verilator/Cocotb/QEMU/生成器/重型测试（按 batch 门控） next=集成者汇入 T-20260905-002 batch candidate 后运行联合 L0-L2
```

## 结论

本 lane 在 T-058 extended STA 暴露的共享 `idex_valid / issue-hold-enable`
锥上完成两个互相独立的寄存边界切点，未修改 hazard/flush/sys_commit 根、FP/
pkg 公共类型、QEMU、QSF 或 SDC。两个 RTL 实现提交可分别回退：

- `ad0d2c0`：`lcvex_muldiv` 请求捕获与 pending→active launch。
- `a3a9b3a`：EX/MEM PA2 推导与 pair 地址断言。
- `169f75c`：corrective commit，完整移除上述 PA2 token/跨页动态分支，恢复
  pair PA2 纯由匹配已寄存 PA1+8 推导。

### muldiv request capture

- `start` 只把 `op/is_32/a/b/acc` 捕获到 request 寄存器；下一拍才由
  `pending_r` 启动 active 迭代器。`busy` 覆盖 pending 与 active，`done/result`
  仍只在最后一个 active 计算周期组合有效，不新增 `done_ready` 或结果保持协议。
- SDIV 的幅值、商符号、MADD/MSUB 选择、32 位宽度和 UMULH/SMULH 操作数均从
  捕获的 request/active 寄存器产生；capture 后 live ID/EX 输入不能泄漏到 DSP
  迭代或结果。
- 新增同步 `kill` 仅由 core 的年轻 ID/EX 精确恢复/异常边界驱动：
  `fetch_merge_wb || wb_exc_commit || difftest_restore_sys_valid`，并以
  `idex_valid && is_muldiv` 限定。普通 `flush_id` 和 `irq_taken` 明确排除：
  branch flush 不杀当前更老 muldiv，IRQ 继续遵循 T-051 的完成/不可回滚 fence。
  reset/kill 清空 pending、active、结果和请求字段，因此不会产生幽灵完成。

### PA2 derive

- `ex_pipe_t.mem_paddr2` 字段保留；ID/EX 只写入零占位，不再把 live decode/
  `idex_valid` 组合锥接到该字段的动态值。
- EX/MEM 捕获时从匹配的已寄存 `idex_d.mem_paddr`（PA1）纯推导 pair 高半
  `PA1 + 8`；W pair 的实际第二个 dmem 请求仍由既有 `mem_size` 选择固定 `+4`，
  提交 `mem2` 表示保持不变。
- 合法自然对齐的 16B `d_mem128` 不跨页；GPR LDP/STP/LDXP/STXP 的跨页第二次
  翻译与 all-or-nothing 限制是 batch 之前已有边界，本 lane 明确不扩项。不新增
  请求、不绕过 MMU/PA window/alignment/fault/cache bypass；kill/reset 清除 EX/MEM
  PA2，新增同页 +8 与 W pair +4 断言。

### 测试与入口

- `tb/sv/lcvex_muldiv_req_tb.sv` 是 SV/Cocotb 共用 wrapper：覆盖 pending/active
  busy、capture 后 live 输入扰动、MUL/MADD/MSUB/SMADDL/SMSUBL/UMADDL/UMSUBL、
  UMULH/SMULH、UDIV/SDIV W/X、div0、reset 以及 pending/active kill；MUL W
  向量 `0xffff_ffff_1234_5678 * 5` 的期望为 `0x0000_0000_5b05_b058`。
- `sim/cocotb/test_muldiv_req.py` 提供同一 raw-bit 定向矩阵；`Makefile` 新增
  `sim-sv-muldiv-req`、`sim-cocotb-muldiv-req` 和 batch L2 入口
  `difftest-muldiv-request`。
- `sim/difftest/test_program.py` 新增显式
  `build_hard_muldiv_request_program`，包含 MUL/UMULH/SMULH/UDIV/SDIV 的 W/X
  与 XZR div0；程序实际输出 16 个 words（18 个 `Insn` 条目含 2 个 label），
  与 `MULDIV_REQUEST_MAX_INSNS=16` 一致；registry 新增两个 L1 与一个 L2 条目。

## 静态验证

以下均为轻量检查，未启动仿真、QEMU、生成器或 physical flow：

| 检查 | 结果 |
| --- | --- |
| `git diff --check` | PASS |
| `python3` AST 解析 `test_program.py`/`test_muldiv_req.py` 与 registry JSON 解析 | PASS |
| `python3 scripts/test_registry.py --check --check-consistency` | PASS（76 项） |
| `make -n sim-sv-muldiv-req sim-cocotb-muldiv-req difftest-muldiv-request` | PASS |
| `bash -n sim/difftest/run_p6_lse.sh` | PASS |

## Batch 联合验收（由集成者在 candidate SHA 执行）

任务登记的完整 L0-L2 联合集合如下；owner 停在 `review`，不把下列未运行项拆成
不同 SHA 的证据：

- L0：microbench/标量路径受影响 smoke（按 batch parent 任务调度）。
- L1：`make compile`；专用 muldiv SV/Cocotb 的 all-op W/X/zero/reset/kill/
  done-hold 检查；core `sim-sv`、backpressure、fetch-fifo、MMU、IRQ-young、
  IRQ-atomic suites；必要的 pair/LSE/LSE128/maint-v82/NEON-int/fetch-fault
  定向单元。
- L2：`difftest-rtl`、`difftest-hazard`、专用
  `difftest-muldiv-request`；pair/LSE/LSE128/maint-v82/IRQ-atomic/STXR-IRQ/
  NEON-int/fetch-fault strict lockstep；P7 scalar/NEON sequences 受共享 issue/
  enable 影响的完整联合集合。

## 边界与风险

- 未在 owner worktree 运行 Verilator/Cocotb/QEMU；需在 `T-20260905-002`
  candidate 合并 SHA 一次性完成联合 L0-L2，再决定是否晋级长期分支。
- 物理时序改善未测量；需由后续 physical lane/STA 确认 `idex_valid -> muldiv`
  与 `idex_valid -> idex_d.mem_paddr2` 是否离开 top-N。
- GPR LDP/STP/LDXP/STXP 跨页第二翻译与 all-or-nothing 是 batch 前既有限制，
  本任务不扩展该语义；联合 MMU/LSE128/NEON Q 测试按既有边界复核请求计数。
- evidence 的 `merge_sha` 保持 `null`，由集成者补 candidate merge SHA 与联合
  运行事实；不修改 `/home/chiro/projects/mycpu/lcvex/docs/tasks/active/` 任务登记。
