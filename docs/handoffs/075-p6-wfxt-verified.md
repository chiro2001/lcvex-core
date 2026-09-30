# LCVEX 交接文档 075：P6 WFIT/WFET 超时等待验证

日期：2026-08-25（Asia/Shanghai）
前置：`074-p6-linux-wfi-resume-timeout.md`
当前分支：`feature/p6-system-reg-shim`

## 1. 本轮完成

- RTL 新增 `SYS_WFIT/SYS_WFET`，解码 `WFIT/WFET Xt` 并登记 Xt 依赖；
- WFIT/WFET 在提交边界比较 `CNTVCT_EL0` 与 Xt：未来值进入 idle，计数
  到期恢复到下一条指令；已到期值立即继续；WFET 在等待前优先消费本地
  `SEVL/SEV` 事件寄存器；
- QEMU fork 新增 `0005-lcvex-wfxt-idle-plugin-hook.patch`，在 WFIT/WFET
  helper 进入 halt 前调用插件 idle 回调；插件 `is_wait_insn()` 识别带
  寄存器的 WFxT 编码，并在无 IRQ 的 timeout/event 恢复时清除旧 wait 状态；
- 临时 `LCVEX_DEBUG_PRE_GE/COMMIT_GE` 诊断代码已从插件删除；已有
  `0004-lcvex-timer-recalc-after-restore.patch` 仍保留并已应用于本地 QEMU。

## 2. 定向验证

新增 `hard_wfit_wfet_timer`，共 14 条有效提交，覆盖：

1. WFIT 未来超时后恢复；
2. WFET 未来超时后恢复；
3. 已到期 WFIT 不进入 idle；
4. `SEVL` 后 WFET 消费事件并立即继续。

已通过：

```text
make test                         PASS
make m2-4b                        PASS（base/cache）
make p6-lse                       PASS（base/cache，100 条）
make p6-wfi                       PASS（base/cache，含 WFxT 14 条）
hard_wfit_wfet_timer, base        PASS（14 条）
hard_wfit_wfet_timer, I+D+L2      PASS（14 条）
```

`make p6-wfi` 入口已改为 14 条版本，base/cache 均已完整执行通过。

## 3. 工作区与限制

根仓库当前包含 WFxT RTL、测试、文档、插件和 QEMU patch 0004/0005 的未
提交改动；`../qemu` 是固定 11.1.0 fork，已有 dirty 内容均为预期，禁止
reset/checkout。当前没有后台 QEMU/Verilator/锁步进程。启动长跑前重新检查
`/tmp` 与磁盘，并绑定一个物理核。

Linux 仍停在约 28.5M 动态指令后的 WFI 等待边界。WFIT/WFET 裸机闭环已证实，
但 Linux 实际等待点的中断源、checkpoint 恢复后的 Timer/GIC 状态和用户空间
入口尚未验收；不要将 WFI timeout 当作 Gate E 完成。

## 4. 下一步

1. 运行完整 `make p6-wfi`，确认 14 条 WFxT 在 base/cache 均绿；
2. 提交 RTL、QEMU patch、插件、测试和文档（按逻辑拆分提交）；
3. 从 `casp-debug-20260825`/`linux-wfi-state-20260825` 检查 Linux WFI
   前后的真实 PPI、DAIF.I、GICC PMR 和 Timer sidecar，必要时扩展 ASYNC
   协议以区分 IRQ 唤醒与 WFxT timeout；
4. 继续 Linux 锁步，目标是稳定 early boot、用户空间 `/init`，再评估
   `LDCLRP/LDSETP/SWPP` 等 LSE128 其他族。
