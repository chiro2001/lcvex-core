# T-20260826-048：标量 ISA/阶段文档与 coverage 口径收敛

日期：2026-08-26（Asia/Shanghai）
基线：`4071ed356cfc0ec6109e61250d80831e19e6d2ba`
证据：[T-20260826-048.json](../tasks/evidence/T-20260826-048.json)

## 结论

- `docs/ISA_SCOPE.md` 顶部已从 P5a 旧快照改为 P6 本地冻结事实。RTL 中已
  实现的 LSLV/LSRV/ASRV/RORV、ISB/DSB/DMB、WFI/WFE/WFIT/WFET/SEV/SEVL
  不再列为未实现；逻辑移位寄存器形式 ROR、MOPS/MTE/RCpc、维护扩展、其它
  LSE128/多核和 PMU 等真实余量仍保留。
- `docs/ISA_GAPS.md` 将 T-043 Gate D 的定向/随机证据与 T-044 Linux 动态
  证据分开：Linux lite fresh-root 为 35,000,000 条并到达 `/init ready`，
  不把该动态窗口解释为所有实现族均已由 Linux 执行。
- `docs/DEVELOPMENT_PLAN.md` 已将 P2/P3/P5 记为完成，P6 记为本地退出满足、
  正式 Gate E/main/CI 待定，P7 保持未开始；未修改 ROADMAP、PROJECT_STATUS
  或任务表。
- coverage 仍使用原有 `EXPECT_RANDOM`/`EXPECT_ALL`、缺失判断和退出码，
  但输出改为 `expected_hit=60/60、observed_families=61`，消除 `61/60` 的
  seen/expected 混读。

## 验证

```text
python3 -m py_compile scripts/insn_coverage.py                         PASS
python3 scripts/insn_coverage.py --expect random <T-043 random_1/2/3.trace> PASS
  expected_hit=60/60、observed_families=61、总提交 298188
git diff --check                                                     PASS
```

完整命令、输入路径、源文件哈希和输出哈希见 evidence JSON。T-043/T-044
长跑本身沿用既有 evidence，不在本任务重复消耗资源。

## 边界与后续

本任务没有扩大 ARMv8.2 完整覆盖率定义，没有改变 RTL/测试期望集，也没有
启动 P7。T-045 checkpoint finalize 原子性与 T-047 PAuth 脏 sidecar 回归均已
关闭；MOPS/MTE/RCpc、维护扩展和其它标量余量不作为 P7 进入门槛。正式
`main`/CI 晋级仍后置，下一步是先冻结 P7 的状态、提交、差分与 checkpoint 协议。
