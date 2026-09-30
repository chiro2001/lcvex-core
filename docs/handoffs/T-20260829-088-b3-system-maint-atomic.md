# T-20260829-088 B3 系统/维护/原子 handoff

- 任务 ID：T-20260829-088（B3）
- 状态：review（第一切片已合入；第二、第三切片待集成者复核）
- 分支：`feature/T-20260829-088-b3-system-maint-atomic`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-088`
- base SHA：`7c847561d3de3edeee0f7f8937fd3929fc101ba6`
- 第一切片 merge SHA：`14b93d58384bd619edb4d765809a16b02f679e41`
- sent_at：2026-08-29T08:00:00+0800（约）
- received_at：2026-08-29T08:05:00+0800（约）
- reported_at：2026-08-29T08:36:00+0800

## 第一切片（已合入）：barrier SB 编码严格性

B3 范围内绝大多数已在当前主线/既有 B1/B2 分支中实现。低风险可验收缺口
集中在 **barrier 编码的保留负测**：

- `DSB/DMB`：QEMU a64.decode 使用 `DSB_DMB` 模式，接受任意 domain/types
  选项；RTL 现状正确。
- `ISB`：QEMU a64.decode 接受任意 CRm；RTL 现状正确。
- `SB`：QEMU a64.decode 只接受 `CRm==0000` 的规范编码（`0xD50330FF`）。
  原 RTL 对所有 `op2=111`、`rt=11111` 均当作 barrier，导致 `CRm != 0`
  的未分配编码被误接受，而不是 UDEF。

本切片修复该 barrier 编码缺口并新增解码器级定向测试，已由集成者合并。

## 第二切片：系统寄存器访问矩阵 + OSLAR_EL1 write-only 权限

审计 QEMU 11.1.0 `target/arm/debug_helper.c` 发现：

- `OSLAR_EL1` 定义为 `PL1_W`（write-only），没有 readfn；
  当前 RTL 的 decoder 允许 MRS OSLAR_EL1 并返回 0，和 QEMU 权限不符。
- 该寄存器在项目中作为 debug shim 使用，QEMU 的 Linux 路径只写不读，
  因此关闭 MRS 风险低。

本切片：
1. `rtl/lcvex_decode.sv` 在 MRS 方向拒绝 `OSLAR_EL1`，保留 MSR 写入。
2. 新增 `tb/sv/lcvex_b3_sysreg_access_tb.sv`，覆盖：
   - EL1 常用 MRS/MSR 方向和读值；
   - EL0 访问 EL1-only 寄存器 -> UDEF；
   - Generic Timer EL0 gate 关闭 -> EC=0x18 SYSREG trap；
   - `OSLAR_EL1` MRS 负测、MSR 正测；
   - `OSDLR_EL1` MRS 读零；
   - 未识别 SYS 编码 UDEF。

未实现 `OSLSR_EL1`、`CONTEXTIDR_EL1` 等额外寄存器，避免本切片扩大范围。

## 第三切片：DC ZVA EL0 权限 + TLBI/DC 维护矩阵

审计 QEMU 11.1.0 `target/arm/helper.c` 的 `aa64_zva_access` 与
`v8_cp_reginfo` 发现：

- `DC ZVA` 是 `PL0_W`，在 EL0 由 `SCTLR_EL1.DZE[14]` 门控；
  未开启时 QEMU 走 System Register Trap EC=0x18，而不是 UDEF。
- 原 RTL 的 EL0 cache maintenance 只按 `SCTLR_EL1.UCI[26]` 门控，
  且未把 `DC ZVA` 放入 EL0 可执行类，导致 EL0 DC ZVA 被当作 UDEF。
- 本切片修复：
  - `el0_maint_class` 加入 `MAINT_DC_ZVA`；
  - EL0 DC ZVA 使用 `DZE[14]` 门控，其它 EL0 cache ops 继续使用 `UCI[26]`。
- 新增 `tb/sv/lcvex_b3_maint_decode_tb.sv`：
  - IC/DC/TLBI 已支持 tuple 的 EL1 解码；
  - EL0 DC ZVA DZE=0 -> EC=0x18、DZE=1 -> SYS_MAINT；
  - EL0 DC CVAP UCI=0 -> EC=0x18、UCI=1 -> SYS_MAINT；
  - EL0 PL1-only DC IVAC/TLBI -> UDEF；
  - TLBI EL1 基线 valid、op1=4 EL2 空间 UDEF；
  - `DC CVADP` 维持 UDEF 负测（未批准实现）。

## 改动文件

| 文件 | 说明 |
| --- | --- |
| `rtl/lcvex_decode.sv` | 第一切片 barrier 收紧；第二切片 OSLAR_EL1 MRS 写权限拒绝；第三切片 EL0 DC ZVA DZE 门控。 |
| `tb/sv/lcvex_b3_sys_decode_tb.sv` | 第一切片新增：barrier DSB/DMB/ISB/SB 编码与 SB 非法 CRm 负测。 |
| `tb/sv/lcvex_b3_sysreg_access_tb.sv` | 第二切片新增：系统寄存器 EL1/EL0 访问矩阵与 OSLAR write-only。 |
| `tb/sv/lcvex_b3_maint_decode_tb.sv` | 第三切片新增：TLBI/DC/IC 维护矩阵与 DC ZVA EL0 权限。 |
| `docs/handoffs/T-20260829-088-b3-system-maint-atomic.md` | 本 handoff。 |
| `docs/tasks/evidence/T-20260829-088.json` | 证据 JSON。 |

## 共享热点冲突风险

- 三个切片都只修改 `rtl/lcvex_decode.sv` 的局部区域：
  - 第一切片：barrier 分支约 5 行。
  - 第二切片：MRS/MSR 系统寄存器分支增加 write-only 判断。
  - 第三切片：EL0 cache maintenance 门控分支增加 DC ZVA/DZE 判断。
- 未修改 `rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、`rtl/filelist.f`、
  顶层 Makefile、QEMU fork、checkpoint 协议。
