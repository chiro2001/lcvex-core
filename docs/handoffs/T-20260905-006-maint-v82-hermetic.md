# Handoff T-20260905-006：p6-maint-v82 hermetic entry

```text
task=T-20260905-006
state=review
base=8383cb05808393cc2ad391af261089321d0e2288
head=final-documentation-tip (see final branch HEAD below)
implementation_head=f021315bcebdb76e51b5944520637f7c8bd18453
branch=infra/T-20260905-006-maint-v82-hermetic
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-006
sent_at=2026-09-05T04:53:41+08:00
received_at=2026-09-05T04:53:41+08:00
reported_at=2026-09-05T04:55:00+08:00
```

## 结论

`Makefile` 的 `p6-maint-v82` 目标现在在 image 生成和六个锁步窗口之前显式执行：

```make
mkdir -p build/difftest
$(MAKE) -C qemu/plugins
```

因此 clean worktree 不再因 `build/difftest` 缺失或本地
`qemu/plugins/lcvex_difftest.so` 缺失而提前退出。维护程序、参考结果、锁步协议、
RTL、QEMU fork/source/patch、QSF/SDC 均未修改。

## 入口顺序与边界

目标依赖仍先构建 base 与 I+D+L2 两个 Verilator coordinator；recipe 随后创建
`build/difftest`、调用仓内既有 plugin Makefile、生成三份维护 image，最后按原顺序
执行六个窗口：

1. `hard_maint_v82` + base coordinator；
2. `hard_maint_v82` + L1D/L2 coordinator；
3. `hard_maint_v82_mmu` + base coordinator；
4. `hard_maint_v82_mmu` + L1D/L2 coordinator；
5. `hard_maint_v82_el0` + base coordinator；
6. `hard_maint_v82_el0` + L1D/L2 coordinator。

本任务只解决本地入口自包含性；外部 QEMU binary、glib/QEMU plugin headers 和
正常锁步运行环境仍是既有前置条件。recipe 不改变 `MAINT_V82*` 上限或任何测试
image 内容。

## 轻量验证

精确命令、source SHA、起止时间和结果见
[`docs/tasks/evidence/T-20260905-006.json`](../tasks/evidence/T-20260905-006.json)。

- `git diff --check`：PASS；
- `make -n p6-maint-v82`：PASS，输出顺序确认 `mkdir -p build/difftest` 和
  `make -C qemu/plugins` 位于 image 生成及六窗口之前；
- `python3 scripts/test_registry.py --check --check-consistency`：PASS（73 项）。

按任务边界未运行实际 `make p6-maint-v82`、Verilator/QEMU 锁步或其它重型测试；
实际 clean-worktree 六窗口运行由重型队列在合并 SHA 上完成，且可能暴露独立的
T-20260905-005 RTL/SYS/MMU 问题。未运行 Quartus、JTAG、SOF、烧写或上板测试。

## Ledger 时间戳 correction record

只读核对显示 dispatch commit `cb2a2c91a8e5c3248e5969e0d487853ab5f66146`
的 author/commit 时间为 `2026-09-05T04:52:06+08:00`，而 active JSON 当前记录
`created_at/updated_at=2026-09-05T04:57:00+08:00`。本 lane 的 writes 不包含
`docs/tasks/active/T-20260905-006.json`，因此没有越权改写；该不一致已在
handoff/evidence 留下 correction record，须由集成者决定是否修正 active ledger。

## 修改文件

- `Makefile`
- `docs/handoffs/T-20260905-006-maint-v82-hermetic.md`
- `docs/tasks/evidence/T-20260905-006.json`

## 下一步

集成者将本提交 cherry-pick 到 Round16 candidate 后，在 clean worktree 运行一次
完整 `make p6-maint-v82`，记录六窗口逐项结果；入口修复通过不等价于维护程序或
SYS/MMU 路径验收通过。
