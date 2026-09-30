# T-20260826-005：续跑 checkpoint provenance 交接

日期：2026-08-26（Asia/Shanghai）  
证据：[T-20260826-005.json](../tasks/evidence/T-20260826-005.json)

## 实现摘要

- `checkpoint.py` 增加 pending→complete 生命周期。严格 manifest 在
  `finalize_manifest()` 前不能被 `read_manifest()`/恢复路径接受；成功发布时
  校验 TSV SHA、chain 端点和全部 sidecar artifact。旧完整 v2 manifest 仍可读，
  但没有 provenance 时不能作为新 global resume parent。
- 增加 `verify-runtime` CLI，按 role 比较当前 Image/DTB/INITRD/QEMU/
  `qemu/VERSION` 的 size/SHA256，并可比较 QEMU CPU/machine/icount context。
- `run_lockstep_resume.sh` 在 `CKPT_EVERY>0` 时拒绝空/冲突输出目录、空 child
  窗口和无 parent manifest；启动前初始化 pending child manifest，保存
  parent manifest SHA、parent local/global seq、`global_seq_offset`、窗口/单核
  运行上下文；协调器成功后才 finalize。local TSV/header 保持不改写。
- `run_lockstep_step.sh` 的 DIFF_CKPT root 链也写入 strict lifecycle/root
  provenance 和 plugin/context，后续可安全作为 resume parent。
- 新增 `checkpoint_resume_manifest_smoke.py` 与 Make/registry 入口，覆盖
  N=1/500000 端点规则、pending 拒绝、parent/artifact 篡改、local→global 映射、
  restore 和路径冲突。

## 映射约定

```text
global_seq_offset = parent_global_seq + 1
global_seq        = global_seq_offset + local_seq
```

sidecar/TSV 的 `seq` 始终是窗口 local seq；首个 `CKPT_EVERY=N` 保存点为
`local_seq=N-1`。context 另存 artifact 的 local/global 闭区间及窗口半开端点，
避免把全局序号写回二进制 header。

## 验证

- `python3 -m py_compile ...`、`checkpoint_resume_manifest_smoke.py`：通过；
- `make checkpoint-manifest-smoke checkpoint-resume-manifest-smoke trace-manifest-smoke`：通过；
- `bash -n` 两个锁步脚本：通过；
- 小型 `DIFF_CKPT=1 CKPT_EVERY=10 MAX_INSNS=30` fixture：生成 3 个 local
  保存点并 finalize/read_manifest 通过。

精确命令和资源记录以 evidence JSON 为准。

## 限制/下一步

- 本任务不启动 Linux 长跑。T-004 历史 init-only lite 链会被新严格 resume
  入口拒绝，应从当前 QEMU 配置重新建立 strict root 链后再续跑。
- QEMU/RTL 本身的 CPU vmstate 兼容性仍需由后续 Linux 任务在严格 context 下
  验证；本任务不修改 QEMU fork 或 coordinator。