- 与 B2c/C2 若在系统指令解码区域并行，合并时需三路检查该区域。

## 验证

```text
# 第一切片 & 第二切片共用 decoder 模块 lint
timeout 120 conda run --no-capture-output -n lcvex \
  verilator --lint-only --timing -Wall -j 2 --top-module lcvex_decode \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv
# RC=0

# 第一切片 SV TB：barrier 语义
timeout 240 conda run --no-capture-output -n lcvex \
  verilator --binary --timing --assert -Wall -j 2 \
  --top-module lcvex_b3_sys_decode_tb \
  -Mdir build/b3_sys_decode \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv tb/sv/lcvex_b3_sys_decode_tb.sv
timeout 30 conda run --no-capture-output -n lcvex \
  ./build/b3_sys_decode/Vlcvex_b3_sys_decode_tb
# PASS, RC=0

# 第二切片 SV TB：系统寄存器访问矩阵
timeout 240 conda run --no-capture-output -n lcvex \
  verilator --binary --timing --assert -Wall -j 2 \
  --top-module lcvex_b3_sysreg_access_tb \
  -Mdir build/b3_sysreg_access \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv tb/sv/lcvex_b3_sysreg_access_tb.sv
timeout 30 conda run --no-capture-output -n lcvex \
  ./build/b3_sysreg_access/Vlcvex_b3_sysreg_access_tb
# PASS: EL1/EL0 sysreg access matrix, OSLAR write-only, RC=0

# 第三切片 SV TB：TLBI/DC 维护矩阵
timeout 240 conda run --no-capture-output -n lcvex \
  verilator --binary --timing --assert -Wall -j 2 \
  --top-module lcvex_b3_maint_decode_tb \
  -Mdir build/b3_maint_decode \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv tb/sv/lcvex_b3_maint_decode_tb.sv
timeout 30 conda run --no-capture-output -n lcvex \
  ./build/b3_maint_decode/Vlcvex_b3_maint_decode_tb
# PASS: DC ZVA DZE gate, cache/TLBI maintenance matrix, RC=0
```

### 未通过/未执行

- `make compile` 在本 worktree 多次尝试均因并发重型 Verilator 构建
  （C2 双核、B2c SoC 等）超时；本任务**不声称完整顶层 lint 通过**。
  已用 `lcvex_decode` 模块级 lint 覆盖实际改动。
- 未运行 QEMU strict lockstep / Gate D。oracle 依据为仓库内 QEMU 11.1.0
  源码（`a64.decode`、`debug_helper.c`），未伪造 QEMU 运行结果。
- 未运行完整 SoC Cocotb；新增测试均为解码器级，避免与其它重型构建抢资源。

## 剩余 B3 切片（不在本次三个切片内）

| 切片 | 状态/说明 |
| --- | --- |
| 系统寄存器全量 reset/权限矩阵 | 已有常用矩阵与本次定向测试；未跑 `scripts/qemu_sysreg_inventory.py` 全量 probe，剩余未识别 SYS 保持 UDEF。 |
| `DC CVADP` | 后置；未实现。 |
| TLBI OS/RV/range、EL2/EL3 维护 | 后置/未实现。 |
| RCpc `LDAPR/LDAPUR` | manifest 中为 POST-V82-DEFERRED，本任务不实现。 |
| 其它 LSE128 家族/多核一致性 | 后置；由 C 线/后续 profile 处理。 |
| PMU 事件计数 | P9 后置。 |
| barrier 的 `DSB nXS`/更高扩展选项 | 未在 V82 非 SVE 已批准范围，保持 UDEF。 |

## 下一步

1. 集成者复核第二、第三切片，并在资源窗口运行完整 `make compile` 与受影响 L1 回归。
2. 后续可将三个解码器级测试纳入 Makefile/测试注册。
3. 如继续 B3，建议优先做已批准 LSE 单寄存器族的 core/Cocotb 定向，或系统寄存器全量 probe；
   避免再大面积触碰 decode 系统维护分支时与 B2c/C2 冲突。
