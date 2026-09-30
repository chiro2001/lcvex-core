# LCVEX 交接文档 060：Linux 14.76M MSR DAIF 提交丢失（调试中）

日期：2026-08-25（Asia/Shanghai）
前置：handoff 059（SVE/SME 探测修正 + sidecar v2 + LDXP/STXP）。

## 1. 当前状态

尾段续跑（`linux-resume-14m-rndr` 链，QEMU 11.1.0 step 锁步）已推进到
全局约 14.76M（本地 seq=762507，从 ckpt4/local 1999999 = 全局 ~14M 恢复
后 762k 条）。此前的缺口已全部关闭（SMCR/SMPRI、CSSELR、SMIDR/AIDR、
RDSVL 取整、EXTR、RNDR 确定化、ERET/SP 银行、SPSel、LDXP/STXP），
每个修复都有定向测试且 base/cache 回归全绿。

当前唯一阻塞：本地 seq=762507 的 `MSR DAIF, x1`（0xd51b4221，
pc=0xffff8000810ca0a4）在 DUT 中提交丢失——协调器 PRE 期望它，但 DUT
第一个提交是下一条 `MRS x1, sp_el0`（0xffff8000810ca0a8）。

## 2. 现象与周期级证据（r22/r23 调试运行，run 目录已清理）

失败点指令流（内核 preempt_count/local_irq_restore 路径）：

