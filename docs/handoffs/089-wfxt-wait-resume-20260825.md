# LCVEX 交接文档 089：WFxT 等待恢复时间同步

日期：2026-08-25（Asia/Shanghai）
前置：`088-pl031-cpp-fabric-20260825.md`
分支：`feature/p6-system-reg-shim`

## 触发现场

主线从 `linux-main-pl061-20260825/chain/diff-499999` 恢复后，先严格通过
361,637 条，随后到达：

```text
PC=0xffff80008108ea68
insn=d5031036  WFIT x22
x22=0x26aff64
```

旧协调器把所有指令限制为 1,000 个 DUT 周期，WFIT 的 QEMU timeout 路径无法
在此预算内恢复。保存 seq=359999 的新 12 列诊断 checkpoint 后可知，第一条
WFIT 为真实 halt；其后 Linux 又执行 `d5031016`（WFET x22），QEMU 因已有
work/event 立即返回。两者不能靠固定周期数或把 WFxT 退化为 NOP 统一处理。

## 修复

1. 协议新增：

   - `WAIT`（type 14）：QEMU plugin 的真实 vCPU idle callback 已发生；
   - `WAIT_RESUME`（type 15）：真实等待恢复、下一 PRE 前的
     `CNTVCT_EL0`。

2. QEMU fork 新增可重放 patch
   `qemu/patches/0008-lcvex-wait-resume-cntvct.patch`：导出
   `qemu_lcvex_difftest_get_cntvct()` plugin API。它仅在当前 LCVEX step
   vCPU 回调中返回 CNTVCT，其他上下文返回 `UINT64_MAX`。

3. plugin 的语义：没有 idle callback 就不会发 `WAIT`；真实 halt 的下一条
   PRE 前发送 `WAIT_RESUME`。因此 coordinator 可区分 QEMU
   `cpu_has_work()` 立即返回和真实 timeout/event 恢复。

4. coordinator：

   - 普通指令仍保持 1,000 周期预算；等待恢复可用独立
     `--max-wait-cycles`（默认 1,000,000）；
   - 带 `WAIT_RESUME` 时以 QEMU CNTVCT 重基准 DUT `cntpct_r`，同时补偿
     wake 同拍旧 `wfi_idle` 的一次内部计数；
   - 没有 `WAIT` 的立即返回仅注入非架构 event，并按 DUT 此刻是否已 visible
     idle 抵消 1 或 2 个内部计数，不伪造 timeout；真实 IRQ 仍必须通过
     `ASYNC` 比较。

5. 用户确认需要显式 Verilator 同步端口后，coordinator 不再直接写
   `event_reg/cntpct_r` 层级变量。`lcvex_soc_tb` 和 `lcvex_core` 新增
   `difftest_wait_release`、`difftest_wait_cntvct_valid`、
   `difftest_wait_cntvct`：协调器单拍驱动，核心在时钟边界锁存并消费；普通
   SV/Cocotb/microbench 固定为 0，FPGA 顶层也不连接此验证专用接口。

## 验证

```sh
make -C qemu/plugins
make -C ../qemu/build -j 6 qemu-system-aarch64
make p6-wfi

CHAIN=build/tmp/linux-main-pl061-20260825/wfi-precheck-20260825/chain \
RESUME_SEQ=359999 MAX_INSNS=10000 PIN=1 \
bash sim/difftest/run_lockstep_resume.sh
```

- `make p6-wfi`：base 与 I+D L1+L2 均通过（WFI/WFE、WFIT/WFET、Timer IRQ）；
- 主线诊断 checkpoint：原 WFIT/WFET 停滞点已跨过，从 seq=359999 继续
  10,000 条逐指令锁步通过；
- Lite：从 12 列 `post-pl031-cpp-v2` checkpoint 续跑 5,000,000 条并保存
  `long-post-pl031-cpp-ckpt-20260825/chain/base-4999999`（12 列，含
  `.dev.mmio.gz`）通过。

## 下一步

1. 提交本轮 plugin/coordinator/runner/文档和 QEMU patch 0008；
2. 主线从 `wfi-precheck` 的 seq=359999 继续长窗并保存新的 12 列链；
3. Lite 从 `base-4999999` 恢复继续向 `/init` 推进；
4. 下一次真实 MMIO/ISA 分歧继续优先补 C++ fabric 或已声明的标量 ISA，
   不把 QEMU 作为 runtime MMIO 从端。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,260p' docs/handoffs/089-wfxt-wait-resume-20260825.md
ps -eo pid,psr,pcpu,pmem,rss,stat,args | rg -i 'qemu|verilat|lockstep' || true
df -h build/tmp /tmp
```
