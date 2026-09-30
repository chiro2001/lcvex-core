# T-20260826-035：P1 QEMU trace 超时 flush 修复交接

日期：2026-08-26（Asia/Shanghai）  
基线：`a35d76a`  
提交：`7b4d820`  
证据：[T-20260826-035.json](../tasks/evidence/T-20260826-035.json)

## CI 根因

CI run `32935884451` 的 PR-difftest artifact 显示，首步 `make difftest` 在
`run_qemu.py` 解析 `/build/difftest/p1_run0.trace` 时收到 `FileNotFoundError`。
后续 hazard/random 也因 trace 不存在失败；lockstep 则等待不到 QEMU socket，
并非 RTL mismatch。nightly 的 seed/delay 失败同样属于前置 trace/lockstep
失败后的级联结果。该 run 最终被取消，不能作为 Gate E CI 通过证据。

根因是 `subprocess.run(timeout=10)` 的超时路径直接 SIGKILL QEMU，QEMU plugin
的 gzip `atexit` flush 没有机会执行。

## 修复与验证

- 改用 `subprocess.Popen`；超时先 `SIGTERM` 并等待 2 秒，只有不退出才
  `SIGKILL`。
- timeout smoke 生成并解析 gzip trace（17 条记录，首条 `init`）。
- `make difftest-qemu`：两次各 16 条与参考模型一致，输出完全确定。

## 后续

推送包含 `7b4d820` 的集成 SHA 后重跑 PR-fast/PR-difftest/nightly；在新 run
完成前不把 CI 作为 Gate E 证据。
