# P7-3 受限 NEON 浮点垂直切片

状态：本任务实现并验证协议冻结的 Advanced SIMD `2S/4S/2D` 浮点子集；不代表
完整 ARMv8.2-A FP/Advanced SIMD 合规，也不修改 QEMU fork。

## 支持矩阵

| 形式 | 支持指令 | 结果 |
| --- | --- | --- |
| `Vd.2S` | `FADD`、`FSUB`、`FMUL`、`FCMEQ` | 两个 FP32 lane，写 Vd[63:0]，Vd[127:64] 清零 |
| `Vd.4S` | `FADD`、`FSUB`、`FMUL`、`FCMEQ` | 四个 FP32 lane，完整 128-bit raw 写回 |
| `Vd.2D` | `FADD`、`FSUB`、`FMUL`、`FCMEQ` | 两个 FP64 lane，完整 128-bit raw 写回 |

`FCMEQ` 是 quiet equal compare：相等 lane 产生该 lane 全 1，不相等或 unordered
产生全 0；quiet NaN 不置 IOC，signaling NaN 置 IOC。`FCMGE/FCMGT`、FCMLE/FCMLT
和其它 compare 形式保持 UDEF。

## RTL 数据路径

`rtl/lcvex_neon_fp.sv` 为每个活动 lane 实例化现有
`rtl/lcvex_fp_scalar.sv`，只传递固定宽度 raw bits。四个 lane 的 FPSR flags
按 OR 合并；DN、FZ、RMode、NaN 传播、舍入、Inf/zero/subnormal 边界因此与 P7-1
共用同一整数算法。模块不使用 `real`、`shortreal`、host float、epsilon 或
“任意 NaN”比较。

decoder 只保留四个 opcode family，并单独检查 Q/FP32/FP64 shape：Q=0 只能是
2S，Q=1 可以是 4S 或 2D；D.2、FP16 和 bit pattern 不在矩阵中的 FP 族进入
`EXC_UDEF`。vector FP 复用 NEON 的 V 读端口和 FPEN access namespace，但在 EX
使用独立 raw unit；整数 NEON datapath 不受改变。

## 状态、权限和提交

- `V0..V31`、`FPCR`、`FPSR` reset 均为零；FPEN 由完整 `CPACR_EL1[21:20]`
  保存，CPACR 其它位不受本切片改写。
- EL0 只有 FPEN=`11` 放行；EL1 的 FPEN=`01/11` 放行，`00/10` 产生
  `EXC_FP_ACCESS=0x07`、`ESR=0x1fe00000`，不进入 EX/MEM、不写 V/FPSR。
- FPCR 只消费 P7 mask 中的 DN/FZ/RMode；FPSR exception bits 是 sticky OR。
  `lcvex_fp_state` 在 `commit_fire` 时同时更新 V/FPSR，`commit_ready=0` 时
  WB 条目、V raw state 和 FPSR 均保持不变。
- 每条支持指令最多一个 V destination；提交包使用已有
  `vec_write_count=1/vec_rd0/vec_wdata0` 和 `fpsr_we/fpsr_wdata` effect 槽位。
  QEMU wire 仍只比较协议规定的 raw FP state delta，不把 RTL effect 当作同值
  写 oracle。

## 明确后置范围

本切片不实现 FMA、FP16、vector conversion、sqrt、estimate、min/max、完整
exception-enable、structured/lane/replicate/pair memory、SVE、Cache、AXI、EMIF
或 FPGA 厂商依赖。P7-2 的整数 NEON、单 Q 两段访存契约和 P7-1 的 scalar FP
回归必须继续通过。

## 验证入口

```text
make compile
make sim-sv-p7-3-neon-fp
make sim-cocotb-p7-3-neon-fp
make p7-3-neon-fp
```

SV raw unit 覆盖 2S/4S/2D 运算、FCMEQ、NaN/Inf/signed zero、DN/FZ/RMode 和
FPSR flags；Cocotb 覆盖真实 pipeline、V forwarding、FPEN trap、backpressure、
sticky flag 与 unsupported UDEF。A76 required 程序覆盖完整 12 组合矩阵
（2S/4S/2D × FADD/FSUB/FMUL/FCMEQ），并执行 vector FZ、DN 及 RN/RP/RM/RZ
四种 RMode raw 对照；FCMGE/FCMGT、FP16、FMA、转换仍为 UDEF。
