# LCVEX 交接文档 093：异步 IRQ exception note 生命周期

日期：2026-08-25（Asia/Shanghai）
前置：handoff 092（LCVXSYS3）
分支：`feature/p6-system-reg-shim`

## 现场

主线从 `wfi-precheck` checkpoint 续跑，在全局 seq `4,103,808` 出现：

```text
PRE insn=0x2a0003f4
QEMU next_pc = IRQ vector
RTL next_pc  = 同一 IRQ vector，exc_valid=1/exc_code=0x40
QEMU COMMIT  = exc_valid=0
```

协调器正确拒绝此结果；不能把“下一 PC 相同”当成 IRQ 成功，否则会掩盖异常
边界、ELR/SPSR 或重复取 IRQ 错误。

## 根因与修复

QEMU fork 在 `arm_cpu_do_interrupt()` 记录单 vCPU `lcvex_exc_note`。plugin
已有 fallback：若普通指令 callback 才看见 vector PC，则在生成前一条 COMMIT
前再次调用 `qemu_lcvex_difftest_take_exception()`。

但该 API 原先额外要求 `qemu_get_cpu(vcpu_index) == current_cpu`。在 plugin
callback 时 `current_cpu` TLS 已清空，导致 pending IRQ note 无法消费。patch
`qemu/patches/0010-lcvex-plugin-exception-note-context.patch` 删除这一瞬态
上下文依赖；固定单 vCPU/TCG 单线程模式只校验 `qemu_get_cpu(0)` 存在。

plugin 在取到 kind=2 后依旧发出严格的 `exc_valid=1`、`exc_code=0x40`；RTL
继续独立由 GIC/Timer 产生 EXC_IRQ，协调器比较两边的 commit packet。此修改
不是事件回灌或宽松策略。

## 验证

```sh
taskset -c 0-5 make -C ../qemu/build -j 6 qemu-system-aarch64
make -C qemu/plugins -B

CHAIN=build/tmp/linux-main-pl061-20260825/irq-fallback-20260825/chain \
RESUME_SEQ=3999999 IMAGE=/tmp/Image-t80000 MAX_INSNS=110000 PIN=3 \
bash sim/difftest/run_lockstep_resume.sh

make p6-wfi
```

- QEMU 11.1.0 clean tree 顺序重放 patches `0001..0010` 通过；
- 从 seq `3,999,999` 恢复后锁步通过 110,000 条，跨过旧 seq
  `4,103,808`；
- `make p6-wfi` 的 base 与 I+D L1+L2 配置均通过 WFI/WFE/WFIT/WFET 与
  Timer IRQ 用例。

## 关联状态

- lite 后台 post-CRC 窗口另在相对 seq `671,978` 触发 `HVC #0`
  hostcall/复位状态分歧；它与 IRQ note 无关，失败现场保留于
  `build/tmp/r.Ztuz1g/fail.txt`，应在本提交后独立处理。
- 本修复尚未在更长主线窗口验证；若要推进主线，优先从
  `irq-fallback/chain/base-3999999` 继续并定期保存 checkpoint。
