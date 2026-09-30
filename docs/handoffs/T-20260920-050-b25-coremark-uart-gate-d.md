# T-20260920-050：UART 背压修复 payload Gate D

```text
task=T-20260920-050 state=done
candidate=5b33c451317442f385dd828ece8c3bf829289d14
candidate_tree=e026b2ce52a673aeb526e0f9c3b508ccfa557d5e
branch=verify/T-20260920-050-b25-coremark-uart-gate-d
task_worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-050
gate_worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-050-gate (detached)
```

## 结果

T-049 修正的 UART 有限 TX 等待上限在冻结代码树 `e026b2ce` 上完成完整 Gate D：
`152 green / 0 red`，覆盖率 `8760`，M2 base/cache `40/40 + 40/40`，delay2 `32/32`，
P5a-Hardening `26/26`，Gate C `7/7`，P5a MMU `3/3`，随机 seeds 1/2/3 各 `100,002`
commits，ISA 覆盖 `62/62`（随机 trace 总计 `300,006` commits），baremetal-C `200/200`。
末尾 marker 为 `PASS: Gate D 系统回归全部通过`。没有 skip、关闭断言或修改参考结果。

锁步候选的 Gate D 在 detached worktree、冻结 SHA `5b33c451` 执行。resource-lock `local`
启动门槛为 `MemAvailable >= 8192 MiB`，并行模式由 `scripts/run_gate_d.sh --parallel`
处理。

L0 在同一 frozen SHA 上再构建一次：BIN 20,448 bytes，SHA
`241b0ce4dface8c4a9db782b63e4ada8674f5c8b51c00f228a795e98fc1aedab`；MIF SHA
`0743295f90cb75e4d21092012c723bc9da4b6d055f13d46958cbd572bd610a2f`；与 T-049 两次
clean build 的 MIF `cmp` 一致。Affected L0-L2 已由 T-049 在完全相同 source tree SHA
`e026b2ce` 运行通过：完整 host CoreMark port tests 和 behavioral/vendor-timing B25
SoC smoke；registered-vendor JTAG-UART 模型以每 65,536 logic cycles drain 一字节，完整
CMSELF transcript 被 strict parser 接受。

## Gate log / 限制

- Gate log：`build/agents/T-20260920-050/gate-d.log`，410,388 bytes，SHA-256
  `8acb603bd7ea6b47c9f7ab6583c48d0c84166cb0200f594fbd9df6be4ed91d5e`；
- exact candidate L0 log：`build/agents/T-20260920-050/l0-verification.log`，SHA-256
  `713e8890cf70ec232f10a8f2b326162fc2c0de26dfa786cc4c46e4a63fe3f2d1`；
- corrected payload manifest SHA-256：
  `d9a087765da1839ed4a2847132999e8755807300f06c015b6f5bae4cd632cd3a`。

本任务没有跑 Quartus、JTAG 或板卡。T-051 将为该候选的更新 MIF 做 fresh physical；
GamePC 目前尚未枚举 MPSSE Blaster，T-053 板测仍需等设备回来。真板 full `c` 和有效
CoreMark 分数尚无证据。

结构化结果见
[`docs/tasks/evidence/T-20260920-050.json`](../tasks/evidence/T-20260920-050.json)。
