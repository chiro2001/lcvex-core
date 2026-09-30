# LCVEX 并行三条线：开源综合评估、全 ARMv8.2-A 指令补完、多核支持

> 状态：初版规划，尚未定稿。
> 目的：供顶级模型额外审核并优化为完整执行方案。
> 日期：2026-08-29（时间线以当前仓库 `feature/p7-final` 为准）

---

## 0. 背景与当前状态

LCVEX 当前目标是实现 ARMv8.2-A AArch64 单核 CPU，并推进 Catapult A10 FPGA 上板。

当前关键事实：

- `feature/p7-final` 已合并 P7 与 FPGA 线，merge SHA `78771bf`。
- 该 SHA 已完成完整 Gate D：M2/R1、Gate C、P5a、P4b、随机 3×100k、覆盖记账、baremetal-C 均全绿。
- P7-0..P7-5 已完成并归档；P7-B B0-B4 已完成，B5-SoC/Boot 本地 L0/L1 已合入 FPGA 线。
- T-067 正在远端重跑 B5 SoC 的 Quartus full flow/STA；远端 `quartus_syn` 高 CPU/高内存，长期占用资源但进展缓慢。
- T-065 因远端 full flow 未完成而保持 blocked。
- 当前 ISA 覆盖是“选定子集”，距完整 ARMv8.2-A 仍有大量缺口；SVE 明确后置，暂不做。

由于 Quartus 线的阻塞和高成本，需要增加并行的、可独立前进的路线。

---

## 1. 三条并行线的总体关系

| 线 | ID（暂定） | 目标 | 与 Quartus 关系 | 最终合拢 |
| --- | --- | --- | --- | --- |
| A. 开源综合/面积/关键路径评估 | T-20260828-071 | 用开源工具链独立评估 LCVEX SoC 的面积和关键路径 | 不替代 Quartus；提供并行参考 | 与 B/C 一起进入最终候选 |
| B. 全 ARMv8.2-A 指令补完（不含 SVE） | T-20260828-072 | 把选定的 FP/NEON/标量子集补成完整非 SVE AArch64 ISA | 不依赖 Quartus | 与 C 完全并行，最后合拢 |
| C. 多核支持：2核 → 4核 → 32核 | T-20260828-073 | 增加可扩展单簇/多核一致性 CPU | 不依赖 Quartus | 与 B 完全并行，最后合拢 |

原则：

1. A、B、C 三条线各自独立推进，可分别跑测试和产出证据。
2. B 和 C 都涉及共享 RTL（尤其 `rtl/lcvex_core.sv`、decode、cache、memory 接口），必须通过独立 worktree/分支并行开发，最后通过冲突消解和集成验证合拢。
3. Quartus/A10 full flow 仍然是 Gate F-BOARD 的正式证据；A 线只是评估代理，不改变 final signoff 依赖。
4. SVE/SME/Crypto/EL2-EL3/完整多核产品化不在本次 B/C 的最终范围内。

---

## 2. 线 A：开源综合/面积/关键路径评估

### 2.1 需求

- 当前 Quartus full flow 受远端主机资源限制，阻塞周期长。
- 需要一条不依赖 Quartus 的独立 RTL 综合/布局布线评估线。
- 目的是回答：
  - LCVEX SoC 在 FPGA 类器件上的面积量级是多少？
  - 逻辑资源主要耗在哪里？
  - 关键路径主要出现在哪些模块？
  - 后续优化应该优先处理哪里？

### 2.2 范围

- 评估对象：
  - `rtl/lcvex_catapult_soc_top.sv`
  - 包含核心、I/D cache、L2、AXI4、Avalon 桥、BRAM boot、JTAG-UART、EPCQ CSR、PLAT_STATUS。
- 不包含：
  - Qsys 生成 IP
  - Altera EMIF / SFL / JTAG-UART IP
  - 远端 Windows 工程、Quartus、Arria 10 专有数据库
