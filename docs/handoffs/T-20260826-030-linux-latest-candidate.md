# T-20260826-030：最新 candidate SHA Linux continuation 交接

日期：2026-08-27（Asia/Shanghai）  
基线：`acd08bc2d9198830bbc3b9376af90b19fbc6642d`  
证据：[T-20260826-030.json](../tasks/evidence/T-20260826-030.json)

## 结果

- lite/main 均从 T-007 finalized parent local `4,999,999`、global `16,509,999`
  恢复，各连续 5,000,000 条逐指令锁步；没有 mismatch、timeout 或终止事件。
- 两个 child manifest 均 `complete/finalized`，全局最后保存点 `21,509,999`，
  parent/plugin/image/DTB provenance 全部通过。
- lite QEMU log 明确记录 `Run /init as init process` 和
  `LCVEX linux-lite /init ready`；这是同一 candidate SHA 的用户态入口证据。
- QEMU/Verilator 使用独立物理核（2/3、4/5），运行期间新产物只写
  `build/tmp/T-20260826-030`。

## Gate E 边界

本任务提供最新 SHA 的本地 continuation 与 `/init` marker 证据；Gate E 仍需
可信 CI/pr-difftest/nightly 最终结果、main 用户态/EL0 稳定窗口判据和统一审计。
