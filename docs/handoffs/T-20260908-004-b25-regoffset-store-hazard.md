# T-20260908-004：B25 register-offset store hazard 交接

```text
task=T-20260908-004
state=done
base=5b2f4e6becf8dde9120f50efc8dcb9c4a9cdfc6a
head=88ea12c8c56b530c1aabe1151e02695e03e894bb
branch=fix/T-20260908-004-b25-regoffset-store-hazard
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-004
sent_at=2026-09-08T11:50:10+08:00
received_at=2026-09-08T11:50:10+08:00
reported_at=2026-09-08T12:12:10+08:00
timezone=Asia/Shanghai
files=rtl/lcvex_decode.sv,sim/difftest/run_t004_regoffset_store_hazard.sh
evidence=docs/tasks/evidence/T-20260908-004.json
```

## 结论

已修复 register-offset 单寄存器 store 的双依赖丢失。原译码先把 `rm`（地址索引）
登记到 `d.rs2`，随后 STR 分支又把 `d.rs2` 覆盖为 `rt`（store data），使
`id_reads`/`ex_id_gpr_hazard` 看不到紧邻的 index producer。T-003 记录的首错为：

```text
insn[2807] PC=0x440044c4 encoding=0x78377a80
strh w0, [x20, x23, lsl #1]
pre x20=0x44080000 x23=7
QEMU store=0x4408000e RTL store=0x44080000
```

实现保持 `d.rs2=rm/d.rs2_en`，并将 store data 改为独立的
`d.rs3=rt/d.rs3_en`；`d.mem_wdata` 和其余访存/扩展语义不变。架构状态仍只在
commit 边界更新。

## 验证

由 local resource-lock 执行的 runner 已退出码 0。existing `hard_reg_offset` 与
新增 45-word focused image 在三种配置均严格锁步通过：

- base：45/45；
- full cache：45/45；
- full cache + `MEM_DELAY_MODE=2`：45/45；
- 共六个矩阵项全部 PASS。

focused image 覆盖 STRB/STRH/STRW/STR、`rm!=rt`、`rm==rt`、XZR index、base/data
相邻 producer，并精确包含 `0x78377a80`（objdump 中为
`strh w0,[x20,x23,lsl#1]`）。三套 Verilator coordinator 均带 `--assert` 构建；未
关闭断言、差分比较或修改 reference/expectation。

精确命令、六项日志、source/tool/image SHA256、资源锁和限制见
[`T-20260908-004 evidence`](../tasks/evidence/T-20260908-004.json)。本次运行未使用
GamePC、Quartus、JTAG、assembler、SOF 或板卡。

## 边界与下一步

没有运行 100k random 或完整 Gate D；这必须在集成 T-002 后的单一候选 SHA 上执行。
集成者应按顺序：

1. cherry-pick `88ea12c8c56b530c1aabe1151e02695e03e894bb`；
2. 与 T-20260908-002 的 pre/post-index 修复合并，并重新跑受影响 directed union；
3. 重新生成 seed 1/2/3（所有 trace 齐全后再跑 coverage），再跑完整 Gate D；
4. 若 Gate D 通过，回到最新 physical timing top-N，再决定下一批 RTL 时序 lane。
