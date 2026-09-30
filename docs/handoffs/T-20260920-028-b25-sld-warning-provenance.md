# T-20260920-028：Quartus SLD warning 16788 provenance 交接

task=T-20260920-028 state=review analysis_base_sha=58f721194a8975d98b1b746513183faeeb305f13 evidence_parent_sha=22ce45e2f86fcb67e34e363850868c27f81244d1 branch=verify/T-20260920-028-b25-sld-warning-provenance worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-028 sent_at=2026-09-20T16:40:18+08:00 received_at=2026-09-20T16:40:18+08:00 reported_at=2026-09-20T17:06:41+08:00 review_correction_at=2026-09-20T17:06:41+08:00 files=docs/tasks/evidence/T-20260920-028.json,docs/handoffs/T-20260920-028-b25-sld-warning-provenance.md tests=git-diff-check,jq-validation-sha256 blockers=T027-global-zero-contract-pending-integrator next=review-and-adopt-or-reject-source-qualified-contract

## 结论

已完成只读 provenance 审计。T027 不再含 tracked RTL 的 'lcvex_decode imm[63]_2'；其唯一去重后的 Warning 16788 身份是 Quartus 21.4 生成的：

'Net "ir_in_2d[2][4]" does not have a driver at alt_sld_fab_0_altera_sld_jtag_hub_1920_oerl7dy.vhd(243)'

T017 与 T027 的 synthesized 'alt_sld_fab_0.sopcinfo' 原始 SHA 分别为
'238dc70e4f18d5ab0ca636c53f2e2d4da095e285d24d5b8576cf4833061a974f' 和
'ec3b82411cbe2cc4830aa29434d0514b7ebff3fa0ee3d2de4e9f31b0bc507e4d'；去掉唯一 XML
时间戳注释后均为 'b127700cfe079af2b01bfc5bcfea3926d2d97d7317d79cad943658d117ff532e'，
diff 为 0。两次生成均为同一 2-node SLD fabric：'COUNT=2'、'N_SEL_BITS=2'、
'N_NODE_IR_BITS=5'，EMIF endpoint 为 type 132 / IR 3，JTAG-UART endpoint 为
type 128 / IR 1，node_0/node_1 宽度为 1/3。

现有 raw metadata 支持“第三个数组行/第五位的确定性 vendor padding”判定，但临时生成
VHDL 不在现场，无法证明 'ir_in_2d' 的内部精确 consumer 或把 12 个 Lost-fanout
寄存器逐一归因到该单网。因此报告保留这个限制，不脑补 VHDL 行为。

## Warning 唯一身份

- T017：syn.rpt 的 decoder 详细行、decoder 摘要行、generated 摘要行，加上 syn.smsg
  的 generated 详细行；唯一身份 2 个（decoder + generated）。
- T023 old 与 fixed-mode old-baseline self-check：各自仅 decoder 身份，详细/摘要各一行，
  唯一身份 1 个。fixed-mode 仍使用 'd1a1d2f...' 旧 decoder，是预期 fail-closed 自检。
- T027：syn.smsg 一条 generated 详细行 + syn.rpt 一条 generated 摘要行，唯一身份 1 个；
  'lcvex_decode.sv(1806)' 在 syn.rpt/smsg/summary 中均为 0 次。

完整 raw 路径、SHA256、行号和 detail/summary 归一化表见
[证据 JSON](../tasks/evidence/T-20260920-028.json)。

## 'ir_in_2d' 与 Lost fanout 边界

'sopcinfo' 只有 'node_0'（encoded ID '201354752'，IR 1/type 128）和 'node_1'
（encoded ID '203451904'，IR 3/type 132），没有 'node_2'。Warning 的
'ir_in_2d[2][4]' 因而不对应任何暴露 endpoint；raw warning 明确报告没有 driver。
唯一可审计的 consumer 上下文是生成的 'altera_sld_jtag_hub' entity。

