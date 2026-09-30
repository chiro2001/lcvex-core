# LCVEX 交接文档 062：MSR DAIF 假性丢失与无时钟诊断修复

日期：2026-08-25（Asia/Shanghai）  
前置：`061-p6-msr-daif-next.md`  
当前分支：`feature/p6-system-reg-shim`  
修复提交：`3e46aed verify: keep lockstep diagnostics side-effect free`

## 1. 结论

061 记录的 `MSR DAIF, x1` 提交丢失不是 RTL 流水线 bug，而是协调器的
临时失败诊断改变了 DUT 时序：`VerilatorDut::read_mem()` 为读取同步 RAM
调试口调用 `tick()`，而它在 QEMU 已提交 Store、等待下一个 COMMIT 的窗口
内被调用。一次 Store 诊断会额外推进 DUT 两拍，导致协调器下一次 PRE 看到的
已经是后续指令，形成“MSR 被跳过”的假象。

修复后不再修改 RTL 的时序或提交协议：

- 删除 060/061 中用于定位该假象的临时 IF/ID、逐拍 DBG 端口和日志；
- `read_mem()` 改为直接读取 Verilator 暴露的 RAM 数组，使用与原调试口相同
  的低 27 位地址回绕，不调用 `tick()`；
- `hard_p6_isa` 中的 MSR DAIF 写读定向用例和 `a64.py` 的 DAIF 编码保留，
  作为正式系统寄存器回归，而不是临时绕过。

## 2. 关键证据

在带临时边沿观测的运行 `build/difftest/resume-run.usvfrZ` 中：

1. `seq=762506` 的 `STLRB` 正常产生 COMMIT；
2. 同一 COMMIT 的诊断分支打印 `DBG store`，并调用两次 `dut.read_mem()`；
3. 下一次 PRE（`seq=762507`，PC `0xffff8000810ca0a4`，编码
   `0xd51b4221`）开始前，DUT 已被这两次隐式 tick 推进，首个可见提交变成
   `MRS x1, SP_EL0`（PC `...a8`）；
4. 这解释了此前看似违反 `sys_hold`/IF/ID 保持的现象：没有任何合法 RTL
   分支需要把 MSR 覆盖，时钟是从诊断路径偷偷推进的。

## 3. 修复后权威验证

运行目录：`build/difftest/resume-run.bsWen3`。命令：

```bash
CHAIN=build/difftest/tail-resume-ckpt4 \
RESUME_SEQ=1999999 MAX_INSNS=900000 PIN=0 \
setsid bash sim/difftest/run_lockstep_resume.sh \
  > /tmp/lcvex-msr-daif-rerun-fixed-read.log 2>&1 < /dev/null &
```

结果：

- 协调器退出码 `0`；
- `PASS: 从 seq=1999999 续跑 900000 条通过`；
- `seq=899999 OK`，没有 PRE/COMMIT 顺序错误；
- 该窗口从全局约 14M checkpoint 跨过约 14.8M 目标；
- QEMU 仍为固定 11.1.0 fork，未修改或覆盖其 dirty 工作区。

随后删除临时调试接口并再次执行 `make lockstep-build-kernel`，Verilator
编译成功。随后 `make test`、`make checkpoint-sys-smoke` 和 `make m2-4b`
均通过；期间顺手关闭了 `-Wall` 暴露的无效 `decode.timer_count` 端口并补齐
两个 SystemVerilog TB 的 `commit_mon_data2` 连接。当前无后台
QEMU/Verilator/锁步进程。

## 4. 后续工作

1. 提交并保留 `3e46aed`，将“诊断函数不得推进 DUT”作为锁步基础设施不变量；
   后续新增失败诊断必须使用无时钟观察或显式记录/恢复，不能在 PRE/COMMIT
   之间调用 tick。
2. 运行 P6 相关回归（`make test`、`make checkpoint-sys-smoke`、
   `make m2-4b`，再按资源计划运行 Gate D/P6 定向）；记录结果后再更新
   阶段文档。
3. Linux 尾段当前已跨过 14.8M；仍未宣称 Gate E 完成。Timer IRQ/WFI、稳定
   early boot 后的用户空间和更长时间负载仍需单独验收。
