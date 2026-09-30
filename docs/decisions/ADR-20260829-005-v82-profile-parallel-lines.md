# ADR-20260829-005：V82 非 SVE profile 与 T-071～T-073 并行路线执行口径

- 状态：accepted
- 日期：2026-08-29
- 关联方案：[`docs/T-20260828-071-073-parallel-lines-plan-v2.md`](../T-20260828-071-073-parallel-lines-plan-v2.md)
- 关联任务：T-20260828-071（开源综合代理）、T-20260828-072（V82 非 SVE profile）、T-20260828-073（多核演进）
- 关联基线：规划快照 `7301268`，功能合并点 `78771bf`
- 关联阻塞：T-20260828-067（Quartus B5 full flow blocked）

## 背景

T-067 的 Quartus 21.4 full flow 三次在 Synthesis 阶段达到约 75GB 私有内存并触发内部 OOM，
远端 A10 综合暂时无法继续。同时项目需要继续推进非 SVE 的 ARMv8.2-A 指令补完、多核演进，
以及一套不依赖 Quartus 的开源综合/PPA 评估。顶级模型已完成审核并产出 v2 执行方案。

## 决定

1. **“完整 ARMv8.2-A”改为可验收的 profile 口径**。
   - `V82-BASE`：项目选定的 AArch64 基础标量、系统、异常、MMU/Cache 语义。
   - `V82-SELECTED-EXT`：明确列出的 FP/Advanced SIMD、FP16、CRC、LSE 等扩展。
   - `V82-SVE-EXCLUDED`：SVE/SVE2/SME 明确排除，不把 ZCR/RDVL shim 当 SVE 实现。
   - `POST-V82-DEFERRED`：PAuth、RCpc、MTE、MOPS、其它 LSE128、Crypto 等未获本轮批准
     的可选/更高版本扩展，不纳入本轮完成百分比。
   - 只有 `V82-BASE + V82-SELECTED-EXT` 清单闭合，才允许使用“非 SVE profile 已闭合”措辞。

2. **A 线定位为开源综合/PPA 代理，不是 Arria 10 signoff**。
   - 主选 Yosys/ABC generic synth，必要的 `sv2v` 转换；nextpnr/VTR 仅作为条件性代理。
   - 不修改 `rtl/lcvex_core.sv` 等通用 RTL 以迁就工具；遇到不支持时降级为 core/Cache
     分层代理，明确 `N/A`。
   - A 线产物不解除 T-067，不替代 Quartus/板测，不改变 Gate F-BOARD 判定。

3. **C 线多核采用分级完成口径**。
   - `CORE_COUNT=1` 是参数化回归锚点，必须先保持单核完整兼容。
   - 一致性采用共享 L2 上游目录式 MSI；不引入 ACE/CHI，保留现有 AXI4/Avalon 下游边界。
   - 2 核为功能候选；4 核为正确性候选；8/16/32 核只报参数化/资源/有限 smoke，不宣称
     完整架构合规。
   - Linux SMP 是单独后置门，不阻塞 2/4 核交付。

4. **F 单核发布与 G-MC 多核演进分成两条列车**。
   - F 单核发布：当前 P7/P7-B + B 线 V82 profile + A 线代理报告 + 既有 Gate D/F-ISA/F-MEM/F-BOARD。
   - G-MC 多核演进：C0–C6、MC 差分、2/4 核正确性和 8–32 核扩展性，新建 Gate G-MC。
   - G-MC 不反向阻塞 F；只有 F 与 G-MC 都通过后才可选做 F+G 联合 candidate，
     且联合 candidate 必须在同一 SHA 重新跑所有受影响门。

5. **执行节奏按 v2 的 W0–W6 波次**。
   - W0 只做契约/审计：A0、B0、C0、D0，不合入功能 RTL。
   - W1 后按低耦合切片推进；共享 `core/pkg/commit/memory` 热点由集成者串行队列处理。
   - 每个波次以合并 SHA 的 L0–L2 和必要 detached candidate 为出口，不跨 SHA 拼接绿色结果。

## 备选方案

- 继续等 Quartus 修复后再推进 PPA/多核：拒绝，会全局阻塞。
- 把多核纳入当前 F 发布列车：拒绝，会拖住已基本完成的单核 Gate F。
- 把 PAuth/MTE/MOPS/Crypto 等未批准扩展混入本轮“完整”：拒绝，不可验收。
- 用开源 ECP5 结果替代 A10 签核：拒绝，架构不同，只能作趋势参考。

## 影响

- B 线工作必须先生成机器可检查 profile manifest，再按族/编码补实现。
- C 线必须先做 D0 多核差分可行性，再写多核 RTL。
- 任务台账新增 `proposed` 父任务和 A0/B0/C0/D0 等子任务标签；子任务依赖只认 `done`。
- T-067 保持 blocked，不因 A 线代理报告解除；后续 Quartus 重试需在内存/页文件或综合
  范围问题明确解决后由集成者授权。

## 验证与迁移

- 按 v2 计划第 13 节批准后立即行动清单执行。
- 每个任务/波次的精确 SHA、worktree、验证证据以任务 JSON、handoff、evidence 为准。
- 本 ADR 若需修订，新增 ADR，不改写本文件。
