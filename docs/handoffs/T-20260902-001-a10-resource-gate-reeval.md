# Handoff T-20260902-001：A10 Resource Gate Reeval

```text
task=T-20260902-001
state=review
base=73897911a81aa8a8833a4d6d457f3e27a01e3c29
head=0e158b7579ac902c119f1d0909248e42cbe51bf3
branch=verify/T-20260902-001-a10-resource-gate-reeval
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-001
sent_at=2026-09-02T01:29:20+08:00
received_at=2026-09-02T01:30:00+08:00
reported_at=2026-09-02T03:01:45+08:00
```

## 摘要

在远端 candidate（`D:\Projects\fpga-altra\lcvex\build\T-20260902-002\candidate`）的隔离 probe（`D:\Projects\fpga-altra\lcvex\build\T-20260902-001-probe`）中分阶段运行 Quartus synthesis。

- 阶段 A decode-only：PASS，57 s，PM 718 MB。
- 阶段 B L1D/L2 standalone M20K：PASS，L1D 25 s / L2-reduced 36 s / L2-default 108 s。
- 阶段 C 真实 SoC：
  - candidate 原样 synthesis **FAIL**：Quartus 21.4 elaboration 兼容错误，非资源 OOM。
  - 隔离 no-FP probe（`A64_FP_SIMD=0`）**PASS**：362 s，PM 2.57 GB，ALM 81.5k，BRAM 247k bits。
  - 隔离 full-FP patched probe：elaboration 通过后 synthesis 运行 54.2 min，峰值 PM 13.24 GB，仍未完成；为收尾手工停止。峰值低于安全窗口，说明资源不是阻断。

## 门限结论

- 历史 35 GB 先验不应作为一票否决。
- 当前 host 安全提交窗口约 36 GB。
- 实测 SoC synthesis 峰值：no-FP 2.57 GB；full-FP 观察峰值 13.24 GB。
- fit/STA/SOF 具备继续逐阶段试验的余量；仍需单作业+采样。
- 外部资源介入条件：实测峰值超过 ~36 GB，或磁盘不足，或出现新的 elaboration/时序问题。

## 阻断

真实 full-FP synthesis 未在本任务内完成；主因是候选 RTL 的 Quartus 21.4 兼容错误（fp_scalar loop limit、NEON out-of-range），不是内存。隔离补丁绕过后可跑，但尚未合入。

## 下一步

1. 正式修复三处 RTL Quartus 兼容问题并跑 Verilator/lint。
2. 重跑真实 full-FP synthesis，获取最终资源估计。
3. 然后按单阶段队列进入 fitter → STA → assembler/SOF，不再受 35 GB 先验门限制。

## 证据

- `docs/tasks/evidence/T-20260902-001.json`
- `docs/FPGA_A10_RESOURCE_GATE_REEVAL.md`
- 远端 `D:\Projects\fpga-altra\lcvex\build\T-20260902-001-probe\**`
