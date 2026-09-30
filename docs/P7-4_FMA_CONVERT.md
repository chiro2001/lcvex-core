# P7-4 FMA 与 FP/整数转换垂直切片

状态：**本任务实施中（T-20260828-066），实现与 owner L0–L2 验证完成后由
集成者在合并 SHA 复跑并归档。**

本切片在 P7-0（V/FPCR/FPSR/FPEN）、P7-1（标量 FP 算术）、P7-3（NEON
2S/4S/2D FP 算术）冻结边界上，补齐选定 FMA 与转换族。它不代表完整
ARMv8.2-A FP/Advanced SIMD 合规；不修改 QEMU fork，不支持编码保持 UDEF。

## 支持矩阵

### 标量 FMA（FP32/FP64）

| 指令 | 语义（A76/QEMU 参考） | 编码要点 |
| --- | --- | --- |
| `FMADD S/D` | `a*b + c` | `00011111 esz 0 rm 0 ra rn rd` |
| `FMSUB S/D` | `c - a*b` | 同上，bit15=1 |
| `FNMADD S/D` | `-(a*b + c)` | 同上，bit21=1 |
| `FNMSUB S/D` | `a*b - c` | bit21=1 且 bit15=1 |

三个源均为 V 寄存器（Rn、Rm、Ra），一个 V 目的 Rd；esz=00（S）/01（D），
esz=10/11（保留/FP16）不接入。四族共用同一 fused multiply-add 整数数据路径：
不产生中间舍入，NaN 传播按 QEMU `float_3nan_prop_s_cab` 顺序（先 SNaN，再
C、A、B；DN=1 时 default NaN），`0*Inf`/`Inf-Inf` 产生 default NaN 与 IOC。
FMADD/FMSUB/FNMADD/FNMSUB 的负号按 QEMU translate 的 `neg_a/neg_n` 方式在
输入上翻转（NaN 符号随之翻转）。

### 标量转换

| 指令 | 形式 | 目的 | 说明 |
| --- | --- | --- | --- |
| `SCVTF/UCVTF` | W/X 整数 → S/D | V | 整数形式 scale=0 |
| `SCVTF/UCVTF` | W/X 定点 → S/D | V | 可选 scale=1..32（W）、1..64（X），按 `value = int * 2^-scale` 用当前 RMode 舍入；IXC/UFC 语义同算术 |
| `FCVTZS/FCVTZU` | S/D → W/X 整数 | GPR | scale=0；NaN→0+IOC，饱和→IOC，截断不精确→IXC |
| `FCVTZS/FCVTZU` | S/D → W/X 定点 | GPR | scale=1..32/1..64，同上 |
| `FCVT` | S↔D | V | S→D 精确；D→S 按 RMode 舍入并报告 OFC/UFC/IXC |

整数→FP 只可能产生 IXC/UFC（int64 小于 FLT_MAX，不产生 OFC）；FP→整数不
产生 UFC/OFC，溢出饱和时置 IOC，不精确截断置 IXC；NaN 输入置 IOC 并返回 0。
FPCR.FZ 对转换输入 subnormal 置 IDC，对定点/FCVT 的 tiny 输出置 UFC，与
P7-1 共用规则。所有 scalar 转换在 ID 标记 `fp_valid`（受 FPEN）；FP→整数
目的写 GPR，V 不写；整数→FP 目的写 V，GPR 不写。

### NEON 向量（selected subset）

| 指令 | 形式 | 说明 |
| --- | --- | --- |
| `FMLA` | `2S/4S/2D` | `Vd = Vd + Vn*Vm`，three-same，含 addend 读 Vd |
| `FMLS` | `2S/4S/2D` | `Vd = Vd - Vn*Vm` |
| `SCVTF/UCVTF` | `2S/4S/2D` | 向量整数→FP（整数形式，scale=0） |
| `FCVTZS/FCVTZU` | `2S/4S/2D` | 向量 FP→整数（scale=0） |

