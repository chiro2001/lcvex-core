# T-20260905-018：R18 FP accumulator kill cut 交接

```text
task=T-20260905-018
state=review
base=738cc142c0dae5269dffe9b8020094cb77ec8094
implementation_head=b212520cff8ecf896023a525047d088c189c015b
branch=timing/T-20260905-018-r18-fp-acc-kill-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-018
files=rtl/lcvex_neon_fp.sv; tb/sv/lcvex_fp_exec_tb.sv
next=integrator 在 R18 batch candidate 上串行运行受影响 L0-L2，并以合并 SHA 运行 physical flow
```

## 结论

本 lane 针对 T-014 residual `core-control -> fp_exec.acc/acc_flags` 方向性路径，完成
一个局部且语义受限的 kill-enable cut：`lcvex_fp_exec` 的 kill 分支仍清除
transaction ownership、held response 和 slot capture，但不再把非架构的
`acc/acc_flags` 写零。reset 分支仍确定性清零；`TX_IDLE` 的下一次 accepted request
仍在任何 slot 运行前清零二者。没有修改 core、scalar datapath、接口、response 构造、
架构提交或真实 kill 优先级。

## T-014 residual 输入

来自全新 R17 physical probe 的方向性报告（T-014 evidence `head_sha=65843ee`）：

| 方向 | WNS | 逻辑级数 | 解释 |
| --- | ---: | ---: | --- |
| `exmem_valid -> acc` | −0.410 ns | 26 | kill/core 控制残余 endpoint |
| `exmem_valid -> acc_flags` | −0.259 ns | 26 | kill/core 控制残余 endpoint |
| `exmem_wb_rd -> acc` | −0.054 ns | 26 | kill/core 控制残余 endpoint |
| `exmem_wb_rd -> acc_flags` | +0.097 ns | 26 | 同一控制族，非最差路径 |
| `memwb_wb_rd -> acc` | +0.093 ns | 24 | 同一控制族，非最差路径 |
| `memwb_wb_rd -> acc_flags` | +0.244 ns | 24 | 同一控制族，非最差路径 |
| `slot_result_r -> acc` | +12.571 ns | 3 | 真实 slot 累加写入，必须保留 |

报告中的共同控制链最终落到 `fp_exec.acc[*].ena`；因此本修改只移除 kill 分支的
死 payload 清零写点，保留 `TX_SLOT` 的真实 `slot_result_r/flags` 写入。

## RTL 语义与结构变化

- `!rst_n` 分支保持 `state=TX_IDLE`、`rsp_r=0`、`acc=0`、`acc_flags=0` 及全部
  slot capture 清零。
- `kill` 分支保持 `state=TX_IDLE`、`req_r/rsp_r/slot_idx/slot_result_valid` 和
  slot capture 清零；`acc/acc_flags` 保持原值，仅作为失去 ownership 后的死 payload。
- `TX_DONE && rsp_ready` 仍释放 response ownership；R17 已确认 response 和
  accumulator payload 的保留语义。
- `TX_IDLE` 的 `req_valid && req_ready` 仍先写 `acc=0`、`acc_flags=0`，再进入
  `TX_RUN`，所以被 kill 的 partial slot 不会进入新 transaction。
- 新增 wrapper SVA：在 `TX_RUN/TX_SLOT/TX_DONE` kill 后要求下一采样点回到
  `TX_IDLE`、无 response/slot capture，并以 `$stable(acc/acc_flags)` 表达死 payload
  保留；accepted request 的下一采样点要求 `TX_RUN` 且 accumulator/flags 为零。

## 定向测试

`tb/sv/lcvex_fp_exec_tb.sv` 新增 `kill_reissue_acc_state_probe`，使用四槽
`FADD.4S`（`1.0 + 2^-24`、round-to-+Inf，结果各 lane `0x3f800001`、FPSR
`0x10`）先形成非零 partial `acc/acc_flags`，再分别在以下实际 wrapper 边界拉高
kill：

- `TX_RUN`、`slot_idx=1`；
- `TX_SLOT`、`slot_idx=1`、`slot_result_valid=1`；
- `TX_DONE`、held response 有效。

每个场景都检查 kill 后没有 ghost response、wrapper 回到 idle、dead accumulator
保持原值；随后用新 tag reissue，检查 accepted request 后、首个 slot 完成前
`acc/acc_flags==0`，并校验完整四槽 response 和单次消费。

## 本 lane 静态证据与限制

- `git diff --check 586e8e9..b212520c`：PASS。
- 相对任务登记提交 `586e8e9` 的实现/测试写集恰为上述两个文件；未触碰
  `rtl/lcvex_core.sv`、`rtl/lcvex_fp_scalar.sv`、QEMU、QSF/SDC 或板级区域。
- 未运行 Verilator、Cocotb、SystemVerilog binary、QEMU、锁步、Quartus 或
  physical flow；本 handoff 不宣称功能绿、L0-L2 绿或 timing improvement。
- 下一步由 integrator 在独立 batch candidate 合并 SHA 上运行完整受影响 L0-L2，
  再由 physical lane 以 fresh post-fit/STA 确认旧方向性路径是否归零及新热点。

所有 assembler、bitstream、JTAG、烧写、上电和板级测试继续禁止，除非获得用户明确许可。