- 外部接口在评估时使用 tie-off / stub：
  - EMIF calibration 状态固定
  - Avalon 主/从接口接固定读响应或常数
  - JTAG-UART / EPCQ 接口接简单 stub

### 2.3 推荐工具链

主选：

```text
sv2v        # SystemVerilog -> Verilog
Yosys       # 综合
nextpnr-ecp5 # 布局布线
```

备选：

```text
VTR / VPR   # 更架构中立的 FPGA 综合/布线评估
```

- ECP5 仅作为“逻辑面积/时序代理器件”，不代表 Arria 10。
- 如果工具链无法消费全部 SystemVerilog 特性，可先做 RTL 子集或 wrapper。

### 2.4 阶段

| 阶段 | 内容 | 输出 |
| --- | --- | --- |
| A0 | 工具链安装/验证，`sv2v` 转换，`yosys read` 与 `verilator --lint` | 工具链可用性结论 |
| A1 | `Yosys synth_ecp5` | 网表、LUT/FF/BRAM/DSP 统计 |
| A2 | `nextpnr-ecp5` place & route | 资源占用、最差 setup、Fmax、关键路径 |
| A3 | 生成报告并与 T-064 A10 fit 数据对比 | JSON + Markdown 报告 |

### 2.5 验证与验收

- 从当前 SHA 可复现。
- Yosys 0 error。
- nextpnr 布线完成。
- 报告至少包含：
  - LUT / FF / BRAM / DSP
  - 模块级资源占比
  - 关键路径起点/终点/模块
  - 预估 Fmax
- 明确声明：
  - 不是 Arria 10 signoff。
  - 不替代 Gate F-BOARD。
  - ECP5/VTR 结果与 A10 不能直接换算。

### 2.6 交付物

```text
fpga/opensynth/Makefile
fpga/opensynth/run.sh
fpga/opensynth/convert.sh
fpga/opensynth/*.lpf / *.pcf / tie-off
build/opensynth/synth_stats.json
build/opensynth/timing.rpt
docs/handoffs/T-20260828-071-open-synth-proxy.md
docs/tasks/evidence/T-20260828-071.json
```

### 2.7 风险

- SystemVerilog 特性（package、struct、interface）可能导致开源工具链无法直接综合。
- ECP5 与 A10 架构差异大，面积/时序只能作相对参考。
- 长流程可能仍需要数小时，但可以自动化和并行。

---

## 3. 线 B：全 ARMv8.2-A 指令补完（不含 SVE）

### 3.1 需求

- 当前 P7 只实现 ARMv8.2-A FP/NEON 的选定子集。
- 项目目标是完整 ARMv8.2-A AArch64 指令支持（本线明确排除 SVE/SME/Crypto 等，见非目标）。
- 需要一个系统化、可度量、可并行拆分的指令补完线。

### 3.2 目标范围

包含：

- AArch64 必选标量指令族补完
- 完整 FP/Advanced SIMD：
  - FP16/FP32/FP64 标量与向量
  - FMA、FCVT、FSQRT、FMIN/FMAX/FMINNM/FMAXNM、FRINT*
  - FCMP/FCMPE
  - by-element
  - lane / replicate
  - 结构化访存、多寄存器 load/store
  - 完整 FPSR/FPCR 语义与 exception-enable
- 系统指令/系统寄存器完整访问矩阵
- 异常路径、维护指令、TLBI/DC 等补齐
- LSE/LSE128、CRC、RCpc、PAuth 等基础扩展（按实现优先级排列）

明确排除（本次后置）：

- SVE
- SME
- Crypto 扩展
- EL2/EL3 虚拟化
- 多核一致性（归线 C）
- 完整 PMU/JTAG/GDB（归未来 P9）

### 3.3 与现网的关系

- 以 `feature/p7-final` 为基线，分出新分支：
  ```text
  feature/T-20260828-072-armv82-full-isa
  ```
- 不能直接破坏 P7 已通过的 Gate D / FP/NEON 证据。
- 每个子切片都必须保留现有 P6/P7 回归。

### 3.4 建议子切片

