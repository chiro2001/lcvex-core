# T-20260830-036 RTL-COMPAT-AUDIT：未提交 Quartus 21.4 兼容 RTL 改动审计与处理

状态：**done（审计通过，已整理到分支；未合入 main，未启动 Quartus full flow，未修改 QSF/SDC）**

```text
task=T-20260830-036
state=done
base_sha=f7d30027e016ffa9482079df2657003882ec7c37
branch=feature/T-20260830-036-rtl-compat-audit
head_sha=65ce6f6355c92cde99369445760f5cf8d04893d1
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260830-036
merge_sha=待集成者填写
```

## 审计结论

对 `feature/p7-final` 与 WIP 分支的完整 diff，以及主工作区随后补入的其余 Quartus
兼容性未提交改动，逐项结论如下。所有改写均以原始表达式为基准，重点核对宽度、
零扩展、位索引和函数返回宽度。

### 1. `rtl/lcvex_decode.sv`

- 新增 `rdg_low`：返回低 `width` 位（`width<=32`）的 **32 位零扩展**结果。
  这修复了初版 WIP 中“返回 64 位零扩展值”导致 STP/STXP W 对拼接被 64 位目标
  截断、丢失 rt2 高半的语义错误。
- 新增 `rdg_low6`：变量移位量直接返回 `[5:0]`，避免在调用点做 32→6 位截断，
  并保持 `d.shift_amt = Rm[5:0]` 原语义。
- 新增 `rdg_bit`：TBZ/TBNZ 从 64 位寄存器中动态取 1 位，语义与 `rdg(rt)[bit_idx]`
  严格等价。
- CBZ/CBNZ：
  - 原：`(rdg(rt)[31:0] == 32'd0)`。
  - 改：`(rdg_low(rt,32) == 32'd0)`。
  - 等价：函数返回 32 位低 32 位零扩展，比较结果只由低 32 位决定。
- STP/STXP W 对：
  - 原：`{rdg(rt2)[31:0], rdg(rt)[31:0]}`。
  - 改：`{rdg_low(rt2,32), rdg_low(rt,32)}`（两个 32 位）。
  - 等价：拼接仍为 64 位 `{Rt2[31:0], Rt[31:0]}`；`mem_wdata2` 仍为
    `{32'd0, Rt2[31:0]}`。
- 普通 STR 宽度：
  - 原 `{56'd0, [7:0]}` / `{48'd0, [15:0]}` / `{32'd0, [31:0]}`；
  - 改 `{32'd0, rdg_low(...,8/16/32)}`。
  - 等价：`rdg_low` 已经零扩展到 32 位，外层再补 32 个零得到原 64 位提交数据。
- 变量移位：`rdg_low6(rm)` 与 `rdg(rm)[5:0]` 严格等价。
- `logic_imm_valid`：将 Quartus 不接受的变步长循环 `for (i=0;i<64;i+=e)` 按
  `len` 展开（len=1..6 六种情况）。每种展开复现 `rot << (e*i)` 的重复拼接；
  功能等价。
- NEON immh 位选择：把 `insn[22:19][3]` 这类 part-select 再位选改为
  `immh_hi = insn[22:20]` 后索引；只取实际用于选择元素宽度的三个高位，
  `immh_ok` 仍检查完整 4 位，因此等价。

### 2. `rtl/lcvex_alu.sv`

- SBFM/UBFM 与 BFM 的 W 形式：
  - 原：`bitfield_op(...)[31:0]` / `bfm_deposit(...)[31:0]` 直接部分选择函数结果。
  - 改：先把 64 位返回值存入 `bf32_full`，再 `bf32 = bf32_full[31:0]`。
  - 等价：取低 32 位；W 形式最终仍由 `result = {32'd0, r32}` 零扩展。
- CLZ/CLS：
  - 原：`{57'd0, clz64(a)[6:0]}`，其中函数返回本身就是 `[6:0]`；
  - 改：`{57'd0, clz64(a)}`。
  - 等价：`[6:0]` 是全宽选择，直接拼接 7 位结果得到相同 64 位值。

### 3. `rtl/lcvex_fp_scalar.sv` 与 `rtl/lcvex_neon_fp.sv`

