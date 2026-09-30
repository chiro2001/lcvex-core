# T-20260919-006：corrected no-FP volatile SOF 交接

```text
task=T-20260919-006 state=done partial=false
acceptance_status=quartus-assembler-success-and-volatile-sof-frozen
physical_candidate=d00d566da86e034d6cf1651cdfb8ec50074ead13
remote=D:/Projects/fpga-altra/lcvex/build/T-20260919-006-b25-nofp-volatile-sof
evidence=docs/tasks/evidence/T-20260919-006.json
```

## 结论

从已验收的 T-004 post-STA 工程建立全新 task-owned clone，只调用一次 Quartus
Assembler。45 秒后 exit 0；stdout 和 asm report 均为 Successful、0 errors、0 warnings，
加载 `root_partition` 与 `auto_fab_0` 的 final snapshot。唯一配置制品为：

```text
file=catapult_a10.sof
bytes=36842110
sha256=04218557c73f1c41b84ef8223a65af9049469e499f60422ce6f96df07bd0abb7
quartus_checksum=0x31426358
design_hash=DAE55641F59510866D2107F480818B86
device=10AX115N4F40E3SG
```

源与 clone 的 539-file pre-manifest 完全一致，源 pre/post 也完全一致。Assembler 对
QDB 的变化恰为 3 个 asm report metadata 新增和 3 个 report/runlog 更新；0 删除，
`final/partitioned/synthesized` physical payload 变化为 0。SOF 1 个，POF/JIC/RBF/JBC/
SVF/JAM 全部 0。

## 边界与下一步

本任务没有运行 programmer、JTAG 或 terminal，未配置 FPGA，未 reset/power，也没有
Flash 行为。T-007 只能使用上述 bytes/SHA/checksum，经 15 MHz task-owned server 做
易失配置，再通过保留的标准 server 执行 device 1 / instance 0 console 测试。精确输入、
database allowlist 和 report hash 见
[`T-20260919-006.json`](../tasks/evidence/T-20260919-006.json)。
