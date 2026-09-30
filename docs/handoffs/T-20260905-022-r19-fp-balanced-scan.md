# T-20260905-022：R19 FP balanced scan owner handoff

```text
task=T-20260905-022
state=review
base=50b046b69341c13c4b93fffd89e5dda7d81590ff
worktree_start=b1041c1347dfffe79e44d2006d013baa404c35eb
head=owner commit intentionally not self-referenced; see final owner report
branch=timing/T-20260905-022-r19-fp-balanced-scan
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-022
sent_at=2026-09-05T22:52:53+08:00
received_at=2026-09-05T22:52:53+08:00
reported_at=2026-09-05T23:11:14+08:00
```

## 结论

已将 `round_pack_scan` 中原先从 bit 255 到 bit 0 的 256-bit 线性 leading-one
搜索替换为固定层级、可综合的平衡优先编码器。focused Verilator 编译、RTL lint 和
运行均通过；新增测试覆盖 zero、special、`pre.lead_valid` 预解码旁路，以及 H/S/D
各 256 个可能 lead 位置。每个位置额外置位一个更低位，验证多位输入仍选择最高位。

当前只处于 owner `review`，没有宣称时序改善。合并候选上的受影响 L0–L2 与 fresh
Quartus STA 由集成者执行。

## 实现与保持的边界

- 256-bit magnitude 先划分为 16 个独立 16-bit group reduction，再做四个 quadrant
  reduction；quadrant/group 选择和选中 group 内的 16-bit nibble/pair/bit 选择均为
  固定层级结构。
- helper 输出 `[8]=valid`、`[7:4]=group`、`[3:0]=bit`；`round_pack_scan` 继续把
  `e` 精确计算为 `pre.exp2 + lead`。
- special 输入不扫描，零输入产生 `is_zero=1` 且不产生 lead/e；已有
  `pre.lead_valid=1` 路径仍直接采用预解码 lead。
- 未修改 `round_pack_p2`、state enum、任意 latency、公开端口、core、QEMU、QSF/SDC。
  DIV/SQRT 使用的既有 `leading_one_index` helper 也不在本任务写集内。

## Owner 验证

精确命令、工具版本、binary hash 和未运行项见
[`T-20260905-022.json`](../tasks/evidence/T-20260905-022.json)。结果摘要：

- Verilator 5.050 RTL lint：pass。
- focused 单线程编译：pass；运行：pass。
- 既有 R18 normal/tiny/pause/kill/reset/valid-drop 全绿。
- 新增 scan metadata：zero/special/predecoded 以及 H/S/D × 256 个 lead 全绿。
- legacy `FP_ITER=0` lint：pass；仅有既有未连接 `iter_busy/iter_done` 的 PINMISSING 警告。

## 待集成验证与风险

集成者需在 R19 batch candidate 上重跑受影响的 scalar、FP wrapper、P7 H/S/D/NEON 和
必要的 L2 strict union，并以同一 physical manifest 执行 synthesis → fitter →
signoff STA，查询 `pp_pre→pack_scan` 及后继 pack 锥、全局 top-N、面积和寄存器代价。
平衡结构是否改善实际 post-fit timing 不能由 RTL 仿真推断。setup 未闭合前继续关闭
assembler、bitstream、JTAG、上电和板测门。

```text
evidence=docs/tasks/evidence/T-20260905-022.json
board_policy=no assembler/bitstream/JTAG/programming/power-on/board test without explicit user permission
```