向量转换只接入 two-register miscellaneous 整数形式（Q=0 仅 2S，Q=1 接受
4S/2D；Q=0 的 D 形式与 FP16 保持 UDEF）。向量 FMLA/FMLS 与 P7-3 共用
three-same 形状矩阵和 V 前递/hazard 边界；每个 lane 的 FPSR 标志按 OR
合并。向量定点转换、FMLAL/FMLAL2、向量 by-element FMA、FP16、结构化访存、
sqrt/estimate/min/max/round 和 SVE 均不实现。

## 编码子集（A64 掩码）

```text
scalar FMA      insn[31:24]==0x1f && esz=00/01 && bit23=0
                bit21=neg_a, bit15=neg_n；rm=20:16, ra=14:10, rn=9:5, rd=4:0
int→fp 整数     insn[31:24]==0x1e && esz=00/01
                op6∈{100010(SCVTF),100011(UCVTF)} && insn[15:10]==0
int→fp 定点     同上但 op6∈{000010,000011}；W:scale=32-insn[14:10]
                （bit15=1 固定），X:scale=64-insn[15:10]
fp→int 整数     op6∈{111000(FCVTZS),111001(FCVTZU)} && insn[15:10]==0
fp→int 定点     op6∈{011000,011001}；scale 同上
FCVT S↔D       insn[31:24]==0x1e && bit23=0 && bit21=1
                bits20:15∈{000101(S→D),000100(D→S)} && insn[14:10]==10000
vector FMLA/FMLS 掩码 0xbfa0fc00：0x0e20cc00 / 0x0ea0cc00
vector 转换     掩码 0xbfbffc00：SCVTF 0x0e21d800 / UCVTF 0x2e21d800 /
                FCVTZS 0x0ea1b800 / FCVTZU 0x2ea1b800（esz=insn[22]）
```

## 状态、权限与提交

- V/FPCR/FPSR/CPACR reset、写掩码和权限沿用 P7-0：`FPCR_P7_WRMASK`、
  `FPSR_P7_WRMASK`、FPEN 四态、EC=0x07/ESR=0x1fe00000 trap 均不变。
- FP 指令在 ID 标记 `fp_valid`/`neon_fp_valid`；trap 不进入 EX、不写
  V/FPCR/FPSR/GPR。转换/向量 FMA 的 V/FPSR effect 由 `commit_fire` 驱动，
  `commit_ready=0` 时 WB 条目与架构状态均不变；FPSR sticky 在 COMMIT OR。
- 每条指令最多一个 V 写（`vec_write_count<=1`），无新的 memory 副作用；
  QEMU wire 仍只比较 raw `FP_INIT`/`FP_COMMIT` delta，RTL effect 仅供
  L1 检查。
- 不支持编码（FP16、esz=10/11、定点向量、by-element、FN* 之外的四 FMA
  变体、FCVTN、FJCVTZS 等）落入 UDEF，不做宽松掩码。

## 验证入口

```text
make compile
make sim-sv-p7-4-fma-convert
make sim-cocotb-p7-4-fma-convert
bash sim/difftest/run_p7_4.sh              # 94/54/27/142 条 A76 required
make p7-4-fma-convert p7-4-fma-convert-edge
make p7-4-fma-convert-rounding p7-4-fma-convert-sequence
# P7 required 差分 checkpoint（LCVXFP01 13 列，每 16 条一个检查点）
FP_NEON=required IMAGE=$PWD/build/difftest/hard_p7_4_fma_convert.bin \
  MAX_INSNS=94 DIFF_CKPT=1 CKPT_EVERY=16 CKPT_DIR=$PWD/build/tmp/ckpt-p7-4 \
  COORD=$PWD/build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh
```

SV raw unit 覆盖四 FMA 族、转换、FCVT、NaN/Inf/zero/subnormal、DN/FZ、
四种 RMode、FPSR 与 UDEF 边界；Cocotb 覆盖真实 pipeline、V/GPR 写回、
FPEN trap、backpressure、sticky 与不支持编码；A76 required lockstep 覆盖
每个编码成功/NaN/FPSR/trap 与 FZ/DN/四种 RMode raw 对照。
