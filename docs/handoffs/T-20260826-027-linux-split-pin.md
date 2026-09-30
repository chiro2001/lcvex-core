# T-20260826-027：Linux split-pin continuation 交接

日期：2026-08-27（Asia/Shanghai）  
基线：`6031796`  
证据：[T-20260826-027.json](../tasks/evidence/T-20260826-027.json)

## 结果

- lite/main 均从 T-007 finalized parent local `4,999,999`、global `16,509,999`
  恢复，各连续 5,000,000 条逐指令锁步；两条最后提交均 `OK`，没有 mismatch、
  timeout、PSCI reset/off 或 WFI 终止。
- 两个 child manifest 都是 `status=complete/state=complete/lifecycle=finalized`，
  10 个 artifact entry；parent manifest、image/DTB、QEMU 和 parent plugin
  `33f25bb…` hash 全部通过 provenance。
- QEMU 与 Verilator 已拆到不同物理核：lite 2/3、main 4/5；实际只使用 4 个
  单线程物理核，资源上限可提升到 75% 但不制造同核竞争。

## Gate E 边界

该窗口把 Gate D candidate 的 Linux continuation 证据推进到 global `21,509,999`，
但仍不是 Gate E 完成：需要同一 SHA 的明确 early-boot/EL0 `/init` 稳定判据、
可信 CI/QEMU patch replay 和失败可复现链。
