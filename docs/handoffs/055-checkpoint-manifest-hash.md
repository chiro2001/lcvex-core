# LCVEX 交接文档 055：checkpoint 输入与链完整性 manifest

日期：2026-08-24（Asia/Shanghai）
前置：handoff 054（确定性 virt Device Tree）。

## 1. 本轮结论

checkpoint 差分链现在绑定了运行时输入环境，不再只依赖 sidecar header 和
TSV 的 `seq/parent/pages` 字段。`DIFF_CKPT=1` 的锁步脚本在启动协调器前创建
`manifest.json`，成功保存后补齐链和 artifact 摘要；恢复工具读取任意链时
会先执行完整校验。

绑定内容包括：

- 实际使用的 Image SHA256（KERNEL 模式还包括 QEMU 导出的实际 DTB SHA256）；
- QEMU 可执行文件 SHA256；
- 仓库内 `qemu/VERSION` SHA256；
- 每个 `*.ram.gz`、`*.dev.gz`、`*.arch.gz`、`*.sys.gz`、
  `*.timer.gz`、`*.gic.gz` 的大小和 SHA256；
- `manifest.tsv` SHA256、页大小、首尾 seq 和条目数；
- KERNEL/地址/保存周期等低风险运行上下文（仅诊断，不替代状态校验）。

JSON 格式名为 `LCVX-checkpoint-manifest-v2`。早期没有 JSON manifest 的
7/8/9/10/11 列链仍可读取，但不会声称具有输入环境绑定。

## 2. 实现位置

- `sim/difftest/checkpoint.py`
  - `init-manifest`：流式计算输入文件摘要并原子写入 JSON；
  - `finalize-manifest`：计算压缩 artifact 和 TSV 摘要，再回读全链校验；
  - `read_manifest()`：保留旧链解析，同时对新链执行输入、QEMU、artifact、
    TSV 和链长度校验；
  - `restore-qemu`：额外校验传入的 QEMU/Image 与保存点摘要一致。
- `sim/difftest/run_lockstep_step.sh`
  - `DIFF_CKPT=1` 强制 `CKPT_EVERY>0`；
  - 要求每次使用新的 `CKPT_DIR`，避免把不同输入追加到同一条链；
  - 成功锁步后才 finalize manifest；失败时不发布“完成”摘要。
- `sim/difftest/checkpoint_manifest_smoke.py`
  - 使用 build 目录内临时空间，覆盖正向链校验和 artifact 篡改拒绝；
  - Make 入口：`make checkpoint-manifest-smoke`。

## 3. 验证证据

在 conda 环境 `lcvex`、低资源串行执行：

~~~
make checkpoint-manifest-smoke
make checkpoint-timer-smoke
make checkpoint-gic-smoke
make dtb-smoke
python3 -m py_compile sim/difftest/checkpoint.py \
  sim/difftest/checkpoint_manifest_smoke.py
bash -n sim/difftest/run_lockstep_step.sh
~~~

结果：

- manifest 反向 smoke 通过，篡改 artifact 被大小/SHA256 校验拒绝；
- `hard_timer` 真实 QEMU/DUT 联合 checkpoint 恢复仍通过；
- `hard_gic` 真实 QEMU/DUT 联合 checkpoint 恢复仍通过；
- 使用 `/tmp/Image-t80000` 的 KERNEL=1 受控锁步 100 条通过，按每 50 条
  保存得到 seq=49 base、seq=99 diff；生成的 manifest 同时绑定实际 FDT；
- 从该真实 Linux seq=49（仍处于 MMU 关闭的早期路径）恢复 RAM、sys/timer/GIC
  sidecar，QEMU `-incoming` 与 kernel DUT 联合执行 5 条通过；
- virt/GICv2 DTB compact 7701 字节，SHA256
  `a4f17ed497c6af38e37eb73776a292c7ffedb6be6f38fc7e4810399992b8c8b9`；
- 没有留下 QEMU、Verilator 或协调器长命进程；128 MiB 原始 RAM backend
  仍在脚本退出时清理。

典型链目录：

~~~
manifest.json
manifest.tsv
base-<seq>.*.gz
diff-<seq>.*.gz
~~~

JSON 只保存小型摘要；压缩 RAM/设备文件仍留在 `build/difftest`，不提交 git。

## 4. 限制与下一步

1. JSON 中仍保存当前工作区的绝对输入路径；跨机器发布 checkpoint 时，恢复
   端应提供同内容输入并在后续版本增加按 role 显式重绑定的 CLI。
2. 旧链没有输入摘要，不能用于要求环境可追溯的 Linux 恢复验收。
3. 还没有链压缩/自动淘汰；总大小上限仍为 512 MiB，超过即拒绝发布，避免
   删除 parent 导致断链。
4. `SCTLR.M=1` 的真实 checkpoint 联合恢复已在 handoff 056 完成；下一步从
   1M 之后向约 14.8M 受控继续 step 锁步，验证更深 TLB/Device memory 状态；
   不启动无上限长跑。
