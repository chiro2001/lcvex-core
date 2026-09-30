# P7-5 FP16 半精度、sqrt、min/max 与 round 垂直切片

状态：**本任务已验证完成（T-20260828-069）**。本切片在 P7-0（V/FPCR/FPSR/FPEN）、
P7-1（标量 FP32/64 算术）、P7-3（NEON 2S/4S/2D FP）、P7-4（FMA/转换）冻结
边界上，补齐 FP16 半精度、FSQRT、FMIN/FMAX/FMINNM/FMAXNM 与 FRINT*
（round-to-integral）族。不代表完整 ARMv8.2-A FP/Advanced SIMD 合规；
不修改 QEMU fork；不支持编码保持 UDEF，不做宽松掩码。

## 支持矩阵

### 标量（A64 `0x1E`/`0x1F` 数据路径）

| 指令 | S | D | H | 说明 |
| --- | --- | --- | --- | --- |
| `FADD` / `FSUB` / `FMUL` / `FDIV` | 是（P7-1 回归） | 是 | 是 | 与 P7-1 共用 raw 整数数据路径 |
| `FCMP` / `FCMP #0.0` | 是 | 是 | 是 | quiet compare；FCMPE 仍 UDEF |
| `FMOV`（寄存器 / 立即数） | 是 | 是 | 是 | H 立即数按 VFPExpandImm(H) |
| `FSQRT` | 新增 | 新增 | 新增 | 负输入/NaN → default NaN + IOC |
| `FMIN` / `FMAX` | 新增 | 新增 | 新增 | NaN 按 QEMU s_ab；`FMIN(+0,-0)=-0` |
| `FMINNM` / `FMAXNM` | 新增 | 新增 | 新增 | 单个 QNaN 返回数值；SNaN 仍 IOC |
| `FRINTN/Z/P/M/A/I/X` | 新增 | 新增 | 新增 | N/P/M/Z/A 固定 RMode；I/X 用 FPCR.RMode；I 不置 IXC |
| `FCVT` | — | — | — | `S↔D`（P7-4）、`H↔S`、`H↔D`（新增） |

标量 H 访存（`LDR/STR H`）本切片不实现（写集外延后项），H 数据经
P7-2 单 Q 访存/FCVT/FMOV immediate 送入 V 寄存器。FP16 标量 FMA
（esz=11 的 `0x1F` 族）保持 UDEF。

### NEON 向量（selected subset）

| 形状 | 支持指令 | 说明 |
| --- | --- | --- |
| `Vd.4H` / `Vd.8H` | `FADD`、`FSUB`、`FMUL`、`FCMEQ` | 每个 32-bit 槽内两个 16-bit lane |
| `Vd.2S` / `Vd.4S` | `FSQRT`、`FMIN`、`FMAX`、`FMINNM`、`FMAXNM`、`FRINT*` | two-register misc / three-same |
| `Vd.2D` | `FSQRT`、`FMIN`、`FMAX`、`FMINNM`、`FMAXNM`、`FRINT*` | 同上 |

协议分批矩阵（docs/P7_FP_NEON_PROTOCOL.md）未包含向量 FP16
FMLA/FMLS/FCVT、向量 H min/max/rint/sqrt 之外的 FP16 族，因此保持 UDEF 并
在本任务记录：**4H/8H 仅接入 FADD/FSUB/FMUL/FCMEQ**；向量 H
`FMLA/FMLS/FCVT/FSQRT/FMIN/FMAX/FMINNM/FMAXNM/FRINT*` 不接入。
向量 S/D 的 `FCVT`（S↔D 重打包）、by-element、lane、结构化访存、FCMGE/FCMGT、
estimate、SVE 均保持 UDEF。

## 编码子集（A64 掩码）

标量 three-same（esz=00/01/11；`insn[31:24]==0x1e`、bit21=1、bits[15:10]）：

```text
FADD   001010   FSUB   001110   FMUL   000010   FDIV   000110
FMAX   010010   FMIN   010110   FMAXNM 011010   FMINNM 011110
FCMP   bits[15:10]==001000（e=0；z 选 #0.0）
FMOV register 为 one-source op=000000（rm 字段必须为 0）
```

标量 one-source（`insn[31:24]==0x1e`、bit21=1、bits[14:10]==10000）：

