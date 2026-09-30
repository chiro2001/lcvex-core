# T-20260920-006：B25 RX 可观测性 Gate D 交接

## 结论

冻结合并候选 `85992f53`（tree `dd41ba4d...`）的完整 release-mode Gate D 全绿，耗时
约 15 分 21 秒。Gate worktree 没有 tracked 修改，assertion、QEMU 比较、coverage、
三组 100k 随机和 baremetal 均未跳过。

主要结果：

- `make test` 与 coverage PASS，覆盖点 `8760`；
- M2 base/cache 各 40 项 PASS；delay2 含 random smoke 共 32 项 PASS；
- P5a hardening 26 项、Gate C 7 组、MMU 3 组、P4b 5 组全部 PASS；
- random seeds 1/2/3 各 `100002` 次 RTL/QEMU commit 一致；
- ISA expected coverage `62/62`，总提交 `300006`；
- baremetal C 镜像 1104 bytes，锁步 200 条 PASS；
- 无残留 QEMU/coordinator。

权威 Gate 日志为 `build/agents/T-20260920-006/gate-d.lock.log`，352705 bytes，
SHA-256 `9b6f7ea9...b9810`。完整 artifact/tool hash 见
[`T-20260920-006.json`](../tasks/evidence/T-20260920-006.json)。

下一步只允许在该冻结 candidate 上新建 fresh no-FP Quartus synthesis/fitter/STA/UCP
任务；physical 全绿后再运行 assembler，最后做一次带 `RXDBG` 的易失板测。Gate D 本身
未使用 GamePC、Quartus、assembler、JTAG，也没有任何 Flash/reset/power 动作。
