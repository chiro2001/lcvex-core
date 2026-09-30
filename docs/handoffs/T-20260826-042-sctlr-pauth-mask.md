# T-20260826-042：SCTLR_EL1 PAuth 写掩码修复

日期：2026-08-26（Asia/Shanghai）  
实现提交：`cc4e292f9cbaa5bc042bbcd0c461a0280b1e18e0`  
证据：[T-20260826-042.json](../tasks/evidence/T-20260826-042.json)

## 结论

T-041 main continuation 在 local `seq=2,139,121` 执行
`MRS SCTLR_EL1`（PC `0xffff8000800a2688`，编码 `0xd5381000`）时，
DUT 返回 `0xfcf4f91d`，QEMU 返回 `0x34f4d91d`。异或值
`0xc8002000` 精确对应 EnIA[31]、EnIB[30]、EnDA[27]、EnDB[13]。

这些位属于未纳入当前 ARMv8.2/P6 标量目标的 Pointer Authentication。
QEMU difftest 的 `sctlr_write()` 会将它们清零；RTL 原先只清除 SCTLR 高
32 位，Linux 后续一次 `MSR SCTLR_EL1` 因而把四个位错误保留下来。

本任务加入统一的 `SCTLR_EL1_WRITE_MASK=0x0000000037ffdfff`，正常 MSR
提交与 checkpoint restore 均使用该掩码，并用 SVA 保证高 32 位和四个
PAuth enable 位不会留存在架构状态中。reset 值仍为 `0x00c50838`，系统
寄存器仍只在既有 ID 级 commit 时机更新。

## 定向覆盖

新增 `hard_sctlr_pauth`：向 SCTLR 写入
`0x00c50838 | 0xc8002000 = 0xc8c52838`，随后立即 MRS。旧 RTL 在
base/cache 两配置均于 `seq=3` 暴露 `0xc8c52838 != 0x00c50838`；修复后
base/cache 各连续锁步 8 条全绿。

同时通过：

- `make test` 全部 P0/SV/Cocotb/编码器检查；
- `checkpoint-sys-smoke`、`checkpoint-sys-v3-smoke` 和
  `checkpoint-dut-smoke`；
- Verilator `-Wall` lint、Python 编译和 shell 语法检查。

## main 首错重放

只使用 T-039 finalized parent 的 local `seq=4,999,999`，没有使用 T-041
pending 失败 child。QEMU 与 Verilator 分别绑定物理核 1/0，从 global
`21,510,000` 开始连续严格锁步 2,500,000 条，覆盖 global
`21,510,000..24,009,999`，退出码 0。原首错映射到 global
`23,649,121`，本轮已再向后运行 360,878 条。

本次验证关闭 checkpoint 输出；运行期 128 MiB 展开 RAM 位于本 worktree
`build/tmp`，结束时已自动删除。保留的只有小型协调器/QEMU 日志，哈希见
evidence。

## 边界与下一步

- 本任务不实现完整 PAuth；PAC HINT 与 PAuth key 的既有 P6 shim 不变。
- 永久定向用例直接覆盖 MSR/MRS。restore 路径已复用同一掩码并通过 SVA
  与 sys v2/v3 smoke，但尚无专门注入脏 PAuth 位的旧 sidecar fixture。
- 将 `cc4e292` 集成回 `feature/p6-system-reg-shim` 后，RTL SHA 已变化，
  必须冻结新候选并在该 SHA 重新并行运行 Gate D 与 Gate E；不能把
  `a2dd216` 的 Gate 结果当作新候选验收。
