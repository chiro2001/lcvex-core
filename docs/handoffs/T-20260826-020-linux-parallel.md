# T-20260826-020：strict Linux lite/main 并行续跑交接

日期：2026-08-26（Asia/Shanghai）  
验证基线：`1b92a22a55b856908be34720b46f820ff5aea0e8`  
证据：[T-20260826-020.json](../tasks/evidence/T-20260826-020.json)

## 结果

- lite 与 main 均从 T-007 的 finalized strict parent local `seq=4,999,999`、
  global `seq=16,509,999` 恢复，在同一 RTL/QEMU/plugin/coordinator 基线各连续
  `5,000,000` 条逐指令锁步。
- 两条运行均以协调器退出码 0 结束，最后保存点 local `4,999,999`、global
  `21,509,999`；`coord.log` 的每个 checkpoint 和最终提交均为 `OK`，没有
  mismatch、timeout、PSCI reset/off 或 WFI/WFE 终止。
- child manifest 均为 `status=complete`、`state=complete`、
  `lifecycle=finalized`，10 个 artifact entry；manifest、TSV、parent manifest
  hash 和 restore 输入均可审计。完整命令、输入 SHA、QEMU SHA 和产物大小见
  evidence JSON。

## 运行摘要

| child | CPU | kernel/入口 | local/global 保存范围 | manifest SHA256 |
| --- | ---: | --- | --- | --- |
| lite-21m | 2 | no-FP lite，`rdinit=/init` | `[499999,4999999]` / `[17009999,21509999]` | `5787823115770336fa4cab618cb20e55f1c81cbaa966a7b90eaf42afeb5880d2` |
| main-21m | 3 | main，`rdinit=/bin/sh` | `[499999,4999999]` / `[17009999,21509999]` | `f2c5ad90d85c33c4b5e9939a1fc1b174245886f51e8055da71941c33b46f2279` |

## 资源与现场

- 每线使用一个物理核（CPU 2/3），没有申请 75% 升级；运行期间新产物只写
  `build/tmp/T-20260826-020`，未向系统 `/tmp` 写入新的大文件。
- child chain、coord/QEMU log 和 manifest 保留在 `build/tmp`/`build/agents`，
  不进入 Git；T-007 parent 保持只读，不覆盖、不删除。

## 边界与后续

- 该窗口是 P6 Linux continuation 证据，不宣称 Gate E；Gate E 仍需冻结候选
  SHA 上的 Gate D/可信 CI、early-boot 与稳定用户态判据。
- T-019 的 maintenance 修改完成后，不能复用本 child 作为新 SHA 的验证结果；
  应从同一 parent 新建带新 source SHA 的 continuation。
