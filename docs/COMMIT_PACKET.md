# 提交包（Commit Packet）与 Trace 格式

提交包是 RTL、差分测试（Cocotb/QEMU）和调试模块之间的共同边界。任何
新指令、异常或系统状态都通过扩展提交包暴露，不允许绕过提交包直接比较
流水线内部信号。

## 更新时机

- 架构状态只在 COMMIT 阶段、`valid=1` 的时钟沿更新。
- 每周期至多一个提交。
- 异常提交时，比异常指令更年轻的指令全部清空，不得出现在提交包中。
- 提交包各字段语义以本文档为准，RTL 中的 `lcvex_pkg::commit_packet_t`
  必须与本文档保持一致。
- P4b 起：异常指令（UDEF/SVC/IABT/DABT）、`ERET` 与 `MSR`（系统寄存器）
  在 **ID 级提交**（先等更老的指令全部提交），`exc_valid/exc_code` 由此
  产生；异常入口的提交包同时置 `sp_we=1`（SP 切到 `SP_EL1`）与
  `nzcv_we=1`（NZCV=0，QEMU 行为），`next_pc=异常向量`；
  `ERET` 提交置 `sp_we=1`（目标 EL 的 SP bank）与 `nzcv_we=1`
  （从 `SPSR_EL1` 恢复），`next_pc=ELR_EL1`。

## RTL 结构（SystemVerilog）

```systemverilog
typedef struct packed {
  logic              valid;       // 本周期有提交
  logic [63:0]       pc;          // 提交指令 PC
  logic [63:0]       next_pc;     // 下一条 PC
  logic [31:0]       insn;        // 指令编码（失败诊断用）
  logic              gpr_we;      // 通用寄存器写回使能
  logic [4:0]        gpr_rd;      // 写回寄存器编号（Rd=31 视为 XZR）
  logic [63:0]       gpr_wdata;   // 写回数据（W 寄存器写入高 32 位清零）
  logic              gpr2_we;     // 第二写回（LDP rt2）
  logic [4:0]        gpr2_rd;
  logic [63:0]       gpr2_wdata;
  logic              gpr3_we;     // 第三写回（LDP/STP pre/post 基址 rn）
  logic [4:0]        gpr3_rd;
  logic [63:0]       gpr3_wdata;
  logic              sp_we;       // SP 写回使能
  logic [63:0]       sp_wdata;    // SP 写回数据
  logic              nzcv_we;     // NZCV 更新使能
  logic [3:0]        nzcv;        // bit3=N bit2=Z bit1=C bit0=V
  logic              mem_we;      // 内存写使能
  logic [63:0]       mem_addr;    // 内存写地址
  logic [63:0]       mem_wdata;   // 内存写数据
  logic [7:0]        mem_strb;    // 字节写使能，bit[i] 对应 addr+i
  logic              mem2_we;     // 第二存储（STP X 对：mem2=rt2@addr+8）
  logic [63:0]       mem2_addr;
  logic [63:0]       mem2_wdata;
  logic [7:0]        mem2_strb;
  logic              exc_valid;   // 异常提交
  logic [31:0]       exc_code;    // 异常编码（P4 起按 ESR.EC 语义）
  logic              mon_we;      // exclusive 监视器被本提交更新
  logic              mon_valid;   // 更新后有效性（1=LDXR 记录）
  logic [63:0]       mon_addr;    // LDXR 记录地址（clean VA）
  logic [63:0]       mon_data;    // LDXR 记录值（QEMU exclusive_val）
} commit_packet_t;
```

成对指令（LDP/STP，M3）提交语义：

- `LDP`：`gpr=rt`、`gpr2=rt2`；pre/post 寻址时 `gpr3=rn`（基址写回，
  `base+imm`）。
- `STP` W 对（8 字节）：`mem` 单条存储，`mem_wdata={rt2, rt}` 64 位组合。
- `STP` X 对（16 字节）：拆成两条 8 字节存储 `mem=rt@addr`、
  `mem2=rt2@addr+8`（与 QEMU 插件对 16B store 的拆分一一对应，
  保证两个寄存器数据都被差分校验；`mem_strb/mem2_strb=0xFF`）。

exclusive 指令（M3）提交语义：

- `LDXR/LDAXR`：`gpr=rt`（加载值），同时 `mon_we=1, mon_valid=1`，
  `mon_addr=mem_addr`（clean VA）、`mon_data=加载值`（按宽度零扩展，
  与 QEMU `exclusive_val` 一致；rt=31 时仍记录监视器）。
- `STXR/STLXR`：`gpr=状态寄存器 rs`（0=通过 1=失败）；监视器通过且
  内存当前值（按 STXR 宽度截取）与记录值相等才发条件写并
  `mem_we=1`，否则 `mem_we=0`（无内存副作用）；`mon_we=1, mon_valid=0`
  （无论成败都清监视器，QEMU `exclusive_addr=-1`）。
