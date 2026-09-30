# P7-2 Advanced SIMD/Q 整数垂直切片

状态：**T-20260827-059 owner 实现完成，等待集成者在合并 SHA 复跑并归档。**

本切片在 P7-0 的 `V0..V31` raw 128-bit state、FPEN access trap、
`commit_ready` 和既有 scalar memory 握手上增加受限的 Advanced SIMD 整数路径。
它不是完整 Advanced SIMD/NEON 合规声明，也不接 Cache、AXI4、EMIF、FPGA 或
QEMU fork。

## 支持矩阵

所有 register-form 指令都固定 `Q=1`，lane 0 位于最低有效位；`size=0/1/2/3`
分别表示 `B/H/S/D`（8/16/32/64 bit lane）。加减结果按 lane 宽度 modulo
截断；比较为该 lane 全 1 或全 0。

| 类别 | 支持编码/形式 | 结果 |
| --- | --- | --- |
| move | `MOVI Vd.16B/.8H/.4S,#imm8`；`ORR Vd.16B,Vn.16B,Vm.16B`（含 `MOV` alias） | 一条 V 写回 |
| bitwise | `AND/ORR/EOR/BIC/ORN Vd.16B,Vn.16B,Vm.16B` | 逐 bit raw 运算 |
| add/sub | `ADD/SUB Vd.<T>,Vn.<T>,Vm.<T>`，`T=16B/8H/4S/2D` | 逐 lane modulo |
| compare | `CMEQ/CMGE/CMGT/CMHI/CMHS Vd.<T>,Vn.<T>,Vm.<T>` | signed/unsigned 逐 lane mask |
| shift | `SHL/SSHR/USHR/SSRA/USRA Vd.<T>,Vn.<T>,#imm` | 非饱和；`SSRA/USRA` 使用旧 Vd 累加 |
| memory | unsigned-offset `LDR Qd,[Xn,#imm]`、`STR Qd,[Xn,#imm]` | 单 Q、自然 16B、低/高各一条 8B request |

逻辑指令只接受 Q byte arrangement；算术、比较和立即移位接受四种 lane 宽度。
`MOVI` 只接受 zero-extended byte immediate 的 `.16B/.8H/.4S` 三种 cmode。
立即右移的范围为 `1..lane_bits`，左移为 `0..lane_bits-1`；非法 `immh`/距离
按 UDEF 处理。

## 解码和执行边界

`rtl/lcvex_decode.sv` 使用固定 mask 选择上述 A64 编码族，所有操作在 ID 锁存
V raw operands、lane size 和 shift distance。`rtl/lcvex_neon_int.sv` 只使用
固定宽度无符号/有符号位运算，未使用 host SIMD、`real`、浮点或 epsilon。

V 写回沿用 `lcvex_fp_state` 的单条 commit effect：一次最多一个 `vec_write`
（`vec_write_count=1`），只在 `commit_fire = commit_valid && commit_ready`
时更新。ID/EX、EX/MEM 和 MEM/WB 均有 V forwarding；Q load 在第二个 8B
响应完成前不会前递，并会触发 load-use stall。标量 FP 与 NEON 共用 V hazard
检查，避免跨单元读到旧值。

FPEN 为 `00/10` 时，Advanced SIMD 指令产生 `EXC_FP_ACCESS=0x07` 与
`ESR=0x1fe00000`，不写 V、不发 memory request；EL1 的 `01/11` 权限规则
沿用 P7-0。

## 单 Q 访存 ABI

架构上 `LDR/STR Q` 是一条指令和一条 commit。核心内部将它镜像为：

1. 低 64 位，地址 `PA`，`WSTRB=8'hff`；
2. 高 64 位，地址 `PA2`（通常 `PA+8`），`WSTRB=8'hff`。

只有两段都完成后才生成 WB/commit；load 的 raw 结果为
`{second_rdata, first_rdata}`，其低/高半分别进入 `fp_v_lo/fp_v_hi`。store 的
commit packet 使用既有 `mem/mem2` 两个兼容视图，地址、数据和 strobe 均保留。
请求未接受或响应未返回时流水线保持，`commit_ready=0` 时 V state 和 memory
提交包保持不变。取指 fault merge 仍保留已完整成功的 older `mem/mem2`，而
`memwb_exc` 优先于 fetch merge。

Q 访问必须 16B 自然对齐，且在第一段 request 前通过完整 16B 窗口检查；MMU
开启时跨页 Q 访问分别翻译两半，两个 PA 均通过窗口检查后才发 request。对齐、
范围 fault 在第一段 request 前拒绝，且 `STR Q` 的 ESR WnR=1；这种路径不会
产生 V effect 或半笔 memory commit。

本切片明确采用受限下游契约：对已经通过完整窗口预检的 Q store，底层
`mem_req` slave 必须不再返回 response fault。RTL SVA 检查该契约；专用
`lcvex_neon_fault_bfm_tb` 故意让第二段 fault，探针确认普通 request 在 accept
即产生第一段副作用，且 assertion-enabled 构建按预期失败。因此本切片**不**
声称任意下游 fault 可回滚；若未来 AXI/Cache 允许此类 fault，必须先增加
prepare/commit/abort 事务或等价的可回滚接口，并另开任务验证。

## 明确 UDEF / 后置

本任务不接受并测试为 UDEF：饱和 `SQADD/UQADD/...`、narrow/widen、permute、
table、across-lane、crypto、structured `LD1/ST1`、lane/replicate/pair forms、
变量移位、NEON 浮点、FP16、P7-3 浮点、SVE，以及 Cache/L1/L2/AXI4/EMIF。
单 Q 是一个 V destination 和最多两条连续 8B store；多寄存器 Q 访存不在范围。

## 验证入口

| 层级 | 入口 | 覆盖 |
| --- | --- | --- |
| L0 | `make compile`、Python/shell/diff check | 可综合 elaboration、生成器和边界格式 |
| L1 | `make sim-sv-p7-2-neon` | raw unit 的 move/bitwise/add-sub/compare/shift |
| L1 | `make sim-cocotb-p7-2-neon` | 真实 pipeline、V forwarding、Q 两段 memory、FPEN、fault、UDEF、backpressure |
| L1 | `MEM_DELAY_MODE=2 ... Makefile.p7_2_neon` | 随机下游响应延迟下的 Q memory 握手 |
| L2 | `make p7-2-neon-int` | Cortex-A76 `FP_NEON=required` strict lockstep，31 条定向提交 |

定向程序和 raw encoder 位于 `sim/difftest/test_program.py`；未修改 QEMU fork。
P7-1 和 P6 scalar 回归仍必须在集成者合并 SHA 上复跑，不能以本任务的模块级
结果替代完整 P7/Gate-F 验收。
