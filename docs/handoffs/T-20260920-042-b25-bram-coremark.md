# T-20260920-042：B25 BRAM CPU microbench 与 CoreMark

```text
task=T-20260920-042
state=done
base=5b9833ead9ad5027d1c98fd6a0f69a0d0d2b1784
implementation_head=84bebb3f66a80900940dffaf3bcd30b70a7c3a91
merged_code_sha=06565f0484d204da7cedb31b70f17b24868b26e7
branch=feature/T-20260920-042-b25-bram-coremark
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-042
reported_at=2026-09-20T23:28:56+08:00
```

## 结论

T-042 已完成本地 L0–L2 验收。单一 64 KiB BRAM 镜像新增 `t/v/c`：`t` 的 24 项
整数 correctness suite 输出 `MBPASS 24 8679CF21`；`v` 用官方 2 KiB performance
seed 跑一次 CoreMark，full-SoC 原始输出为 seed/list/matrix/state
`E9F5/E714/1FD7/8E3A`、`cycles=1479468`、`score=INVALID`；`c` 保留上游自动标定，
只有官方 validation、CRC 和至少 250,000,000 个 25 MHz target cycle 全满足时才会
输出 `CMRESULT VALID`。host parser 还会逐项交叉核对上游原始报告，不能只相信固件
的 `VALID` 字样。

最终 payload 为 20,448 bytes，BSS 结束于 `0x58f8`，未进入保留栈
`[0xf000,0x10000)`。BIN SHA-256 为
`ddb27ff2ffdfb595c3821a20af262f4e3ae95c1e680bf5530e2865bf45b6c56d`，MIF
SHA-256 为 `d56386b0714c65bab955cb91112d510b31f4290f80281f86c7feabdd6988d7d0`。
两次 clean build 的 ELF/BIN/HEX/MIF/manifest 逐字节相同。

## 实现边界

- CoreMark 固定为 EEMBC `v1.01`、commit
  `cfa9ab377835911f23d9b0831c7be302ed1f58de`；许可证、README 和六个算法/框架
  文件逐字节保存，构建不联网。
- port 为 LP64、single-context、2 KiB `MEM_STATIC`、无 libc/heap/FP/DDR；实际
  GCC flags、source hash 与 artifact hash 写入生成 manifest。
- `PLAT_STATUS+0x40` 新增只读 64-bit `logic_clk_25` cycle counter；reset=0、每拍
  加一、请求接受时原子采样、写入忽略。没有使用 `CNTVCT/CNTPCT` 或 host wall time。
- `p/?/m/d/echo` 保持兼容；`t/v/c` dispatch 类别为 `6/7/8`。短自检的 verbose
  上游报告被抑制，只输出有界 summary；完整 `c` 的 UART 输出全部位于正式计时区间
  之外。
- parser 拒绝短窗口冒充分数、错误 CRC/seed/frequency、重复结果、伪造定点分数、
  上游 raw/summary 不一致和缺少 upstream success marker。

## Microbench 暴露并关闭的 RTL 缺陷

首次 `v` 在 `coremark_main+0x18` 的第二条连续 `STP` 后停止提交。诊断显示 core 已
记录 dmem request accepted，但 coherence client 停在 `C_L1_WAIT`、D-L1 已回
`ST_IDLE`：probe 与 CPU request 同拍时，D-L1 曾同时拉高两个 `ready`，时序逻辑却
只按优先级接收 probe，导致 CPU 请求丢失。

提交 `79e510aa` 使 probe 有效时 `u_req_ready=0`，并增加 SVA 与同拍定向用例；独立
L1D-WB 回归为 `operations=11 accepted=66 PASS`。修复后 behavioral 和
Quartus-21.4 registered-timing 两条 full-SoC 路径均通过；vendor 变体还完成
262,144 次空轮询和 2,359,306 次提交。

## 后续边界

本任务未访问 GamePC/真板，也未运行完整 `c`（RTL 仿真十秒 target window 没有
验证收益）。因此尚不能报告 CoreMark 分数。下一步由 T-043 在冻结合并 SHA 运行
完整 Gate D，再依次执行 T-044 fresh physical、T-045 单次 assembler 和 T-046
易失 SOF 真板 `t/v/c`；T-046 结束后必须恢复并证明 exact golden。

完整命令、hash、资源与负例结果见
[`T-20260920-042.json`](../tasks/evidence/T-20260920-042.json)。

集成者已在 merged code SHA `06565f04` 复跑 L0、L1D-WB 与 behavioral L2，结果
全绿且 payload/manifest hash 与 topic 完全相同；T-042 因此关闭，后继为 T-043。
