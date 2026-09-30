# LCVEX 交接文档 061：P6 Linux 尾段 MSR DAIF 调试续接

日期：2026-08-25（Asia/Shanghai）  
前置：`060-p6-msr-daif-commit-loss.md`  
当前分支：`feature/p6-system-reg-shim`  
当前提交：`e0e5943 debug: MSR DAIF commit-loss investigation (WIP)`

## 1. 交接结论

本次只完成交接和状态固化，没有启动新的锁步任务，也没有改变 RTL、QEMU
或 checkpoint。P6 Linux 尾段仍被一个确定的提交协议问题阻塞：在 MMU 开启的
真实 Linux 负载中，`MSR DAIF, x1`（`pc=0xffff8000810ca0a4`，编码
`0xd51b4221`）进入 DUT 的 IF/ID 后被跳过，协调器预期该提交，而 DUT 下一条
`MRS x1, SP_EL0`（`pc=...a8`）成为首个提交。

这不是“已经通过 14.8M”的状态。此前从 checkpoint 恢复后已通过约 14.76M
全局指令，失败发生在本地 `seq=762507`（前一条 `STLRB` 为 `seq=762506`）。
修复、验证和临时调试代码清理仍未完成。

## 2. 当前仓库与外部状态

- LCVEX 工作区干净；没有后台 QEMU、Verilator、锁步协调器或 `make` 进程。
- 当前 HEAD 的 WIP 提交已经包含临时调试接口和日志；不要假设它们仍是未跟踪
  改动。定论后应在一个独立提交中删除或整理它们。
- `../qemu` 是固定 QEMU 11.1.0 fork，基线 `84f0721`，工作区有预期 dirty
  改动（difftest step/checkpoint hook、RNDR 等）。禁止在该目录执行
  `git reset --hard`、`git checkout` 或覆盖式清理；QEMU 改动必须继续由
  `qemu/patches/` 可重放地维护。
- 主机当前 12 个物理核；测试按项目约定最多使用约 50%，并通过 `PIN` 绑定
  物理核。续跑脚本应使用 `setsid`，避免终端会话结束时杀掉后台任务。
- 最近检查：`/tmp` 可用约 7.0 GiB，系统可用内存约 19 GiB。checkpoint 或
  trace 运行前仍须检查空间，避免在 `/tmp` 产生未受控的 RAM 临时副本。

现有可恢复链：

| 链 | 内容 | 目录占用 |
| --- | --- | ---: |
| `build/difftest/tail-resume-ckpt4` | base `999999` + diff `1999999`，RAM 128 MiB | 约 13 MiB |
| `build/difftest/tail-resume-ckpt3` | base `1999999`，RAM 128 MiB | 约 13 MiB |

manifest 中的 `ram/dev/arch/sys/timer/gic` sidecar 必须成套使用，不能只恢复
RAM 或只恢复 QEMU arch 状态。

## 3. 已确认的失败证据

指令流：

```text
0xffff8000810ca0a0: stlrb wzr, [x0]  ; seq=762506，提交正确
0xffff8000810ca0a4: msr daif, x1    ; seq=762507，DUT 无提交
0xffff8000810ca0a8: mrs x1, sp_el0  ; DUT 下一条提交
0xffff8000810ca0ac: ldr x0, [x1,#8]
```

已提交的 `DBG tick` 观测到 MSR 在 IF/ID 中 `sys_op=3`、`sys_hold=1`，等待
前一条 STLRB 的访存排空；同拍出现的 `cvalid=1` 提交仍是 `...a0`。取指
已经超前到 `...ac`/`...b0`，但 `fetch_next_settled` 以
`fetch_pc_r == next_pc` 为条件，因而反复触发 `sys_fetch_redirect`。下一次
协调器调用 `step_until_commit` 时直接看到 `...a8`，没有观察到 MSR 的
`sys_commit` 或 UDEF 提交。

MMU 关闭的 `hard_p6_isa` MSR DAIF 写读用例已通过，故当前证据指向 MMU/取指
上下文的 IF/ID 保持与重定向竞态，而不是 DAIF 编解码本身。

## 4. 下一次工作必须按此顺序执行

1. 在 `tb/sv/lcvex_soc_tb.sv` 再暴露并接入协调器观测：`flush_id`、
   `capture_now`、`sys_fetch_redirect`、`stall_if`、`if_pc`。现有
   `dbg_ifid_valid/sys_commit/sys_hold/fetch_* /dec_sys_*` 接口保留用于对照。
2. 只重跑失败附近窗口，不从头启动 Linux：

   ```bash
   CHAIN=build/difftest/tail-resume-ckpt4 \
   RESUME_SEQ=1999999 MAX_INSNS=900000 PIN=0 \
   setsid bash sim/difftest/run_lockstep_resume.sh \
     > /tmp/lcvex-msr-daif-rerun.log 2>&1 < /dev/null &
   ```

   若需要新的 checkpoint，显式指定独立的 `CKPT_DIR`，并先确认磁盘和内存；
   不要让默认目录覆盖已有链。
3. 根据逐拍证据判断：重定向拍是否错误地 `capture_now` 捕获了 `...a8`，或
   `flush_id` 清空/覆盖了仍应保持的 MSR。修复应保持“每个 QEMU PRE 恰有一
   个 DUT commit packet”的协议，不得通过跳过比较或伪造提交绕过问题。
4. 候选修复仅限于架构正确的流水线处理：
   - 对等待中的系统指令，若取指已覆盖 `next_pc` 且无 fault，可重新定义
     settled 判定，避免 `fetch_pc_r` 超前导致永久重定向；或
   - 修正 `sys_fetch_redirect` 与 IF/ID `capture_now` 的优先级/清理时机，
     使 IF/ID 中的 MSR 保持到 `sys_commit`。
5. 修复后先重建 `make lockstep-build-kernel`（必要时轮换
   `build/verilator_lockstep_kernel`），再续跑至少 900000 条，确认跨过全局
   14.8M 目标。随后移除临时 `DBG tick/skip/excl/smcr/sp` 和多余 tb 端口，
   保留可复用的失败诊断能力，并运行：

   ```bash
   make test
   make checkpoint-sys-smoke
   make m2-4b
   ```

   再补跑 P6 关键锁步与尾段，记录命令、QEMU patch 校验和、结果及限制。

## 5. 不要做的事情

- 不要把 `MSR DAIF` 当作 NOP、把错误提交补成“看起来匹配”，或关闭断言/差分。
- 不要从 Linux 起点重新跑数千万条指令；优先使用 ckpt4 的 diff 链。
- 不要删除 checkpoint、trace 或 QEMU dirty 改动来“清理”工作区。
- 不要在未关闭该提交丢失前开始新的 P6 系统寄存器扩展；P7/P8 也继续等待
  标量 Linux 差分稳定。

## 6. 完成判据与提交边界

本问题关闭必须同时满足：

1. 失败窗口中 `MSR DAIF` 产生唯一、顺序正确的 commit packet；
2. 从 ckpt4 恢复至少通过全局 14.8M 尾段，且 QEMU/DUT 状态逐条一致；
3. base/cache 配置、P6 定向测试和现有回归不退化；
4. 临时调试代码已清理或转为受控 debug 开关，并有中文 handoff/测试记录；
5. 以单一逻辑提交提交修复，以另一提交（如有必要）提交文档/调试清理，
   然后才考虑阶段分支合入 `main`。在本地 Gate D 和 CI 均通过前不得合并。
