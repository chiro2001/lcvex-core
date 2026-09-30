# T-20260826-002：trace manifest 与全局切片交接

日期：2026-08-26（Asia/Shanghai）  
实现提交：`9afa97e`  
前置提交：`c803f90`  
证据：[T-20260826-002.json](../tasks/evidence/T-20260826-002.json)

## 已完成

- 新增 `scripts/trace_manifest.py`，为 gzip/明文 trace 生成
  `LCVX-trace-manifest-v1`；绑定 trace artifact、Image/DTB/QEMU/plugin/
  `qemu_version` 输入的 bytes/SHA256、压缩 codec、init/header 摘要和全局
  半开区间 `[seq_start, seq_end)`。
- gzip 使用严格单 member 流式读取，CRC/截断/尾数据/拼接 member 均拒绝；
  manifest 与切片输出都采用目标目录内临时文件后原子替换。
- `scripts/trace_slice.py` 按 global→local 映射切片，保留 parent init/header，
  保存 parent manifest/trace/range/selected commit 摘要；支持非零起点和二级切片，
  明确与协调器 `--skip <global_start>` 的关系。
- `scripts/trace_manifest_smoke.py` 覆盖 gzip/明文、输入和 payload/parent/init
  篡改、压缩流损坏、全局/二级/尾部切片、移动 artifact、边界和路径冲突。
- Make 入口：`trace-manifest-smoke`、`trace-slice-help`；设计约束补入
  `docs/DIFFTEST_QEMU_PLAN.md`。

## 验证结论

以下均在 `conda:lcvex`、本地低资源条件下通过：

- `python3 -m py_compile scripts/trace_manifest.py scripts/trace_slice.py scripts/trace_manifest_smoke.py`
- `python3 scripts/trace_manifest_smoke.py`
- `make trace-manifest-smoke trace-slice-help`
- `make checkpoint-manifest-smoke`
- `VERILATOR_JOBS=4 make checkpoint-dut-smoke`

精确命令、版本和退出码以 evidence JSON 为准。

## 边界与已知限制

- manifest root 要求显式绑定五类运行输入；Linux trace 的 DTB 必须使用与实际
  QEMU machine 相同的导出文件。child 输入记录从 parent 继承，目录移动时按相对
  路径重新解析。
- trace 行本身没有 seq 字段，因此全局起点来自 root `--seq-start` 或 parent
  manifest；不能从没有 provenance 的 `tail=N` 文件自动推断原始起点。
- 本任务没有修改 QEMU fork、`checkpoint.py` 或协调器的 `--skip` 实现，也没有
  启动真实 Linux/QEMU 长跑；完整 trace/checkpoint 不进 Git。
- 集成者合并后必须在 merge SHA 复跑任务要求的 L0–L2，并补齐 evidence 的
  `merge_sha`，之后才可归档任务。

## 下一步

1. 集成者 cherry-pick 本提交，在合并 SHA 复跑 L0–L2。
2. 若通过，归档 T-002；再单独登记 Gate runner/trace release 大小策略任务，
   不把本 smoke 宣称为 Gate E 或 Linux 长跑验收。