~~~text
0xffff8000810ca0a0: stlrb wzr, [x0]        ; seq=762506（OK）
0xffff8000810ca0a4: msr daif, x1            ; seq=762507（DUT 跳过！）
0xffff8000810ca0a8: mrs x1, sp_el0          ; DUT 提交了这条
0xffff8000810ca0ac: ldr x0, [x1, #8]
~~~

协调器 step_until_commit 的周期级观测（DBG tick）显示：

~~~text
pc=0xa4 insn=0xd51b4221 ifid=1 sysc=0 sysh=1 fpc=0xa4 pend=0 trans=0 settled=0 op=3 next=0xa8 cvalid=0
pc=0xa4 insn=0xd51b4221 ifid=1 sysc=0 sysh=1 fpc=0xa4 pend=0 trans=0 settled=0 op=3 next=0xa8 cvalid=1 cpc=0xca0a0
~~~

关键观察：MSR 在 IF/ID（sys_op=3=SYS_MSR、sys_hold=1），而同拍
cvalid=1 的提交 pc 是 **0xca0a0（前一条 STLRB 的 WB 提交）**——即
step 返回的是 STLRB 的提交；MSR 在 IF/ID 等待流水线排空。随后协调器
进入 seq=762507 的 PRE/step 时，DUT 直接提交了 0xa8（MRS），说明 MSR
在等待期间从 IF/ID 丢失且未产生提交（既无 sys_commit 也无 UDEF 提交）。

## 3. 当前假设（尚未定论）

1. **MSR 等待期取指超前 + sys_fetch_redirect 反复冲刷**：STLRB 是访存
   指令，其数据事务长时间占用流水线（DBG 显示 STLRB 在 IF/ID 停留约
   17 拍）；期间 IF 继续超前取指到 0xac/0xb0（fetch_imem_req_valid
   不检查 stall_if）。MSR 的 sys_commit 需要 `fetch_next_settled`
   （fetch_pc_r == next_pc=0xa8），而 fetch_pc_r 已超前到 0xac；
   `sys_fetch_redirect` 因此反复触发、清掉在途取指并重定向 if_pc=0xa8，
   可能与 IF/ID 捕获/冲刷相互作用导致 MSR 被覆盖。
2. **IF/ID 捕获覆盖**：sys_hold 使 stall_if=1、capture_now=0，理论上
   不会覆盖 IF/ID；但 sys_fetch_redirect 只清取指状态不清 IF/ID，
   需核对重定向后 capture_now 是否在错误拍捕获了 0xa8。
3. **MMU 开启时 MSR 提交 gating 过强**：`sys_commit_ready` 在 MMU on
   时要求 fetch_next_settled；而 fetch_next_settled 依赖 fetch_pc_r
   恰好等于 next_pc。取指超前时该条件长时间不成立，属已知薄弱点。

## 4. 已就位的调试设施（工作区未提交）

- `tb/sv/lcvex_soc_tb.sv`：新增 dbg_ifid_valid/sys_commit/sys_hold/
  fetch_pc/fetch_pending/fetch_translated/fetch_next_settled/
  dec_sys_op/dec_next_pc 输出。
- `sim/difftest/lockstep_coordinator.cc`：
  - `DBG skip`：PRE-commit pc 不匹配时打印 DUT 内部状态；
  - `DBG tick`：step_until_commit 内对 pc∈[0xca0a0,0xca0b0) 逐拍打印
    流水线状态（含 cvalid/cpc）；
  - `DBG excl/smcr/sp`：exclusive/SME/SP 状态取证；
  - 均为临时调试，定论后移除。
- `sim/difftest/a64.py`：新增 daif 寄存器编码；`test_program.py` 的
  hard_p6_isa 已加 MSR DAIF（寄存器形式）写读用例（106 条，MMU off
  下通过，说明非通用 MSR DAIF bug，而是 MMU/取指上下文相关）。

## 5. 建议的下一步（按优先级）

1. 在 `DBG tick` 基础上再加一拍：MSR 进入 IF/ID 后逐拍打印
   `flush_id`、`capture_now`、`sys_fetch_redirect`、`stall_if`、
   `if_pc`（需在 tb 再暴露 3~4 个信号，重跑一次 762k 段约 3 分钟）。
2. 重点核对 `sys_fetch_redirect` 与 IF/ID 捕获的竞态：若重定向拍
   capture_now 误捕获（fetch_got_data 清得太晚/太早），MSR 会被
   0xa8 覆盖——这最符合“MSR 无提交消失、MRS 成为首个提交”的现象。
3. 修复方向候选：
   - sys_commit_ready 对 MSR 放宽：取指超前时（fetch_pc_r > next_pc）
     视为 settled（fetch 已覆盖 next_pc 且无 fault）；
   - 或 sys_fetch_redirect 触发时同步保持 IF/ID（不清 fetch_got_data
     中已属于 next_pc 的数据）。
4. 修复后：重新编译 kernel 协调器，从
   `CHAIN=build/difftest/tail-resume-ckpt4 RESUME_SEQ=1999999
   MAX_INSNS=900000` 续跑验证过 14.8M，然后清理临时调试、全量回归、
   提交。

## 6. 保留资产与命令

- 链：`build/difftest/linux-resume-14m-rndr.A056Gm`（原链，QEMU
  c05cb64b…）、`tail-resume-ckpt3`（全局 ~12M/13M v2 checkpoint）、
  `tail-resume-ckpt4`（全局 ~14M，base-999999 + diff-1999999）。
- 续跑脚本：`sim/difftest/run_lockstep_resume.sh`（支持 base/diff
  记录、RESTORE_SMCR 默认空、PIN 绑核）。
- 重建命令：`make lockstep-build-kernel`（先 mv 旧目录轮换，
  见 Makefile 注释）；QEMU/插件已是当前代码（rndr 钩子 + LDXP/STXP
  协议），无需再动 fork。
- 无后台进程（r23 已结束）；主机内存充裕。

## 7. 已提交基线（feature/p6-system-reg-shim）

- `0e1bea7 isa: add LDXP/STXP 128-bit exclusive pair`
- `e0c4e5c verify: resume script handles base/diff checkpoint records`
- `57c075a docs: handoff 059`、`dd270de verify: sys sidecar v2`
- `41975f7 verify: resume/sys smoke`、`fc9c09f isa: P6 probe semantics`

工作区未提交：tb 调试信号、协调器临时 DBG、hard_p6_isa 的 MSR DAIF
用例、a64.py daif 编码（调试用，修复后随正式提交一并整理）。
