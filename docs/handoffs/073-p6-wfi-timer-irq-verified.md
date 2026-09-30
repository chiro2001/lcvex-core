# LCVEX 交接文档 073：P6 WFI/WFE 与 Timer IRQ 唤醒验证

日期：2026-08-25（Asia/Shanghai）  
前置：`072-p6-casp-wfi-boundary.md`  
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮完成

- 解码并提交 `WFI/WFE/SEV/SEVL`；WFI/WFE 退休后核心进入 `wfi_idle`，
  不再发取指或数据请求；SEV/SEVL 设置单核事件寄存器。
- WFI idle 期间 Generic Timer 虚拟计数继续推进；IRQ 唤醒时核心产生独立
  `EXC_IRQ=0x40` 合成提交，保存 `ELR_EL1=等待指令下一条`，进入 EL1h
  IRQ 向量并恢复后可执行 ERET。
- 修正 GICv2 Timer PPI 映射：QEMU virt 非安全物理定时器为 PPI30，虚拟
  定时器为 PPI27。GIC 模型仅对 Timer 电平线使用默认 level 语义，不改变
  ICFGR 可见复位值。
- QEMU fork patch `0003-lcvex-wfi-idle-plugin-hook.patch`：WFI/WFE helper
  设置 halt 后显式调用插件 idle 回调；普通 QEMU 未激活 LCVEX 时无行为变化。
- 锁步协议新增 `LCVEX_MSG_ASYNC=13`。插件在等待指令正常 COMMIT 后，
  IRQ 唤醒发送合成异步提交；协调器让 DUT 从 idle 产生对应 packet，再比较
  PC、GPR/SP/NZCV、异常码和下一条 PC。重复的 IRQ/exception discontinuity
  回调会被过滤，避免同一个唤醒事件重复上报。

## 2. 测试入口与结果

新增：

- `sim/difftest/run_p6_wfi.sh`；
- `make p6-wfi`；
- `hard_wfi`、`hard_wfe`、`hard_wfi_timer_irq` 定向镜像；
- `a64.py` 的 WFI/WFE/SEV/SEVL 编码器。

实跑结果：

```text
hard_wfi             base/cache       2 条   PASS
hard_wfe             base/cache       2 条   PASS
hard_wfi_timer_irq   base/cache      45 条   PASS
hard_irq             base/cache      30 条   PASS（回归）
hard_gic             base/cache      52 条   PASS（回归）
```

`make compile` 与 Verilator lockstep 构建均通过。Timer 定向程序覆盖：
GICD/GICC 使能、PPI30、CNTP CVAL/CTL、DAIFClr、WFI、Timer IRQ、IAR/EOI、
IRQ handler 和 ERET。

## 3. 当前边界

- `WFI/WFE` 的 idle/IRQ 协议已能在裸机 base/cache 定向测试中闭环；Linux
  深段仍需从 `tail-resume-ckpt17` 或 `casp-debug` 边界继续，确认真实 WFI
  定时器/外设唤醒与用户空间入口。
- `LDCLRP/LDSETP/SWPP` 等其他 LSE128 操作、FIQ、PMU、Gate E 仍未完成。
- WFE 的跨核 SEV 广播在单核范围外；当前 SEV/SEVL 仅维护本核事件寄存器。

## 4. 后续命令

```bash
make p6-wfi
make m2-4b                         # 变更后完整 M2/R1 回归
CHAIN=... RESUME_SEQ=... MAX_INSNS=... \
  bash sim/difftest/run_lockstep_resume.sh
```

长跑前检查 `/tmp`/磁盘，绑定单个物理核；不要删除现有 checkpoint 或回退
`../qemu` dirty fork。
