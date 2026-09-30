# T-20260826-045：checkpoint finalize 原子发布

日期：2026-08-26（Asia/Shanghai）
基线：`2b930ec06f4c2353b627cb952e2171421c1d4e9d`
实现提交：`5c509b07224f01aaf68aed74fb30c8cf08485001`
证据：[T-20260826-045.json](../tasks/evidence/T-20260826-045.json)

## 结论

已修复 `finalize_manifest` 的发布顺序缺陷。函数现在先构造候选完成态，调用既有
`_validate_manifest_meta`（包含输入、artifact、TSV、chain 和 parent/provenance
递归校验），只有全部通过后才调用 `_write_json_atomic`。发布后不再依赖一次
`read_manifest` 才发现错误，因此 late parent/plugin 失败不会留下伪 finalized 链。

候选态使用独立顶层字典并复制 strict context；字段格式、legacy v2 兼容、strict
root/resume provenance、parent binding 和已 finalized 链的既有语义均保持不变。

## 永久回归 fixture

`checkpoint_resume_manifest_smoke.py` 新增严格链：parent 记录 plugin A，child
记录 plugin B；两边 sidecar 与 TSV 均合法。校验确认 finalize 抛出具体的
`输入 plugin 与 parent 摘要不匹配`，child `manifest.json` 原始字节和
`status/state/lifecycle/finalized/complete` pending 值完全不变，且失败后
`read_manifest` 继续拒绝 pending 链。

旧代码红测已复现：同一 fixture 在基线实现中退出码 1，错误发生在写 complete/
finalized 之后，原始字节断言失败；修复后该 fixture 及其它 smoke 全部转绿。

## 验证

- `py_compile`：通过。
- `make checkpoint-manifest-smoke checkpoint-resume-manifest-smoke`：通过。
- `make trace-manifest-smoke`：通过。
- 临时 legacy v2（无 lifecycle/provenance）finalize/read probe：通过。

本任务未运行 Gate/Linux 或 sys 联合 checkpoint smoke；资源限制为单核、4 GiB，
且未修改 QEMU、active task、`TASKS.md`、`PROJECT_STATUS.md` 或 `ROADMAP.md`。
