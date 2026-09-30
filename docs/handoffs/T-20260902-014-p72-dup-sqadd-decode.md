# Handoff T-20260902-014：P7-2 DUP/SQADD Decode Overlap Fix

```text
task=T-20260902-014
state=review
base=8aa10fe4c5aa37e23b9d75a695e137e018a9d473
head=374eb385b8556ee53fcfaa68a2718edbb09892f2
branch=fix/T-20260902-014-p72-dup-sqadd-decode
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-014
sent_at=2026-09-03T00:53:00+08:00
received_at=2026-09-03T00:54:00+08:00
reported_at=2026-09-03T01:07:30+08:00
files=rtl/lcvex_decode.sv
tests=make compile:pass; make VERILATOR_JOBS=1 sim-sv-p7-2-neon:pass; make VERILATOR_JOBS=1 sim-cocotb-p7-2-neon:10/10 pass; git diff --check:pass
blockers=none
next=integrator merge/review; FP-P0 DUP/SQADD baseline red item now closed
```

## 根因

`rtl/lcvex_decode.sv` 的 B2c DUP 分支使用过宽的匹配掩码：

```systemverilog
(insn & 32'hff00_fc00) == 32'h4e00_0c00  // DUP general
(insn & 32'hff00_fc00) == 32'h4e00_0400  // DUP element
```

该掩码固定了 DUP 的顶层字节（`0x4E`）和 `[15:10]` 字段，但没有固定
`[23:21]`。DUP general/element 的架构编码要求 `[23:21]==000`；而 Advanced
SIMD three-same 的未支持族（如 `SQADD_v`）也落在 `0x4E..0C..` / `0x4E..04..`
的宽匹配范围内，且 `[23:21]` 非零。

具体失败编码 `0x4E220C20`：

- `[31:24] = 0x4E`，`[15:10] = 0x3`，属于 DUP general 的宽匹配；
- 但 `[23:21] = 0b001`，`[20:16] = 0b00010`；
- 因此旧 DUP 分支看到 `imm5=2` 后按 `DUP Vd.8H, Wn` 解码，而不是按
  unsupported/UDEF 路径处理。

QEMU `a64.decode` 中 DUP 的精确形式为：

```
DUP_element_v  0 q:1 00 1110 000 imm:5 0 0000 1 rn:5 rd:5
DUP_general    0 q:1 00 1110 000 imm:5 0 0001 1 rn:5 rd:5
```

即除 Q、imm5、rn、rd 外，`[23:21]` 固定为 `000`。

## 修复

将 DUP 分支的匹配掩码从 `32'hff00_fc00` 收紧为 `32'hffe0_fc00`，使 `[23:21]`
参与匹配并固定在 `000`。分支内部用于区分 general/element 的 `dup_base` 同步
改为同一掩码。

```systemverilog
((insn & 32'hffe0_fc00) == 32'h4e00_0c00) ||
((insn & 32'hffe0_fc00) == 32'h4e00_0400)
```

效果：

- 合法 DUP scalar/element（`[23:21]==000`）仍由原分支解码；
- `0x4E220C20` 等 three-same 未支持族不再被 DUP 捕获，落入默认 UDEF；
- 未新增指令支持，未修改 NEON 整数 datapath、QEMU 或测试期望。

## 验证

| 层级 | 命令 | 结果 |
| --- | --- | --- |
| L0 | `make compile` | PASS，exit 0 |
| L1 | `make VERILATOR_JOBS=1 sim-sv-p7-2-neon` | PASS |
| L1 | `make VERILATOR_JOBS=1 sim-cocotb-p7-2-neon` | **TESTS=10 PASS=10 FAIL=0 SKIP=0** |
| L1 | `git diff --check` | PASS |

Cocotb 中 `test_p7_2_unsupported_udef` 的 SQADD 用例已恢复 UDEF，且 DUP 与
其它 P7-2 用例全部通过。

## 边界

- 只修改 `rtl/lcvex_decode.sv` 的 DUP 掩码。
- 不新增任何 NEON/FP 指令支持。
- 不修改 `sim/cocotb/test_p7_2_neon.py`、QEMU、NEON 整数 datapath。
- 未运行完整 Gate D / 远端 Quartus；本次验证为任务要求的 L0/L1 范围。

## 证据

- `docs/tasks/evidence/T-20260902-014.json`