- `CLREX`：`mon_we=1, mon_valid=0`。
- `ERET`：`mon_we=1, mon_valid=0`（QEMU `exception_return` 先清再取指，
  含 ERET 目标越界合并 IABT）。
- A profile 异常入口（SVC/UDEF/IABT/DABT）与 `MSR`：`mon_we=0`
  （异常入口不清监视器，QEMU 实测）；`STXR/LDXR` 自身 DABT 时
  `mon_we=0`（指令未完成，清监视器不执行）。

## Trace 文件格式

每行一条提交记录，固定字段顺序，十六进制值固定宽度、补零，便于
Cocotb/QEMU 双方解析和失败时人工核对。文件以版本头开始：

```text
# lcvex-trace v1
commit insn=0x00000000 pc=0x0000000000000000 next_pc=0x0000000000000004 gpr_we=0 gpr_rd=00 gpr_wdata=0x0000000000000000 sp_we=0 sp_wdata=0x0000000000000000 nzcv_we=0 nzcv=0x0 mem_we=0 mem_addr=0x0000000000000000 mem_wdata=0x0000000000000000 mem_strb=0x00 exc_valid=0 exc_code=0x00000000
```

字段宽度约定：

| 字段 | 格式 | 说明 |
| --- | --- | --- |
| `insn` | `%08x` | 指令编码 |
| `pc` / `next_pc` / `gpr_wdata` / `sp_wdata` / `mem_addr` / `mem_wdata` | `%016x` | 64 位值 |
| `gpr_rd` | `%02x` | 寄存器编号 0~31 |
| `nzcv` | `%01x` | 4 位标志 |
| `mem_strb` | `%02x` | 8 位字节使能 |
| `exc_code` | `%08x` | 异常编码 |
| `*_we` / `*_valid` | `%d` | 布尔值 0/1 |

## 与 QEMU 差分状态的最小映射

对应 `docs/DIFFTEST.md` 的 `arm_difftest_state`：

| 提交包字段 | QEMU 状态字段 |
| --- | --- |
| `pc` | `pc` |
| `gpr_we` / `gpr_rd` / `gpr_wdata` | `gpr_we` / `gpr_rd` / `gpr_wdata` |
| `sp_we` / `sp_wdata` | `sp` |
| `nzcv_we` / `nzcv` | `flags_we` / `nzcv` |
| `mem_we` / `mem_addr` / `mem_wdata` / `mem_strb` | `mem_we` / `mem_addr` / `mem_data` / `mem_strb` |
| `exc_valid` / `exc_code` | `exception` / `exception_code`（ESR.EC） |
| `next_pc` | 差分后一步重取 PC，由测试脚本比较 |

## 失败诊断必存数据

差分测试失败时，至少保存：指令编码与反汇编、执行前架构状态、RTL
提交包（trace 行）、QEMU 状态、最近提交记录和随机种子（如有）。

## P7 FP/NEON 冻结扩展（协议已审核；P7-0 独立边界已实现）

P7 保持现有 scalar 字段/语义及 QEMU `lcvex_commit` wire layout 不变；RTL
`commit_packet_t` 以追加字段扩展 `vec_write_count`（0..4）+四组 `vec_rd/vec_wdata[127:0]`、
`store_count`（0..8）+八组 `store_addr/data/strb`，以及 FPCR/FPSR post/effect；
所有效果仍属于一条 `commit.valid`，不能拆成多个 commit。P7 首批限制一个 V
destination、两个连续 8B store，但不再宣称必须另开多副作用 ABI。

旧 RTL `mem/mem2` 映射为新增 store slot0/1 的兼容视图；未来超过初期上限的
编码使用已预留 slot，不得改变既有 scalar 字段语义。

QEMU 的同 seq FP_INIT/FP_COMMIT 只传可观察 FP state full-init/delta，不传
`vec_we/fpcr_we/fpsr_we`：公开 QEMU API 无法作为同值写的可靠 oracle。RTL effect
只用于 L1 SVA/定向检查；L2 锁步用 raw V/FPCR/FPSR delta。完整 required handshake、
ASYNC、trace 和 checkpoint 契约见主协议。

T-20260827-051 在不改动现有 scalar wire/SoC 顶层的前提下，已将追加的 RTL-only
effect 字段和 `lcvex_fp_state` 的 commit/restore 边界落地并独立验证；现有 core
尚未接入 FP 指令译码或 FP state pipeline，新增 effect 字段固定为零。详见
[P7-0_FP_STATE.md](P7-0_FP_STATE.md)。

raw-bit、NaN/FPSR、PRE/COMMIT frame、trace、失败包和 checkpoint 的权威定义见
[P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md)。

T-051 协议续作已把上述 FP frame 的长度、seq 和提交顺序接入仓库侧
plugin/coordinator/checkpoint/trace 工具；当前 owner worktree 的 SoC 顶层仍未
接入 `difftest_restore_fp_*` 和 FP commit effect 端口，因此非零 FP delta 只能
在该串行接线完成后进入真实 L2 比较。
