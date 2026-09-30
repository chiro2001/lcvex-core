# T-20260920-010：RX observability volatile SOF 交接

```text
task=T-20260920-010 state=done partial=false
acceptance_status=quartus-assembler-success-and-volatile-sof-frozen
physical_candidate=05ea248845f0b94b226ffe554e082980d89e452c
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-010-b25-rx-observability-volatile-sof
```

## 结论

从 T-007 已验收 post-STA 工程建立全新 task-owned clone，只调用一次 Quartus
Assembler。47 秒后同步 wrapper exit 0；stdout 与 asm report 均为 Successful、
0 errors、0 warnings，并加载 `root_partition` 与 `auto_fab_0` 的 final snapshot。
唯一配置制品为：

```text
file=catapult_a10.sof
bytes=36842100
sha256=7e9c60641c48fb4afff047f97f1d84865d32d24bd92aead26041035fd985a2f2
quartus_checksum=0x316ED173
design_hash=18B51F1418BE0B12479B55B745396DBF
device=10AX115N4F40E3SG
```

源与 clone 的 539-file pre-manifest 完全一致，源 pre/post 也完全一致。Assembler 对
QDB 的变化恰为 3 个 asm report metadata 新增和 3 个 report/runlog 更新；0 删除，
`final/partitioned/synthesized` physical payload 变化为 0。SOF 1 个，POF/JIC/RBF/JBC/
SVF/JAM 全部 0。

## 边界与下一步

本任务没有运行 programmer、JTAG 或 terminal，未配置 FPGA，未 reset/power，也没有
Flash 行为。T-011 只能使用上述 bytes/SHA/checksum 做易失配置，再用用户指定的
JTAG-MPSSE device 1 / instance 0 直连命令验证 BOOT/READY/RXDBG/status/PONG/echo。
精确输入、database allowlist 和报告 hash 见
[`T-20260920-010.json`](../tasks/evidence/T-20260920-010.json)。