| 切片 | 内容 | 说明 |
| --- | --- | --- |
| B0 | 指令差距审计与覆盖矩阵 | 扩展 `ISA_SCOPE.md`，生成可机器校验的期望指令集 |
| B1 | 标量/整数/访存/分支缺口补完 | 补 ROR、LDAPR、MOPS、剩余 LSE128 等 |
| B2 | FP/Advanced SIMD 全矩阵补完 | 完成线 B 最大工作量；按数据路径/编码族拆分 |
| B3 | 系统寄存器、异常、维护指令补完 | 完善访问矩阵与 QEMU 对齐 |
| B4 | 最终覆盖闭合与 Gate D 全量回归 | 覆盖期望集 100%，完整回归 |

每个切片可继续拆成可派发的子任务。

### 3.5 验证方法

- `make compile`
- SV raw-bit 定向测试
- Cocotb 流水线测试
- QEMU `cortex-a76` / 必要时 `-cpu max` strict lockstep
- 随机程序 + `scripts/insn_coverage.py` 扩展
- 每个切片完成后运行完整 Gate D 回归
- 最终目标：在所选非 SVE ARMv8.2-A 范围内，期望覆盖集 100% 命中

### 3.6 验收

- 明确的 ISA 范围文档更新。
- 所有支持矩阵中的指令族都有 SV/Cocotb/difftest 证据。
- 非支持/后置范围有明确 UDEF 及记录。
- 最终候选通过完整 Gate D。
- 与线 C 合拢后，在同一 SHA 上再跑全量回归。

### 3.7 风险

- ARMv8.2-A 范围极大，需要控制“完整”的边界。
- QEMU 参考模型可能在部分可选扩展上与 ARM 架构手册有差异。
- 实现和验证工作量可能远超单次派单，需要分解。
- 与线 C 共用 RTL，需要接口稳定/冲突管理。

---

## 4. 线 C：多核支持（2核 → 4核 → 32核）

### 4.1 需求

- 当前 LCVEX 是单核顺序 CPU。
- 需要新增一条完全并行的多核线，目标按 2 核、4 核、……、32 核扩展。
- 该线与全指令补完线完全并行，最终再合拢到统一候选。

### 4.2 目标范围

- 多核启动与复位
- 多核缓存一致性：
  - D-L1 一致性和维护
  - I-L1 维护
  - L2 统一/共享模型
  - 探针/写回/失效
- 核心间互连：
  - AXI4 或自定义一致性接口
  - 内存/MMIO 路由
  - 中断路由（GIC 多核）
- 系统范围：
  - PSCI 多核 CPU_ON/OFF
  - 多核 Timer/GIC
  - 地址空间、DDR、BRAM 启动
- 验证：
  - QEMU 多核 lockstep/差分
  - 多核裸机程序
  - Linux SMP 启动（若可行，后置验证）

明确排除（本次后置）：

- SVE
- 完整 ARMv8.2-A 指令补完（线 B 负责，合拢时统一）
- 完整 FPGA 产品化/物理板级多核

### 4.3 阶段

| 阶段 | 内容 | 验证 |
| --- | --- | --- |
| C0 | 多核架构设计：核 wrapper、互连协议、一致性模型、中断/启动 | 设计文档 + L0 检查 |
| C1 | 2 核原型 | 2 核裸机/定向/差分通过 |
| C2 | 4 核扩展 | 4 核一致性/互连/中断通过 |
| C3 | 8 / 16 / 32 核扩展 | 可扩展性、资源/带宽评估 |
| C4 | 与线 B 合拢 | 合拢 SHA 全量 Gate D + 多核回归 |

建议核心步骤：

1. 先把单核核心封装为稳定 wrapper，定义 `core_id`、`snoop/probe`、`irq`、`start/stop` 等接口。
2. 新增多核互连模块，不直接大改单核路径。
3. 在独立 worktree 中并行开发，最后消解与线 B 的共享文件冲突。

### 4.4 验证策略

