# LCVEX 交接文档 045：AT/PAR_EL1 地址翻译

日期：2026-08-24（Asia/Shanghai）

## 背景

内核锁步在 `seq=5,927,033` 首次遇到 `MRS X23, DAIF`（`0xd53b4237`）。
此前交接误将该编码标成 PAR_EL1；实际字段是 `S3_3_C4_C2_1`。AT/PAR_EL1
仍是同一段内核路径的后续缺口，现一并补齐。

## 实现

- `MAINT_AT`：识别 `AT S1E1R/W`（`op0=01, op1=0, CRn=7, CRm=8,
  op2=0/1`），仅 EL1 可执行。
- AT 复用现有数据侧 MMU 请求/页表遍历；`S1E1W` 将写权限传给 MMU。
- 新增 `SREG_PAR_EL1`（复位 0，EL1 可读写）。AT 成功写入物理页号和
  LPAE 标记，失败写入 fault 位及 FSC；AT 本身不产生数据异常。
- MMU 关闭时按直接映射生成成功 PAR 结果。
- PAR 更新在核心唯一的主时序块完成，避免系统寄存器写路径与维护状态机
  多驱动。
- `SREG_DAIF`：`MRS/MSR DAIF` 读写 `PSTATE.DAIF[3:0]` 映射到寄存器
  `[9:6]`，立即数 `DAIFSet/DAIFClr` 路径保持不变。
- `STLR/LDAR`（含 B/H/W/X 宽度）按顺序核普通访存处理；不引入额外
  内存排序状态。

## 验证

`make lockstep-build-kernel` 已通过 Verilator 5.050 `-Wall --assert`。
本地 Linux 锁步（单物理核，`MAX_INSNS=6100000`）已通过，越过
`seq=5,927,033` 的 DAIF 与 AT/PAR 路径，并继续通过 `STLRB WZR,[X0]`；
最终 `seq=6,099,999` 正常达到上限。测试期间协调器约 138MB、QEMU 约
149MB RSS，`/tmp` 使用率约 43%。

## 后续

1. 记录并实现下一个未实现系统寄存器或指令编码。
2. 为 AT 成功/失败、PAR/DAIF 读写及 STLR/LDAR 增加裸机 microbench 和
   定向差分用例。
3. 再按 044 计划实现差分 checkpoint；当前全量 gzip checkpoint 保留为
   基线，避免在 ISA 缺口尚未收敛时扩大恢复面。
