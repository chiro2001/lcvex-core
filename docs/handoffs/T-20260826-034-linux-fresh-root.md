# T-20260826-034：当前集成 SHA Linux lite fresh-root 交接

日期：2026-08-26（Asia/Shanghai）  
候选基线：`e4e86db`  
证据：[T-20260826-034.json](../tasks/evidence/T-20260826-034.json)

## 结果

- 在包含 T-033 ALLINT 修复的候选 SHA 上，从全新复位开始运行
  `35,000,000` 条逐指令锁步，退出码 0，无 mismatch、timeout 或复位终止。
- QEMU/Verilator 分别绑定物理核 7/6；QEMU 使用固定 11.1.0、no-FP CPU、
  `virt,gic-version=2,memory-backend=lcvexram` 和 `-icount shift=0`。
- strict root manifest 已 finalized：70 个 checkpoint、490 个 artifact，
  最后 seq `34,999,999`。
- QEMU 日志记录：

```text
Run /init as init process
LCVEX linux-lite /init ready
```

- `/init` marker 之后继续运行到 35M，覆盖 SVC/IRQ/PSTATE.ALLINT 路径，仍全绿。

## Gate E 边界

这是当前候选 SHA 的 fresh-root + `/init` 稳定窗口本地证据。Gate E 仍不能在
CI run `32949011243` 完成前宣称通过；main 线用户态口径也仍需按冻结标准审核。