- 单元/SV：核心间接口、probe、memory ordering。
- Cocotb：多核事务/一致性/中断。
- QEMU 差分：
  - 每核以 A76 参考逐指令锁步；
  - 跨核内存访问以 QEMU 多核行为为参考。
- 定向程序：
  - 多核启动
  - 核间同步
  - 核间 cache coherence
  - 多核 IRQ
- 大规模：
  - 随机多核负载
  - 长跑稳定性

### 4.5 验收

- 2/4/.../32 核可编译、可启动。
- 多核一致性测试通过。
- 多核中断、PSCI 通过。
- 与线 B 合拢后，同一 SHA 通过：
  - 完整 Gate D
  - 单核全量回归
  - 多核专项回归
- 不宣称完整产品级多核/物理板验证，除非后续 Gate 明确。

### 4.6 风险

- 多核一致性是高风险高复杂度线。
- 需要新的验证基础设施（多核 QEMU、跨核 lockstep、共享内存模型）。
- 与线 B 共享核心 RTL，合并冲突可能大。
- 32 核可能受限于仿真性能和资源，需要层次化/参数化设计。

---

## 5. 并行协作与最终合拢策略

### 5.1 分支与 worktree

建议：

```text
feature/T-20260828-071-open-synth-proxy
feature/T-20260828-072-armv82-full-isa
feature/T-20260828-073-multicore
```

三条线都从 `feature/p7-final`（当前 HEAD `0801501`）分出。

### 5.2 共享文件冲突处理

- B 和 C 都涉及 `lcvex_core.sv`、`lcvex_decode.sv`、Cache/MMU 等文件。
- 建议：
  1. 先冻结单核核心接口；
  2. B 线以指令/解码改动为主；
  3. C 线以核 wrapper、互连、一致性改成新增模块为主；
  4. 合拢时按“先 B 后 C 或先 C 后 B”的顺序做集成，避免双方同时重写同一文件；
  5. 合拢后必须跑全量 Gate D + 多核专项回归。

### 5.3 合拢候选

最终合拢到一个统一候选，例如：

```text
feature/p7-final-next 或 feature/armv82-multicore-final
```

合拢 SHA 需要同时满足：

- 完整 Gate D
- 非 SVE ARMv8.2-A 指令覆盖目标
- 多核专项验证
- A10/Quartus 进度允许时，再并入 Gate F-BOARD 正式证据

---

## 6. 开放问题/待顶级模型决策

1. **ARMv8.2-A “完整”边界**：
   - 是否包含 PAuth、RAS、MTE、LSE128 等可选扩展？
   - 是否以 QEMU `cortex-a76` 或 `-cpu max` 作为参考？
2. **多核一致性与内存模型**：
   - 使用自研一致性协议还是基于 AXI4-ACE/Cache Coherent 互连？
   - 是否要求 ARM ARM memory model 完整合规，还是以 QEMU 为参考？
3. **开源综合工具链**：
   - 主选 ECP5 + nextpnr，还是 VTR 更合适？
   - 是否需要以“可综合 RTL 子集”为第一目标，而非完整 SoC top？
4. **任务拆分粒度**：
   - 三条线各自是否应该在系统里登记为一个大任务 + 多个子任务？
   - 是否先只做 B 的审计（B0）再全速推进？
5. **与现有 Gate 的关系**：
   - 多核线是否要进入 Gate F 系列，还是作为未来 P10/P11？
   - 开源综合评估是否作为 Gate 前置参考或只作为内部优化证据？

---

## 7. 建议下一步

1. 顶级模型审核本文档，给出完整方案、里程碑和任务拆分。
2. 按审核结果登记正式任务：
   - `T-20260828-071`：开源综合评估
   - `T-20260828-072`：全 ARMv8.2-A 指令补完（无 SVE）
   - `T-20260828-073`：多核支持 2→4→32
3. 先启动低风险线：
   - A 线工具链验证；
   - B 线 B0 指令差距审计；
   - C 线 C0 多核架构设计。
4. 每条线独立产出证据；最终合拢后统一跑全量回归。