- 移除 `clk = 1'b0`、`rst_n = 1'b1` 端口默认值。
- 主核心 `lcvex_core.sv` 已有显式 `.clk(clk)` / `.rst_n(rst_n)`，无需改动。
- `lcvex_neon_fp.sv` 中 4 个向量 lane 原本依赖默认值；去掉默认后必须显式连接。
  由于 NEON FP 当前不发出 FDIV，且原默认值就是 `clk=0/rst_n=1`，本任务在
  `scalar_lane` 实例补 `.clk(1'b0)`、`.rst_n(1'b1)`，保持完全相同的未使用
  多周期 divider 输入行为。

### 4. `rtl/lcvex_pkg.sv`（主工作区附带未提交改动）

- 将 `alu_op_t` 的 `5'd` 字面量改为 `6'd`（类型 `logic [5:0]`）；
- 将 `sys_reg_t` 等 `6'd` 字面量对齐为 `7'd`（类型 `logic [6:0]`）；
- 其余枚举已有匹配宽度，仅去除多余空格。
- 语义：枚举值不变，只是字面量位宽与声明基础宽度一致；用于满足 Quartus 21.4
  enum literal 宽度检查。

### 5. `rtl/lcvex_core.sv`（主工作区附带未提交改动）

- LD1R/NEON 向量加载写回：将原来“16 次动态循环按 lanes 截取”改为按
  `exmem_mem_size` 静态展开（8/16/32/64 位分别固定循环次数；64 位 lane 显式写
  两半）。
- 语义：只消除 Quartus 对非恒定/越界 part-select 的静态检查问题；对合法 lanes
  和 quad 的写回值与原循环一致。

### 6. `rtl/lcvex_l2_wb.sv`（主工作区附带未提交改动）

- `WAYS>1` 时保留原双 way 命中/替换逻辑；
- `WAYS=1` 时关闭对 `valid[..][1]`/`tags[..][1]` 的访问，避免 Quartus 对缩减
  配置的越界静态检查。
- 语义：只在 `L2_WAYS=1` 的隔离/缩减配置下改变综合展开，默认多 way 行为不变。

## 验证结果

以下均在独立 worktree 中串行执行；Verilator 5.050，未运行 Quartus full flow。

| 验证 | 命令/目标 | 结果 |
| --- | --- | --- |
| 默认核心 lint | `make compile` | PASS（无 warning/error） |
| FP scalar 基础 | `make sim-sv-fp-scalar` | PASS |
| P7-4 FMA/convert | `make sim-sv-p7-4-fma-convert` | PASS（scalar + NEON） |
| P7-5 FP16/sqrt/minmax | `make sim-sv-p7-5-fp16-sqrt-minmax-round` | PASS（scalar + NEON） |
| ALU Cocotb | `make sim-cocotb` | PASS（15/15） |
| Decoder B1 | `lcvex_b1_decode_tb` | PASS |
| Decoder maint | `lcvex_b3_maint_decode_tb` | PASS |
| Decoder sys | `lcvex_b3_sys_decode_tb` | PASS |
| Decoder sysreg | `lcvex_b3_sysreg_access_tb` | PASS |
| Decoder atomic/barrier | `lcvex_b3_atomic_barrier_tb` | PASS |
| 定向附加 decode | STP W 对、CBZ/CBNZ、TBZ/TBNZ、LSLV shift | PASS |
| L2 单元 | `make sim-sv-l2` | PASS |
| Core SoC TB | `make sim-sv` | PASS |

## 最终处理

- 主工作区中的 Quartus 兼容未提交改动已全部纳入本分支（decode/alu/fp_scalar 三项
  外加 pkg/core/l2_wb/neon_fp/logic_imm_valid）。
- 分支已整理为最终提交，未合入 main；原始 WIP 两条保留在历史或已由最终提交体现，
  详细记录见 `docs/tasks/evidence/T-20260830-036.json`。
- 不修改 QSF/SDC；不启动 Quartus full flow。

## 建议

**建议合入**。所有本地定向回归通过，语义逐项等价；集成者只需在合并后按项目规范复跑
L0–L2 相关证据即可。已知未覆盖项：未运行完整 Quartus synthesis/fit/STA，也未运行完整
QEMU 长跑/锁步（本任务不要求）。