```text
FSQRT 000011   FRINTN 001000   FRINTP 001001   FRINTM 001010
FRINTZ 001011  FRINTA 001100   FRINTX 001110   FRINTI 001111
```

标量 FCVT（同 one-source 空间）：

```text
esz=00: op=000101 → S→D；op=000111 → S→H
esz=01: op=000100 → D→S；op=000111 → D→H
esz=11: op=000100 → H→S；op=000101 → H→D
```

NEON three-same（掩码 `0xbfa0fc00`）新增：

```text
4H/8H: FADD 0x0E401400  FSUB 0x0EC01400  FMUL 0x2E401C00
       FCMEQ 0x0E402400（Q=bit30；Q=0→4H，Q=1→8H）
2S/4S/2D min/max（Q=0 仅 2S，D 仅 Q=1）：
       FMAX 0x0E20F400/0x0E60F400  FMIN 0x0EA0F400/0x0EE0F400
       FMAXNM 0x0E20C400/0x0E60C400  FMINNM 0x0EA0C400/0x0EE0C400
```

NEON two-register misc（掩码 `0xbfbffc00`）新增：

```text
FSQRT   H 0x0EF9F800   S 0x2EA1F800   D 0x6EE1F800
FRINTN  H 0x0E798800   S 0x0E218800   D 0x0E618800
FRINTP  H 0x0EF98800   S 0x0EA18800   D 0x0EE18800
FRINTM  H 0x0E799800   S 0x0E219800   D 0x0E619800
FRINTZ  H 0x0EF99800   S 0x0EA19800   D 0x0EE19800
FRINTA  H 0x2E798800   S 0x2E218800   D 0x2E618800
FRINTX  H 0x2E799800   S 0x2E219800   D 0x2E619800
FRINTI  H 0x2EF99800   S 0x2EA19800   D 0x2EE19800
```

## 状态、权限与提交

- V/FPCR/FPSR/CPACR reset、写掩码和权限沿用 P7-0：`FPCR_P7_WRMASK`
  （含 AHP bit26、FZ bit24、DN bit25、RMode bits23:22、FZ16 bit19）、
  `FPSR_P7_WRMASK`、FPEN 四态、EC=0x07/ESR=0x1fe00000 trap 均不变。
- FP16 算术使用 **FPCR.FZ16**（bit19）flush 输入/输出 subnormal；
  **不置 FPSR.IDC**（QEMU A64 对 FPST_A64_F16 屏蔽 IDC）。输出 flush 置
  UFC，舍入不精确置 IXC。S/D 仍按 FPCR.FZ（bit24）并置 IDC。
- `FPCR.AHP`（bit26）只影响 `FCVT` 的 H↔S/D（AHP=1 时 H 无 NaN/Inf：
  H→S/D 把 e=11111 当正常指数；S/D→H 的 NaN→±0、Inf→max normal 并置
  IOC）。FP16 算术指令不受 AHP 影响。
- 所有 FP 指令在 ID 标记 `fp_valid`/`neon_fp_valid`；trap 不进入 EX、不写
  V/FPCR/FPSR/GPR。V/FPSR effect 由 `commit_fire` 驱动；每条指令最多一个
  V 写，QEMU wire 仍只比较 raw FP_INIT/FP_COMMIT delta。
- 提交数据（PC/写回/NZCV/next_pc）与 P7-1 一致；FCMP 更新 NZCV，算术
  写 Vd，FPSR sticky 在 COMMIT OR。

## 验证入口

```text
make compile
make sim-sv-p7-5-fp16-sqrt-minmax-round
make sim-cocotb-p7-5-fp16-sqrt-minmax-round
bash sim/difftest/run_p7_5.sh
```

SV raw unit 覆盖 H add/sub/mul/div/cmp/minmax/sqrt/frint/fcvt/fmov、
FZ16/AHP、四种 RMode、NaN/Inf/zero/subnormal 与 FPSR；Cocotb 覆盖真实
pipeline、V 写回、FPEN trap、backpressure、sticky 与 unsupported UDEF；
A76 required lockstep 覆盖每个编码成功/NaN/FPSR/trap 与 FZ16/AHP/四种
RMode raw 对照。回归保持 P7-1/P7-2/P7-3/P7-4 与 P6 标量入口全绿。
