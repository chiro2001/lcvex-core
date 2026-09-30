# P7-1 FP32/FP64 标量垂直切片

状态：**实现与 owner L0–L2 验证完成，等待集成者在合并 SHA 复跑并归档。**

本切片严格建立在 P7-0 的 V/FPCR/FPSR/FPEN 和 `FP_INIT`/`FP_COMMIT` 契约上，
目标是单发射、顺序、单核核心中的有限 FP32/FP64 标量路径。它不代表完整
ARMv8.2-A FP/Advanced SIMD 合规，也不接 Cache、AXI4、EMIF 或 FPGA。

## 支持矩阵

| 类别 | 当前支持 | 编码/边界 |
| --- | --- | --- |
| move | `FMOV S/D, S/D`、`FMOV S/D, #imm` | scalar raw write；Vd[127:64] 清零 |
| arithmetic | `FADD`、`FSUB`、`FMUL`、`FDIV`，S/D | 两个 V 源、一个 V 目的；结果在 COMMIT 更新 |
| compare | quiet `FCMP S/D, S/D`、`FCMP S/D, #0` | 只更新 NZCV；FCMPE 未选 |
| memory | unsigned-offset `LDR/STR S/D` | 单寄存器、自然宽度 byte-enable（S=`0x0f`，D=`0xff`） |

未实现并明确保持 UDEF：FMA/FN*、sqrt/estimate、min/max、转换、整数/定点
转换、FP16、NEON 向量、结构化/lane/replicate/pair 访存、SVE，以及 FP exception
enable 触发的异步/同步 trap。

## raw IEEE 语义

`rtl/lcvex_fp_scalar.sv` 只使用固定宽度无符号整数、指数和 GRS 位进行解包、
对齐、规格化、舍入和打包；没有 `real`、`shortreal`、host floating point、
epsilon 或宽松 NaN 比较。加法保留 128 个额外低位用于抵抗 cancellation，除法
保留 128 位商并把余数压入 sticky 位。FP32/FP64 均支持四种 `FPCR.RMode`：

| `FPCR[23:22]` | 语义 |
| --- | --- |
| `00` | nearest-even |
| `01` | toward +Inf |
| `10` | toward -Inf |
| `11` | toward zero |

P7-1 消费现有 P7 mask 中的 `DN[25]`、`FZ[24]` 和 `RMode[23:22]`；`FZ16` 对
S/D 不起作用，`AHP`、exception-enable 和其它保留位不改变本切片行为。

- DN=1 产生 `0x7fc00000`（S）或 `0x7ff8000000000000`（D）default NaN；
- DN=0 时 signaling NaN 优先于 quiet NaN，随后优先 operand A；signaling NaN
  quiet 化并置 `FPSR.IOC`，quiet NaN payload 按 raw bits 保留；
- `0 * Inf`、`Inf - Inf`、`Inf / Inf`、`0 / 0` 产生 default NaN 和 IOC；非零
  除零产生 signed Inf 和 `FPSR.DZC`；
- signed zero、Inf、正常数和 subnormal 按 sign/exponent/fraction 位比较；
  FPCR.FZ 对算术输入产生 `FPSR.IDC`，tiny 输出按 QEMU A64 的
  tininess-before-rounding 规则置 UFC/IXC，FZ 输出 denormal 置 UFC；
- `FCMP` 的结果为 greater=`0010`、equal=`0110`、less=`1000`、unordered=`0011`；
  quiet NaN 的 FCMP 不置 IOC，signaling NaN 置 IOC；
- 标量 FP 写回按当前 `FPCR.NEP=0` 行为生成零扩展 V 值，完整 V raw state 仍由
  P7-0 模块统一保存。

## 提交、权限和故障边界

FP 指令在 ID 标记 `fp_valid` 并检查 CPACR.FPEN；被拒绝时提交
`EXC_FP_ACCESS=0x07`、`ESR=0x1fe00000`，不进入 EX/MEM，不写 V/FPCR/FPSR。
算术/比较的 V/FPSR effect 从当前 MEM/WB 条目进入既有 `lcvex_fp_state`，由
`commit_fire`（而非仅 `commit_valid`）驱动，因此 `commit_ready=0` 时状态不变。
每条 FP 算术/比较的 FPSR exception bits 在真正 COMMIT 时与当前 FPSR OR，
避免背靠背指令丢失 sticky flag。FP load fault 同样屏蔽 V effect；store 的
副作用只由已有 dmem request/response 和提交包确认。

V effect 仅作为 RTL L1 边界，P7 coordinator 仍按协议只消费 QEMU 的 raw
`FP_COMMIT` state delta，并在每个 required commit 后比较完整 FPCR/FPSR/V state。

## 验证入口

以下入口均在本任务 worktree 运行，精确命令和结果冻结在
[`docs/tasks/evidence/T-20260827-058.json`](tasks/evidence/T-20260827-058.json)：

```text
make compile
make sim-sv-fp-scalar
make sim-cocotb-fp-scalar
make p7-1-fp-scalar
make p7-1-fp-scalar-edge
make p7-1-fp-scalar-rounding
```

SV 覆盖 raw S/D arithmetic、NaN、Inf/zero、FCMP、FZ；Cocotb 覆盖真实
scalar pipeline、V 前递、FP scalar load/store、FPEN trap、load fault 无副作用
和 commit backpressure。A76 required lockstep 还覆盖标准 28 条、边界 38 条、
四种 RMode 18 条，以及 388 条背靠背 S/D raw 算术序列。

QEMU 仍只读使用既有 11.1.0/0012 required wire；本任务没有修改 QEMU fork。