T017/T027 报告均列出同一组 12 个 generated hub 内部寄存器因 'Lost fanout' 被移除：
6 个 'irf_reg' 和 6 个 'shadow_irf_reg'，随后 'Total Number of Removed Registers = 12'。
这与未使用/填充 IR 状态一致，但没有临时 VHDL/netlist 就不能证明一对一因果。

## 历史正向板测边界

T020 精确消费 T017 candidate/tree，唯一 SOF SHA 为
'd9bc9a964be9b0c0e98b16643a5d9ca44a4bce00b3694915c84714552a0ed2fd'。T021 对该 SOF
完成 checksum/JTAG-ID 配置，枚举 'Virtual JTAG #0'、'Signal Tap #0'、'JTAG UART #0'、
'JTAG PHY #0'，终端达到 'LCVEX25 BOOT'、'READY'，并观察到 RXPATH 三层一致的
'0x0000A43F'。这证明同一 T017 SLD topology 曾被真实配置并运行到 BOOT/READY；由于
T017/T027 normalized sopcinfo 完全相同，topology identity 也覆盖 T027。

这不是新板测，也不是完整功能通过：T021 同时记录 'DDR-FAIL'、未达到 CLOCK25/pong/debug，
且 CPU 可见 RX load/writeback 仍错误，随后回滚 Golden。不能用它把 T027 的 synthesis
warning 视为已解决。

## Tracked source/QSF/IP 审核

T017→T027 之间 QSF、Qsys、EMIF IP、平台 top、JTAG-UART wrapper 和 vendor-generated
JTAG-UART Verilog 的 SHA256 均不变；只有 'rtl/lcvex_decode.sv' 发生 decoder repair。
QSF 保留 Qsys EMIF 和 JTAG-UART 两组输入，没有 SLD disable、endpoint removal、
MESSAGE_DISABLE、filter 或 waiver 根因设置。tracked JTAG-UART 文件的
'altera message_off ... 16788' 是禁止采用的 suppression metadata，且没有压掉生成 SLD
hub warning；其中 'SLD_AUTO_INSTANCE_INDEX=YES' 仅在注释块中，也不是 active repair。
因此未发现同时保留 EMIF JTAG 与 JTAG-UART 的合法 tracked-source 根因修复。

## 建议的 source-qualified contract（待集成者决定）

保留 raw '.syn.rpt'/'.syn.smsg'/'.syn.summary'，不做 suppression/filter/waiver。每次
fresh synthesis 必须满足：

1. tracked RTL/IP 的 Warning 16788 去重计数为 0，特别是 'lcvex_decode.sv:1806'
   的 'imm[63]_2' 必须消失；
2. generated SLD allowlist 最多一个且当前 topology 期望恰好一个，必须完整匹配
   '(16788, ir_in_2d[2][4], alt_sld_fab_0_altera_sld_jtag_hub_1920_oerl7dy.vhd:243,
   auto_fab_0|alt_sld_fab_0|alt_sld_fab_0|sldfabric)'；当前 raw 形式只能是一条 detail
   和一条 summary；
3. normalized synthesized sopcinfo SHA 必须为
   'b127700cfe079af2b01bfc5bcfea3926d2d97d7317d79cad943658d117ff532e'，且 module/hpath、
   endpoint hpath、SETTINGS/type-code/IR-width、COUNT/N_SEL_BITS/N_NODE_IR_BITS、
   NODE_INFO 和 node_0/node_1 宽度 1/3 全部匹配。任一 count/signature/topology drift
   fail closed；
4. 任意 tracked RTL/QSF/IP/topology/Quartus version 变化都必须开新任务并 fresh physical；
   本交接不修改 T027，也不宣称 T027 已通过。

## 验证与限制

'git diff --check'、'jq empty docs/tasks/evidence/T-20260920-028.json' 已通过。未运行
Quartus、synthesis/fitter/STA/assembler、SOF、JTAG、板卡、Flash、reset 或 power。
精确命令、artifact SHA、source commit/path、历史 evidence hash 和 residual risks 见
[证据 JSON](../tasks/evidence/T-20260920-028.json)。
