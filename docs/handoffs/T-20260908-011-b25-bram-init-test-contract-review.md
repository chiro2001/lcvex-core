# T-20260908-011：B25 BRAM init TB oracle contract review

```text
task=T-20260908-011
state=done
base/head=8f8faac30119c1db734a2ecd0394b4aad24e881b
branch=verify/T-20260908-011-b25-bram-init-test-contract-review
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260908-011
sent_at=2026-09-09T00:01:15+08:00
received_at=2026-09-09T00:01:15+08:00
reported_at=2026-09-09T00:09:45+08:00
files=docs/tasks/evidence/T-20260908-011.json,docs/handoffs/T-20260908-011-b25-bram-init-test-contract-review.md
tests=read-only contract review；未build/未连接 Quartus、GamePC、JTAG、板卡
evidence=docs/tasks/evidence/T-20260908-011.json
```

## 一次性结论

当前 `tb/sv/lcvex_bram_init25_tb.sv:115` 的
`64'h9100_001f_5800_17c0` 不是可维护的长期 oracle：它把首条 LDR literal 的
PC-relative `imm19` 和下一条 MOV SP 编码一起冻结在一个 64-bit word 中。literal
pool 或 link layout 一变，即使 `_start` 仍正确，测试也会假失败。当前 TB 还只加载
HEX，不能证明 BIN/HEX/MIF 互相一致；zero-fill 只抽查 `0xF000` 一个 word。

推荐的非循环方案是两层组合：

1. 用独立的 ELF structural decoder + cross-artifact checker 生成 expected image；
2. TB 运行时读取该独立 expected file，按字节拼出 debug word，同时保留边界读请求。

结构 decoder 应从 ELF 符号/载荷计算 LDR `imm19` 目标并验证目标 literal 等于
`__stack_top=0x10000`，而不是比较固定 `imm19`；第二条指令按 ADD-immediate
的字段验证 `MOV SP,X0` 语义。checker 再完整比较 ELF-derived load image、BIN、
HEX、8192 条 64-bit little-endian MIF 和 64 KiB zero padding。

生成 include/parameter 可作为 hash-bound 派生便利，但不能从 DUT HEX/MIF 复制，
也不能成为唯一 oracle。直接更新常量和只替换 `c0` 为 `00` 均拒绝。

## 必须保留的故障注入

至少覆盖：缺失/错误 image path、首字节/首指令篡改、LDR imm19 篡改、MOV SP
篡改、32-bit word/byte reverse、MIF byte-lane 交换、HEX/BIN/MIF 单点不一致、
zero-fill/stack 非零、`0xFFFC`/`0xFFFF` 合法访问、`0x10000` exclusive top fault、
跨边界 fault、debug lane/address rotation 以及 stale expected file。完整矩阵和每项
检测层级见 evidence。

## T-007 边界

T-007 的最小写集仍只是 QSF 的一条
`set_global_assignment -name VERILOG_MACRO SYNTHESIS`、必要的 manifest/hash
闭合和对应静态 checker/evidence；不应修改本 TB，不应把 DUT/debug 输出反推为
expected，也不应通过改 RTL 规避 Error 19544。T-011 未读取 T-010 worktree，未做
任何重型或外部操作。

下一步另立 oracle 实现任务；完成后在 physical candidate 中运行对应 BRAM TB 和
cross-artifact checker，再决定是否允许继续 Quartus flow。
