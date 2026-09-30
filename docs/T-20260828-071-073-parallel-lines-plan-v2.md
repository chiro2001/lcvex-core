# LCVEX T-071～T-073 三条并行路线优化执行方案

> 审核对象：[`T-20260828-071-073-parallel-lines-plan.md`](T-20260828-071-073-parallel-lines-plan.md)
>
> 版本：v2（审核优化稿）　日期：2026-08-29　状态：待集成者批准后登记任务
>
> 本文是执行规划，不替代 `ROADMAP.md`、`PROJECT_STATUS.md`、
> `ISA_SCOPE.md`、`P7_FPGA_PARALLEL_PLAN.md` 或已接受的 ADR。批准后，任务
> JSON、阶段快照和 evidence 仍由集成者按 [`MULTI_AGENT_WORKFLOW.md`](MULTI_AGENT_WORKFLOW.md)
> 更新。

## 1. 结论先行

原计划的三条线可以保留，但不能按“三个大任务同时做到最终目标”的方式执行。
优化后的主张是：

1. **A 线先做可行性，再做代理测量。** `sv2v + Yosys + nextpnr-ecp5` 不是
   Arria 10 签核链；完整 SoC 若无法被开源工具消费，降级为分层 RTL 代理，不能
   为了跑通工具而改写架构语义。
2. **B 线先冻结 profile，再补指令。** “完整 ARMv8.2-A（不含 SVE）”不是
   一个可验收的集合；必须用机器可检查的 feature/profile 清单区分基线、已选可选
   扩展和更高版本扩展。只有清单闭合，才允许使用“非 SVE profile 已闭合”的措辞。
3. **C 线先证明 2 核正确，再谈扩展。** 先做 `CORE_COUNT=1` 兼容、双核壳层、
   目录式 MSI/MESI-lite 和可重复的多核差分协议；4 核是正确性候选，8/16/32 核
   先定义为参数化/资源/压力目标，不把 32 核的可综合或短 smoke 写成完整架构
   合规。
4. **汇入以契约窗口和证据为节拍，而不是以日历强切阶段。** A 可与 B/C 分析
   并行；B/C 的共享 `core/pkg/commit/memory` 热点按单队列串行合入。每个波次只
   合入少量已验收垂直切片，任何合入 SHA 失败立即停止队列并保留现场。
5. **当前 Gate F-BOARD 仍是独立阻塞项。** T-065 本地 SoC L0/L1 已合入
   `23218fb`，T-067 在 Quartus 21.4 synthesis 后期两次复现挂起，尚无新的
   fit/STA/SOF；A 线不能替代或解除该门。B/C 可在其外推进，但不能把最终发布写成
   F-BOARD/F-RELEASE 已完成。

## 2. 对原计划的审核

### 2.1 保留的优点

- 把开源评估、ISA 补完、多核演进分成不同关注面，避免把 Quartus 等待时间变成
  全局阻塞。
- 已意识到 ECP5 结果不能等同 Arria 10，也意识到 B/C 会争用 `core/pkg`、Cache
  和 QEMU 路径。
- 已给出初步阶段、验证层级、分支/worktree 和最终 Gate F 合流方向。

综合判断：原文适合作为方向草案，不适合作为立即派单依据；缺口集中在可验收边界、
多核差分可行性和汇入控制，而不是再增加更多功能清单。

### 2.2 必须修正的问题

| 发现 | 当前证据/影响 | v2 修正 |
| --- | --- | --- |
| 基线陈述已过时且不唯一 | 原文以 `78771bf` 和 `0801501` 混写当前点；当前计划审阅 SHA 是 `7301268`，功能合并点为 `78771bf`。T-067 已不是“等待第一次重跑”，而是两次 synthesis 挂起后保持 blocked。 | 文档和任务都记录 `source_sha`、功能基线 SHA、证据 SHA；不再用“当前 feature 分支”代替精确 SHA。 |
| 任务粒度太大 | T-071/072/073 还未登记，三个父任务没有唯一 owner、写集、子依赖和 L0–L2 出口。 | 父任务保持 `proposed`，拆成可独立验收的 A0–A4、B0–B5、C0–C6；子任务依赖只认 `done`。 |
| A 线默认工具链过强 | 本次 shell 未在 PATH 中发现 `yosys`、`sv2v`、`nextpnr-ecp5` 或 VTR；vendor IP、SystemVerilog 特性和 A10 器件也不能直接映射。 | 增加 A0 能力矩阵、core→memory→SoC 三层 go/no-go 和 stub/blackbox 方案；无工具或无时序模型时只交付统计代理。 |
| B 线“完整”边界不成立 | PAuth、RCpc、MTE、MOPS、LSE128、Crypto 等来自不同可选/更高版本扩展；SVE 本身也是可选扩展。把它们混成“ARMv8.2 完整”会造成不可证伪的验收。 | 以 `V82-BASE`、`V82-SELECTED-EXT`、`POST-V82-DEFERRED` 三层 profile 管理；每行有编码、RTL、测试、oracle、负测状态。 |
| B 线工作量没有分水岭 | FP/Advanced SIMD、系统寄存器、维护和异常都被放进一个 B2/B3，无法判断先错点，也会长期占用 core 热点。 | FP 拆算术/转换异常/向量访存；标量、系统维护、编译器覆盖分别设出口。 |
| C 线直接跳到 32 核 | 当前架构和 QEMU 协议均是单核：`CONFIG` 只有 single-vCPU，提交包没有 `core_id`，现有 probe 契约也明确 `CORE_COUNT=1`。 | 先做协议可行性和双核壳层；2 核功能、4 核正确性、8–32 核扩展性分开验收。 |
| 一致性方案未决 | “自研还是 ACE/CHI”留成开放问题会让 RTL 和测试同时漂移；现有 AXI4 下游不应因扩核重写。 | 先采用 L2 上游内部目录式 MSI（必要时再加 MESI-lite），保留现有 probe/abort/drain 契约；AXI4/EMIF 不变，不引入 ACE/CHI。 |
| 多核差分和 checkpoint 未规划 | 逐核 PRE/COMMIT、全局顺序、异步 IRQ、共享内存和每核 sidecar 没有协议版本或失败口径。 | 先做 `LCVX-DIFF-MC-v2` 可行性任务；v1 单核 ABI 保持兼容，v2 才增加 `core_id/global_seq/vcpu_seq/event`。 |
| 多核与当前发布列车耦合 | 若要求 A/B/C 同时达到最终发布，C 的高风险一致性会拖住已有单核 F-ISA/F-MEM/F-BOARD 进度。 | 拆成 F（单核发布）与 G-MC（多核演进）两条列车；C 只在 G-MC 门通过后作为可选合并。 |
| 验证注册表没有新域 | 当前 `scripts/test_registry.json` 只有既有五个域，没有 `fpga-platform` 或多核专项条目；直接发明命令会失去可查询、可排队的事实源。 | W0 先登记/扩展测试条目和资源估计；新命令在 registry 可查询前只标为 planned。 |
| 汇入节奏不够具体 | 只说“先 B 后 C 或先 C 后 B”，没有契约窗口、单次合入检查、重型作业队列和退回规则。 | 固定 W0–W6 波次、共享热点单队列、每次合入后 L0–L2、候选 SHA 再跑 L3/L4。 |
| Gate 边界容易被误读 | Gate D、F-ISA、F-MEM、F-BOARD 的绿色结果可能来自不同 SHA；T-067 的旧 T-064 产物也不能冒充 B5。 | 所有门绑定同一 detached candidate；任何未通过的门只记录限制，不拼接跨 SHA 结果。 |

## 3. 审核时的权威基线

以下事实是本方案的输入，不是对未来任务完成情况的预宣称：

| 项目 | 当前事实 | 对路线的约束 |
| --- | --- | --- |
| 计划审阅点 | `feature/p7-final` 当前 HEAD `7301268`；P7/FPGA 功能合并点 `78771bf`。 | 新任务从集成者明确记录的 clean `base_sha` 派生，不从工作区猜测。 |
| P7/标量验证 | P7-0～P7-5 已有垂直证据；P7-5 `e36b7b1` 有完整 Gate D 复跑；`feature/p7-final` 合并点也有 Gate D 证据。 | B 线必须保留 P6/P7 既有回归，不能把补完工作当成新基线重写。 |
| FPGA B5 | T-065 在 `23218fb` 完成本地 SoC/BRAM/地址映射 L0/L1；T-067 两次 Quartus synthesis 后期挂起，无新 fit/STA/SOF。 | A 线是内部优化参考；F-BOARD 仍单独 blocked，不能用代理数据放行。 |
| Cache/一致性 | B3/B4 主要是 `CORE_COUNT=1` 模块级 candidate；probe response hold/abort、checkpoint drain 顺序已有契约，但尚未完成 core→SoC→QEMU 的 F-MEM 系统接线。 | C 线必须复用并扩展契约，不得把模块级 probe 通过写成多核一致性通过。 |
| 锁步 | QEMU 11.1.0 固定；当前协议和 coordinator 以单 vCPU/单核序列为前提。 | QEMU 多核改动另设串行任务；先验证协议，再写多核 RTL。 |
| 协作/资源 | dsh 采用事件驱动完成通知；写任务须用 direct sibling worktree；本机重型作业合计不超过约 50% 资源。 | 不用 `sleep` 轮询 subagent，不在各 worktree 后台跑 Gate D，不共享 socket、QEMU build 或 checkpoint 链。 |

详细依据：[`PROJECT_STATUS.md`](PROJECT_STATUS.md)、[`ROADMAP.md`](ROADMAP.md)、
[`ARCHITECTURE.md`](ARCHITECTURE.md)、[`COMMIT_PACKET.md`](COMMIT_PACKET.md)、
[`L1_L2_PROBE_CONTRACT.md`](L1_L2_PROBE_CONTRACT.md)、
[`DIFFTEST_QEMU_PLAN.md`](DIFFTEST_QEMU_PLAN.md)、
[`T-20260828-067-b5-fullflow-rerun.md`](handoffs/T-20260828-067-b5-fullflow-rerun.md)。

## 4. 不变的边界与新的完成口径

### 4.1 不变边界

- 目标仍为 ARMv8.2-A AArch64、little-endian；AArch32、EL2/EL3、TrustZone、
  SVE/SME、完整产品级调试/PMU 不因本计划提前进入当前 Gate F。
- 单核默认配置必须继续可编译、可运行并通过既有 Gate D；`CORE_COUNT=1` 是
  所有多核参数化的回归锚点。
- 通用内存下游继续使用 AXI4 Full 128-bit；64B line 的 4-beat INCR、单 ID/
  单 outstanding 约束不因多核直接改写。Avalon-MM 只留在 Catapult 适配层。
- 所有架构状态仍只在 COMMIT 更新。提交包至少保留 PC、下一条 PC、GPR/SP、
  NZCV、内存副作用和异常；多核字段只能追加或由版本化 envelope 承载。
- QEMU 版本、补丁可重放性、失败现场和 checkpoint provenance 规则不放宽。

### 4.2 建议采用的 profile 口径

| Profile | 内容 | 宣称方式 | 处理方式 |
| --- | --- | --- | --- |
| `V82-BASE` | 项目选定的 AArch64 基础标量、系统、异常、MMU/Cache 语义。 | 只有清单每一行有 RTL+定向+差分+负测才可称“闭合”。 | B0 生成机器可检查清单。 |
| `V82-SELECTED-EXT` | 明确列出的 FP/Advanced SIMD、FP16、CRC、LSE 等扩展；已实现项和新增项逐行登记 FEAT/编码。 | 称“V82 非 SVE 选定 profile”，不称整个架构所有可选项。 | B0/B2/B3 分片推进。 |
| `V82-SVE-EXCLUDED` | SVE/SVE2/SME 向量状态和指令。 | 明确排除，不把 ZCR/RDVL shim 当 SVE 实现。 | 保持后置。 |
| `POST-V82-DEFERRED` | PAuth、RCpc、MTE、MOPS、其它 LSE128、Crypto 等未获本轮批准的可选或更高版本扩展。 | 不纳入本轮完成百分比；若日后选择，另建 profile/任务。 | 另建 ADR/任务，不在 B1 里顺手加入。 |

“完整 ARMv8.2-A”在本项目中改写为“`V82-BASE + V82-SELECTED-EXT` 清单闭合的
非 SVE profile”。任何扩展版本或可选性不确定时，先记录 FEAT、架构版本、QEMU
支持情况和是否 required，再派实现任务。

### 4.3 多核完成口径

| 层级 | 可接受的声明 | 不可接受的声明 |
| --- | --- | --- |
| 2 核 | 指定一致性、原子、屏障、IRQ 和故障矩阵在确定性测试及多核差分中通过。 | “已支持任意 ARM 内存模型”。 |
| 4 核 | 目录/互连/中断/启动在压力和回归中稳定，作为多核正确性 candidate。 | 直接推断 8/16/32 核资源和时序。 |
| 8/16/32 核 | 参数化 elaboration、有限 smoke、带宽/面积/延迟趋势和已知限制。 | “32 核完整 Linux/板级/物理签核”。 |
| Linux SMP | 单独的后续阶段门；依赖 4 核正确性和平台中断/PSCI 完成。 | 用裸机 litmus 代替 Linux SMP 验收。 |

### 4.4 两条发布列车

为避免把高风险多核工作倒灌到当前单核阶段，采用两条有明确边界的发布列车：

| 列车 | 包含 | 依赖/出口 | 与另一列车的关系 |
| --- | --- | --- | --- |
| **F-单核发布** | 当前 P7/FPGA 单核、B 线 `V82` profile、A 线的非签核代理报告，以及既有 F-ISA/F-MEM/F-BOARD。 | 在同一 detached SHA 上按现有 Gate F 规则验收；不等待 C。 | C 线从 F candidate 派生，不反向阻塞 F。 |
| **G-MC 多核演进** | C0–C6、MC-v2 差分、2/4 核正确性和 8–32 核扩展性。 | 新建 Gate G-MC（名称可在 ADR 中确认）；要求 F 单核兼容，但不取代 F 门。 | G-MC 通过后，才创建可选的 F+G 联合 candidate；联合 candidate 仍须重新跑所有受影响门。 |

因此，本文中的 `I2/I3/I4` 是多核候选门；当前 `F-RELEASE` 可以在没有 C 线完成
声明的情况下发布，但必须明确记录“多核后置”。A 线代理报告是优化参考而非
F-RELEASE 的放行条件；A 线暂时没有产物也不能伪造或阻塞单核门。

## 5. 优化后的依赖图和阶段门

```text
G0  clean baseline (7301268 / 功能基线 78771bf)
│
├── A0 → A1 → A2 → A3 → A4                         开源综合代理
│
├── B0 → B1 → B2a → B2b → B2c
│          └──────────────→ B3 → B4 → B5             ISA profile 闭合
│                           │
│                           └→ F-I0 → F-I1 单核 candidate → F-ISA/F-MEM/F-BOARD
│
└── C0 ──┬→ D0(多核差分 v2) → C1 → C2 → C3 → C4 → C5
         └→ 与 B1 的 memory/commit 契约检查
                                      │
                                      └→ G-I0 → I2 双核 → I3 四核 → I4 G-MC

F candidate + G-MC candidate ──(可选、重新跑所有受影响门)──> F+G 联合 candidate
T-067 / F-BOARD 是 F 列车的独立外部依赖，当前 blocked；A 不替代它。
```

阶段门定义：

| 门 | 进入条件 | 退出条件 | 失败动作 |
| --- | --- | --- | --- |
| G0 基线门 | clean `base_sha`、既有证据可回读。 | `make compile`、受影响 smoke 和基线 Gate D 证据链明确。 | 不从 dirty worktree 派发；修复/另建 regression task。 |
| G1 profile/契约门 | B0、C0、D0 草案完成。 | ISA profile、commit/memory/core wrapper、协议版本、reset/权限/提交时机均有文档和 owner。 | 暂停实现任务，不以口头决定推进。 |
| G2 垂直切片门 | 单个 A/B/C 子任务完成。 | owner 的 L0–L2、handoff/evidence、写集和已知限制齐全。 | 退回 review；不合入半成品。 |
| G3 波次门 | 2–4 个低耦合任务准备合入。 | 按顺序合入后在合并 SHA 重跑受影响 L0–L2。 | 停止合并队列，保存首个失败点。 |
| G4 候选门 | F 或 G-MC 的目标层级达到。 | F candidate 通过 Gate D、F-ISA/F-MEM；G-MC candidate 另通过 I2/I3/I4 及声明的多核门。若做联合 candidate，必须在同一 SHA 重跑两套门。 | candidate 冻结为失败现场，开 regression task；不得因 G-MC 失败撤销已通过的 F 证据。 |
| G5 发布门 | F-BOARD 的外部条件满足。 | 同一 SHA 的 F-ISA、F-MEM、F-BOARD 和完整 Gate D 全绿。 | 只能发布已通过的门，不能拼接不同 SHA。 |

### 5.1 父/子任务登记映射（逻辑标签）

`A0`～`C6`、`D0`、`I0`～`I4` 是路线标签，不是任务注册表 ID。批准后由集成者为
每个垂直包分配下一个 `T-YYYYMMDD-NNN`，再写入唯一 owner、`base_sha`、worktree、
写集和验证资源；不要把一个父任务交给多个 owner 共享写集。

| 父任务 | 子标签 | 建议 owner 子域 | 主要依赖 | 默认写集 | 最高必跑层级 |
| --- | --- | --- | --- | --- | --- |
| T-20260828-071 | A0–A4 | `fpga-platform` + `verify-suite` | G0；A2 依赖 A1 | `fpga/opensynth/**`、opensynth 脚本/报告、独立 stub | A0–A2 L1；A3/A4 由集成者审计 |
| T-20260828-072 | B0–B5 | `core-isa` + `verify-suite` | G0；B1 依赖 B0；B2/B3 依赖接口冻结 | decoder/FP/NEON 模块和测试；共享 core/pkg 需预约 | 单片 L2；B5 detached L3 |
| T-20260828-073 | C0–C6、D0 | `mem-subsys` + `difftest-infra` | G1；C1 依赖 C0/D0；C2 依赖 B1 契约 | 新 cluster/coherence 模块、MC harness、目录/sidecar | C1/C2 L2；C4 规模报告；G-MC 门由集成者执行 |
| 集成波 | I0–I4 | `root/integrator` | 对应父/子任务 `done` | 热点接线、任务台账、candidate manifest | 合并 SHA L0–L2；候选 L3/L4 |

若要扩展 `test_registry` 的域或 schema，先单独登记基础设施任务；在校验器支持前，
新测试只能标为 `planned`，不能悄悄写入一个未知 domain。

## 6. 线 A：开源综合/面积/关键路径代理

### 6.1 目标和限制

A 线回答“逻辑大致花在哪里、优化趋势是什么”，不回答“Arria 10 已签核”。
厂商 Qsys/EMIF/EPCQ/JTAG IP 使用 stub 或 blackbox，不能复制到通用 RTL，也不
能为适配 Yosys 改变架构行为。

### 6.2 详细节点

| 节点 | 工作包 | 写集/产物 | 退出条件 |
| --- | --- | --- | --- |
| A0 能力矩阵 | 建隔离工具环境并固定版本；分别试编译小型 SV、`lcvex_core`/Cache、SoC wrapper；记录 package/struct/interface/厂商原语失败点。 | `fpga/opensynth/toolchain.lock`、`capability.json`、转换/ lint 日志。 | 至少完成小型 SV 和一项真实 LCVEX 模块；工具缺失或失败有明确原因和 fallback。 |
| A1 核心/内存代理 | 用 Yosys/ABC 做 core、I-L1/D-L1/L2、AXI4 模块的 generic synth；vendor/PLL/EMIF 仅 blackbox；重复运行检查网表/统计稳定。 | `fpga/opensynth/*.ys`、`build/tmp/opensynth/<run>/stats.json`、网表 hash。 | 0 error；两次同输入输出统计/网表 hash 一致；报告 LUT/FF/RAM/DSP 或 N/A。 |
| A2 SoC stub | 对 `lcvex_catapult_soc_top` 建最小 tie-off/stub（calibration、Avalon、JTAG/EPCQ）；先 `verilator --lint`，再 generic synth；只有存在对应 device pack 才尝试 nextpnr。 | wrapper、stub、filelist、`synth.rpt`、可复放脚本。 | 顶层可 elaboration；任何未支持 IP 均列出；nextpnr 不可用时不伪造 Fmax。 |
| A3 相关性报告 | 将 A10 T-064 的真实资源/STA 作为“方向参考”，只比较模块占比、排序和趋势；禁止线性换算 ECP5→A10。 | `docs/handoffs/T-20260828-071-open-synth-proxy.md`、JSON 报告和 hash。 | 报告含工具/输入 SHA、资源、关键路径或 N/A、限制、建议；可从 clean SHA 重放。 |
| A4 趋势回归（可选） | 对已通过的 proxy 建轻量阈值/差分报告，避免每个提交触发重型 place-and-route。 | `scripts/opensynth/`、趋势 artifact。 | 只有 A3 稳定后才启用；阈值失败只阻止 proxy 合入，不改变 Gate F。 |

### 6.3 A 线 go/no-go

- 若 A0 无法解析完整 SoC：转入 A1 核心/Cache 代理，保留失败日志；**不**修改
  `rtl/lcvex_core.sv` 以迁就工具。
- 若 A2 无法获得 ECP5 device pack：只交 generic 逻辑统计；关键路径标为
  `N/A`，不得把 ABC delay 当 FPGA Fmax。
- 若同一输入两次统计不一致：先查宏、随机种子、工具版本和环境；不发布趋势结论。
- A 线报告必须明确“不是 Arria 10 signoff、不替代 Quartus、不解除 T-067”。

## 7. 线 B：V82 非 SVE profile 补完

### 7.1 共同规则

每个 profile row 至少包含：`feature/FEAT`、架构版本、编码范围、required/optional、
RTL 模块、SV 定向、Cocotb、QEMU 参考配置、负向/保留编码、checkpoint 影响和
状态。覆盖率的分母是声明的 profile rows，不是随机 trace 偶然观察到的族数。

每个实现切片的最小验证包：

```text
L0  decoder/encoder/raw-bit microbench
L1  SystemVerilog + Cocotb（含 reset/backpressure/负测）
L2  固定 QEMU 11.1.0 的 strict lockstep + 必要 checkpoint
L3  集成者在 detached candidate 跑 Gate D/覆盖记账
```

QEMU fork、插件、协议或参考模型的写入始终是全局串行任务；B 的普通 RTL/测试
任务不得自行修改共享 QEMU fork。

### 7.2 详细节点

| 节点 | 工作包 | 重点和边界 | 退出条件 |
| --- | --- | --- | --- |
| B0 profile 审计 | 从 `ISA_SCOPE.md`、`ISA_GAPS.md`、编译器反汇编、QEMU probe 生成机器可检查清单；标出当前已实现、shim、UDEF 和后置。 | 不新增指令；先纠正“v8.2/后续扩展”标签；SVE 单列排除。 | 清单可生成/校验；每行有 oracle 或明确 blocked；集成者批准 profile。 |
| B1 标量/解码闭合 | 按编译器收益补 logical shifted-register ROR、剩余寻址/符号扩展、保留位严格拒绝、系统/分支边界等；仅实现已在 profile 的族。 | 维护 XZR/SP、W 零扩展、NZCV、异常和连续 WB `commit_fire` 语义；不把 MOPS/MTE/PAuth 等混入。 | 每个 row 的成功/保留/UDEF 证据齐全；P6 scalar、随机和 Gate D 受影响子集全绿。 |
| B2a FP/ASIMD 算术 | 在现有 P7-0～P7-5 上按数据类型/操作族补齐声明的 FP32/64/16 和 NEON 算术、比较、FMA。 | 保留 raw-bit NaN、signed zero、FPSR sticky、FPEN trap 和单 commit 多副作用限制。 | SV/Cocotb/raw lockstep 逐族通过；未支持 encoding 有负测。 |
| B2b 转换/舍入/异常 | FCVT/整数转换、FRINT、异常 enable/flag、FPCR 访问矩阵；先定义 QEMU 与 ARM ARM 的 oracle 差异。 | 不因 host float 方便而替代 raw-bit oracle；异常状态只在 COMMIT 生效。 | 四种 rounding、NaN/Inf/subnormal、trap/flag 和 checkpoint restore 全覆盖。 |
| B2c 向量访存/编码族 | lane/by-element、replicate、结构化/多寄存器访存、fault/preflight，按可支持的 store slot 分批。 | 与 L1/L2 backpressure、byte lane、fault 原子性联测；不顺手扩成 SVE。 | 每一族有内存副作用比较、延迟/背压和失败现场；Cache 配置不回归。 |
| B3 系统/维护/原子 | 系统寄存器矩阵、TLBI/DC/IC、barrier、LSE/RCpc 等**已批准**扩展；补 reset、权限、mask、提交时机。 | 每个新寄存器说明 reset/读写权限/commit；跨核语义留给 C，后续扩展另建 profile。 | QEMU probe、SV/Cocotb、strict lockstep、异常/维护/sidecar 证据闭合。 |
| B4 编译器和覆盖闭合 | `-O0/-O2/-Os` baremetal-C、反汇编 gap、随机/定向交叉覆盖；加入 reserved/unsupported negative 集。 | 不用 Linux 动态窗口推导静态全覆盖；失败保存 ELF、反汇编、状态和 seed。 | 声明 profile 100% rows 命中；旧 P6/P7 Gate D 子集无回归。 |
| B5 profile freeze | 在一个 clean candidate 上锁定 profile、QEMU/config/hash、支持/后置清单。 | 不把“未列族”默认为支持；不跨 SHA 拼绿色结果。 | Gate D 全量、profile coverage、P6/P7 checkpoint/max 兼容、handoff/evidence 定稿。 |

### 7.3 B 线的停止规则

- 某 row 没有稳定 QEMU/参考 oracle：标为 `blocked`，先做 probe/决策，不以猜测
  通过。
- 连续 WB、store 接受/提交或异常年轻指令出现问题：暂停新 ISA 扩展，优先修复
  commit/memory handshake 和 SVA。
- 只要新增族会改 `rtl/lcvex_pkg.sv`、`rtl/lcvex_core.sv`、顶层 filelist 或
  QEMU，就关闭当前波次的并行写入，由集成者开接口窗口。

## 8. 线 C：2→4→8/16/32 核演进

### 8.1 推荐的架构决定

1. **一致性互连**：在共享 L2 上游新增内部 line-level 目录协议，第一版采用
   `I/S/M`（MSI）和确定性仲裁；只有 MSI 正确后，才评估 E/O 或更复杂优化。
2. **下游保持不变**：每个核不直接成为 DDR AXI master；现有 L1→共享 L2→AXI4
   →Avalon/EMIF 边界保持，`core_id/source_id/transaction_id` 扩展为目录索引。
3. **协议选择**：本阶段不引入 ACE/CHI。若未来硬件一致 DMA 必需，再另建 ADR 和
   bridge 任务，不把 DMA 需求隐式塞进 C2。
4. **顺序口径**：先定义项目要求的原子/屏障/litmus 子集和目录线性化点；不宣称
   在未验证前符合完整 ARM memory model。round-robin 只用于可重放，不等于架构
   顺序；C2 还要用受控的调度扰动/交错集合检查允许结果。

### 8.2 详细节点

| 节点 | 工作包 | 重点 | 退出条件 |
| --- | --- | --- | --- |
| C0 cluster contract | 设计 core wrapper、reset/start/stop/quiesce、`core_id`/MPIDR、每核 irq/timer、提交和内存请求接口；定义目录状态/仲裁/错误回滚。 | `CORE_COUNT=1` 默认端口和行为完全兼容；复用 L1/L2 probe response hold/abort、drain 顺序。 | 端口表、状态机、时序图、reset 值、backpressure/kill/SVA 草案获 I0 批准。 |
| D0 多核差分可行性 | 扩展协议 envelope 为 `LCVX-DIFF-MC-v2`：`version, core_id, global_seq, vcpu_seq, event_kind, commit`；保留 v1 单核解析。 | 先做 QEMU 多 vCPU/插件回调可行性 probe；确定性 round-robin 或 token scheduler；QEMU fork 修改串行；明确 PRE（执行前）与 COMMIT（退休后）边界，绝不把 before-instruction callback 当通用 after-retirement hook。 | 两核最小 PRE/GO/COMMIT/ACK/ASYNC/STOP 序列可重放；若 QEMU 做不到逐核退休，明确转 reference-model/litmus fallback。 |
| C1 双核壳层 | 参数化复制核心和本地状态，先关闭/旁路 cache 或使用不共享地址的内存，验证启动、core ID、独立 reset/irq、WFI/WFE。 | 单核 regression 与双核 shell 同时保留；不在此节点宣称 coherence。 | 2 核编译/elaboration、独立程序和 per-core commit 记录通过；`CORE_COUNT=1` 全回归。 |
| C2 双核 MSI | 共享 L2 目录、ReadShared/ReadUnique/Upgrade、I/D-L1 probe/失效、dirty owner、原子/exclusive monitor、错误和重试。 | 先 correctness 后性能；目录 invariant：dirty 唯一、probe 未握手不复用 tag、fault 不产生 stale response；`DC clean + IC invalidate + ISB` 可见性单列。 | message passing、store-buffering、load-buffering、CAS/LDXR-STXR、barrier、随机延迟和 reset/fault 全绿。 |
| C3 四核系统 | 扩展 GIC/PSCI/Timer、IPI/SEV/WFE、TLB shootdown、启动次序、共享 MMIO 路由和公平仲裁。 | 异步事件必须有确定的 global sequence；中断/电源状态进入 checkpoint。 | 4 核裸机同步/IRQ/maintenance/长期压力通过；单核/双核不回归。 |
| C4 8/16/32 扩展性 | `CORE_COUNT` 参数化、目录位图/仲裁树、带宽/队列/面积/仿真时间测量；bounded smoke 和 elaboration。 | 32 核是规模目标，不是当前板级目标；超过资源时记录上限和退化配置。 | 每个规模至少有 compile/elaboration、有限事务 smoke、资源/延迟报告；不得将缺少完整 lockstep 的规模标为功能完成。 |
| C5 Linux SMP（后置） | 在 C3/C4 和平台中断/PSCI 稳定后，尝试 Linux SMP bring-up、scheduler/共享页表/用户态。 | 依赖 F-MEM、GIC、多核 timer、TLBI 和软件镜像；不阻塞前面的双核/四核交付。 | 另设 Gate；同一 image/DTB/QEMU manifest 的可复现 SMP 窗口和失败分类。 |
| C6 合拢 | 与 B 的 profile/commit/memory 变更在同一 candidate 汇合；逐核状态、共享内存副作用和 checkpoint v4 一起验证。 | 任何协议版本、wire layout 或 sidecar 变化都要升级 manifest，拒绝旧链伪恢复。 | I2/I3/I4 通过，证据可从同一 SHA 重放。 |

### 8.3 多核提交与 checkpoint 最小扩展

- 单核 `commit_packet_t` 字段保持兼容；多核用外层 envelope 增加 `core_id`、
  `global_seq`、`vcpu_seq`、事件类型和版本，不把核心编号塞进旧字段的隐含位。
- 每个 commit 仍须携带 PC、next PC、GPR/SP、NZCV、所有 store slot、异常、
  原子/监视器效果以及存在时的 FP/NEON effect；共享内存的可见顺序由目录线性化
  点记录。
- checkpoint 至少增加每核 GPR/PSTATE/system/timer、L1 metadata/data、目录状态、
  pending probe/transaction、GIC/IPI/event 和全局调度 token；恢复顺序先停发新
  请求，再恢复目录/缓存，最后释放核。
- `global_seq` 只表示协调器定义的确定性事件顺序，不把宿主线程执行顺序当作
  架构顺序；无序或不可观察的内部时序不进入差分比较。

## 9. 汇入节奏和合并队列

### 9.1 波次安排

波次是“契约/证据完成”的逻辑节点，不是日历承诺。默认每个波次最多合入 2–4
个低耦合任务；共享热点或协议变化自动拆成单任务波次。

| 波次 | 可并行开发 | 集成顺序与检查 | 波次出口 |
| --- | --- | --- | --- |
| W0 基线/契约 | A0 能力调查、B0 profile、C0 cluster 设计、D0 只读协议 probe。 | 先锁 `base_sha`，由集成者分别审定 F 列车的 profile/commit/memory 契约和 G-MC 的 cluster/diff 契约；不合入功能 RTL。 | G1、F-I0、G-I0 文档和 task DAG 完整。 |
| W1 低耦合验证 | A1 核心代理、B1 的纯 decoder/encoder 子集、C1/D0 的独立 harness。 | A→B→C；每项先核对写集，再在各自 merge SHA 跑 L0/L1；QEMU 仍单队列。 | 单核 smoke 不变；双核 shell 可 elaboration。 |
| W2 单核语义波 | A1 结果完善、B1 标量切片、C1 shell 接线。 | B 先于触碰共享 `core/pkg/commit` 的 C 变更；每次合入后跑 P6/P7 受影响 L2。 | B 标量片段和 C1 通过 G2；连续 WB/store/flush SVA 无回归。 |
| W3 FP/SoC 代理波 | A2 SoC stub、B2a/B2b、C2 前的目录/协议模块级实现。 | A 可独立合；B 的 FP/QEMU 任务串行；C2 只能在 memory/commit 契约确认后接线。 | P7 raw-bit/FP checkpoint 与模块级 MSI/目录测试通过。 |
| W4 系统/一致性波 | B2c/B3、C2→C3、A3 报告。 | 共享热点按 B→C 串行；任何 QEMU 协议改动独占该波次和资源槽。 | F-MEM 受影响 L2、双核 litmus、系统寄存器/维护证据齐全。 |
| W5 闭合/扩展波 | B4/B5、C4、A4（若启用）。 | F 与 G-MC 各自从对应最新 SHA 创建 detached candidate；先跑短 L2，再排 Gate D/L3。 | `V82` profile closure、F 单核 candidate、4 核 candidate、规模报告。 |
| W6 最终候选波 | 仅做必要修复和证据补全；不再引入新功能。 | F 与 G-MC 分门验证；若做联合 candidate，每次只允许一个联合 SHA，并重新跑所有受影响门。 | F-ISA/F-MEM/F-BOARD/F-RELEASE 与 I4 G-MC 状态分别记录。 |

### 9.2 每次合入的固定动作

1. 集成者检查依赖是否 `done`、`base/head/branch/worktree`、写集、handoff、
   evidence 和时间戳；子 Agent 不修改 `TASKS.md`、`ROADMAP.md`、`PROJECT_STATUS.md`
   或别人的 worktree。
2. 只合入一个已报告的垂直切片，使用 cherry-pick 或显式 merge；不把多个 owner
   的半成品拼成“看起来完整”的提交。
3. 在**合并 SHA**重跑任务声明的 L0–L2。失败即停止后续波次，保存首个失败指令、
   反汇编、执行前状态、RTL/QEMU 状态、最近提交和重现命令。
4. 每 2–4 个低耦合任务或每次契约/协议变化后，创建 detached gate worktree，
   排队一次较重的 Gate D/F-MEM 子集；重型作业不在 owner worktree 常驻后台。
5. 只有 candidate 的所有必需门在同一 SHA 通过，才更新阶段快照或考虑进入 `main`。
   T-067 旧产物、另一分支的绿色日志和 proxy Fmax 都不能补齐缺失门。

### 9.3 分支、写集和资源

建议父线名（批准后再登记）：

```text
feature/T-20260828-071-open-synth-proxy
feature/T-20260828-072-v82-profile
feature/T-20260828-073-multicore
```

实现子任务仍须使用唯一 topic branch 和仓库外 direct sibling worktree。建议写集：

| 线 | 默认写集 | 集成保留热点 |
| --- | --- | --- |
| A | `fpga/opensynth/**`、`scripts/opensynth/**`、独立 proxy wrapper、handoff/evidence。 | 不改通用 RTL 语义；若需 filelist/Makefile 入口，单独预约。 |
| B | 按 B1/B2/B3 拆分 decoder、FP/NEON 模块和对应测试。 | `rtl/lcvex_core.sv`、`rtl/lcvex_pkg.sv`、`rtl/filelist.f`、顶层 Makefile、QEMU patch、commit/checkpoint wire。 |
| C | 新建 `rtl/lcvex_cluster_*`、`rtl/lcvex_coherence_*`、多核 TB/runner。 | core wrapper/commit packet、共享 L2 端口、`sim/difftest`、GIC/PSCI 热点。 |
| QEMU/协议 | 一个串行任务独占 QEMU fork/build/socket/checkpoint 协议。 | A/B/C 不得同时写 QEMU 或复用可写 build。 |

本机总资源仍按工作流约束不超过约 50%；默认一个重型槽（Gate D、长锁步、Quartus
或大型综合）加若干低成本 L0/L1。dsh 下 subagent 采用完成通知，不主动轮询；只有
远端宿主或物理板等待才使用带时间戳的整段等待。owner 的报告必须把
`sent_at/received_at/reported_at` 双写到 handoff 和 evidence。

## 10. 验证和证据套餐

| 线/阶段 | L0 | L1 | L2 | L3/L4 |
| --- | --- | --- | --- | --- |
| A | 工具版本、输入 hash、elaboration、转换/lint | Yosys/ABC 统计、stub 边界、重复性 | 一般不做架构 lockstep；如 wrapper 改行为则跑对应 smoke | A3 报告；Quartus/板测仍属 F-BOARD，不由 A 代替 |
| B | encoder/decode/raw-bit、profile checker | SV/Cocotb、SVA、backpressure、负测 | QEMU 11.1.0 A76/max strict lockstep、FP/系统 checkpoint | detached Gate D、编译器 C、nightly/patch replay |
| C1/C2 | 参数化 elaboration、目录 invariant、协议 frame | SV/Cocotb BFM、随机延迟、litmus、reset/fault | MC-v2 per-core lockstep 或明确 reference-model fallback | 2/4 核候选、长压测、Linux SMP（后置） |
| 合拢 | clean SHA/manifest | 受影响全量 | 合并 SHA 受影响套餐 | 同一 candidate 的 Gate D/F-ISA/F-MEM；F-BOARD 需外部条件 |

### 10.1 覆盖和失败现场

- B 的覆盖报告同时显示 `declared_rows`、`expected_hit`、`observed_families`、
  negative rows 和未覆盖原因；不能只报告动态执行数量。
- C 的覆盖至少按核数、目录状态转移、probe 命令、dirty owner、原子结果、barrier、
  IRQ/SEV/WFI、fault/retry 和 reset epoch 统计。
- A 的报告记录工具版本、命令、源 SHA、stub 清单、资源/时序/N/A、运行 hash；
  不把 ECP5 数字转换成 A10 资源百分比。
- 所有 failure bundle 保留指令编码/反汇编、执行前状态、RTL commit、QEMU 状态、
  内存副作用、最近 32 条记录、seed、manifest 和 artifact hash；大文件只放
  `build/tmp/<task-id>/` 或外部 artifact，不进 Git。

### 10.2 现有可复用验证入口

任务登记时优先复用以下已在 registry 中存在的入口；多核和开源综合的新入口先以
`planned` 登记并补资源估计，不在文档中把尚未接线的命令写成已可执行：

| 层级 | 现有入口 | 适用场景 |
| --- | --- | --- |
| L0 | `make microbench` | B 标量/编译器快速语义；C 壳层前的裸机 smoke |
| L1 | `make test`、`make check-encoders` | 单元、SVA、编码器和 P7/P6 基线 |
| L1 | `make checkpoint-manifest-smoke`、`make checkpoint-resume-manifest-smoke` | B/C 协议或 sidecar 改动后的 provenance 检查 |
| L2 | `make difftest`、`make difftest-hazard`、`make p4c`、`make p5a` | B 标量/异常/MMU 受影响回归 |
| L2 | `make p6-lse`、`make p6-wfi`、`make p6-maint-v82` | 原子、等待、维护和系统寄存器回归 |
| L3 | `bash sim/difftest/run_gate_d.sh --parallel` | 仅集成者在 detached candidate 排队运行 |
| registry | `python3 scripts/test_registry.py --check` | 每次新增/修改测试条目前的注册表校验 |

C 的 `MC-v2`、litmus、目录压力和 A 的 opensynth 命令需在对应任务中声明实际
入口、资源和 artifact 路径；在此之前，不能用表中现有单核命令替代多核验收。

## 11. 风险登记与处置

级别含义：`阻断` 表示不得进入下一依赖节点；`高` 表示可继续无关低耦合工作，
但不能合入受影响热点；`中` 表示记录并在波次出口复核。

| ID | 风险/级别 | 触发信号 | 预防 | 止损与责任 |
| --- | --- | --- | --- | --- |
| R-A1 | SV/vendor IP 无法开源综合（高） | sv2v/Yosys 在 package/interface/厂商原语处失败。 | A0 分层能力矩阵、blackbox/stub、固定工具环境。 | 降级为 core/Cache generic proxy；A owner 保留日志，不改架构 RTL。 |
| R-A2 | 代理器件误导优化（高） | ECP5 Fmax/资源与 A10 趋势矛盾。 | 只比较模块排序和相对趋势，明确 N/A。 | A3 标记“非签核”；Gate F-BOARD 仍由 T-067/Quartus 负责。 |
| R-A3 | Quartus synthesis 继续挂起（阻断） | T-067 类似的 CPU 停止增长、无 fit/STA/SOF。 | 交互会话/分离步骤/日志和工具版本检查，限制盲目重跑。 | 保持 T-067 blocked，转环境/工具支持；不把旧产物复用。 |
| R-B1 | “完整 v8.2”范围膨胀（阻断） | 新任务同时提出 PAuth/MTE/MOPS/SVE/Crypto 等无 profile 项。 | B0 feature manifest 和 ADR；后续扩展独立任务。 | 暂停派单，退回 scope review；不修改覆盖分母。 |
| R-B2 | 连续提交/Store handshake 回归（阻断） | 连续 WB 丢 commit、store 重复、flush 后有年轻提交。 | 先修 `commit_fire`、request/response、SVA，再扩 ISA。 | 停止 B2/B3，回到 B1/回归任务；保留首错现场。 |
| R-B3 | QEMU oracle 不稳定（高） | 同一指令 raw bits/异常/系统寄存器结果不一致。 | 固定 QEMU 11.1.0、probe、允许集合和 patch hash。 | row 标为 blocked，不用 host float/随机值代替 oracle。 |
| R-C1 | 多核协议无法逐核退休（阻断） | QEMU plugin 只能 before callback，无法提供 per-vCPU 精确 COMMIT。 | D0 先做可行性 probe；v1/v2 版本隔离。 | 转 reference-model/litmus fallback；不宣称多核 strict lockstep。 |
| R-C2 | 一致性状态机丢脏数据/重复 probe（阻断） | dirty owner 不唯一、probe 未握手即复用 tag、fault 后 stale response。 | 复用现有 hold/abort/drain 契约，MSI 先于优化，目录 invariant/SVA。 | 2 核失败即冻结规模扩展，保留 line/epoch 现场。 |
| R-C3 | ARM 内存模型/原子口径不清（高） | litmus 在不同调度下结果无法归类，barrier/LDXR-STXR 分歧。 | 先声明项目 litmus 子集和线性化点；确定性调度用于复现，再覆盖受控交错集合。 | 不写“完整合规”；另建 memory-model 决策任务。 |
| R-C4 | IRQ/PSCI/TLBI 竞态（高） | WFI/SEV、IPI、CPU_ON/OFF、shootdown 顺序不可重放。 | 每核事件序列、GIC/Timer sidecar、阶段化 C3。 | 先关闭 Linux SMP，保留裸机失败包和最小复现。 |
| R-C5 | 32 核仿真/资源爆炸（高） | RSS/运行时间超限、目录位图或仲裁时序恶化。 | 2/4 核质量门；8–32 核 bounded smoke 和参数化报告。 | 停在最高通过规模，不把规模目标写成完成。 |
| R-C6 | checkpoint 恢复遗漏 per-core 状态（高） | 恢复后 next PC、目录、GIC、event 或 cache line 不一致。 | manifest v4、版本/hash、先 quiesce 再恢复目录/缓存。 | 拒绝旧链作为多核证据；开 checkpoint regression。 |
| R-I1 | B/C 共享热点冲突（高） | `core/pkg/filelist/Makefile` 同时出现未合并改动。 | 写集预约、契约窗口、B→C 串行热点队列。 | 停止一方写入，重新从最新 integration SHA 派发。 |
| R-I2 | 跨 SHA 拼接绿色证据（阻断） | Gate D、FP、Cache、Board 来自不同 commit。 | detached candidate、一门一 SHA、merge SHA 复跑。 | 清空候选状态，保留失败证据，不能晋级 main。 |
| R-I3 | 重型作业资源互撞（高） | 多个 Gate/Quartus/长锁步同时抢占 CPU/RAM/socket。 | 集成者单队列、50% 上限、唯一 `RUN_ROOT`。 | 杀的是明确任务 job，不误删 worktree/未知文件；重排队列。 |
| R-I4 | 文档/任务台账漂移（中） | 状态、SHA、owner、handoff/evidence 不一致。 | 子任务只报告，集成者批次更新 `TASKS/ROADMAP/STATUS`。 | 新建纠错/regression 记录，不改写已归档 handoff。 |
| R-I5 | 非一致 DMA/板级假设被隐式引入（高） | HPS/EMIF/外设写入绕过目录却被当 coherent。 | 明确 DMA non-coherent；软件维护或另建 ACE/CHI 任务。 | 从当前 Gate 排除该场景，记录已知限制。 |

## 12. 执行指导和决策默认值

### 12.1 建议直接采用的默认值

| 决策 | 默认值 | 需要何时重审 |
| --- | --- | --- |
| A 工具链 | Yosys/ABC generic synth 为必选；nextpnr/VTR 为条件性代理。 | A0 证明目标器件/时序模型确实可用时。 |
| B 范围 | `V82-BASE + V82-SELECTED-EXT`，SVE 和未批准 post-v8.2 扩展后置。 | profile row 有新证据或用户明确扩大范围时。 |
| C 一致性 | 共享 L2 目录式 MSI，现有 probe/drain 契约扩展；不引入 ACE/CHI。 | 2/4 核正确性通过且性能/外部 DMA 有明确需求时。 |
| C 差分 | `LCVX-DIFF-MC-v2` + 确定性 round-robin；QEMU 修改全局串行。 | D0 证明 QEMU 无法提供足够的 per-vCPU 语义时。 |
| 汇入顺序 | 契约 → A 独立产物 → B 单核语义 → C 壳层/一致性 → 候选 Gate。 | 共享热点或协议发生实质变化时。 |
| 调度策略 | A/B/C 三条线**默认尽可能并行**；只有真实依赖、计划中的汇合点/门、共享热点或资源冲突才串行。单线 blocker 不阻塞其它线的独立任务。 | 每次新波次派发、出现新依赖或写集冲突时复核。 |
| 发布口径 | 2 核/4 核分级声明；8–32 核只报规模结果；F-BOARD 依赖真实 Quartus/板。 | 对应阶段门全部同 SHA 通过时。 |

### 12.2 实现时应优先做的事

- 先把接口和 reset/权限/提交时机写成契约，再让 owner 写 RTL；不要用合并冲突
  作为接口设计工具。
- B 线尽量把新编码放入已有 FP/decoder 子模块和独立测试；`core.sv/pkg.sv` 的
  共享改动集中到短接口窗口，由集成者批量接线。
- C 线先复制一个可关闭 cache/coherence 的核心壳层，验证 core ID/事件/提交协议，
  再打开目录；不要从第一天展开 32 个完整核。
- A 线遇到工具限制时增加 wrapper/stub 和限制说明，而不是删断言、改参考结果或
  把不可综合代码标为可综合。
- 每个失败都以第一分歧为界；失败点之后的指令、动态覆盖数和长跑时长不计入通过。

### 12.3 明确的停止/升级条件

1. A0 两次独立能力尝试仍无法进入目标层级：切换 proxy scope，提交 A0 handoff，
   不继续投入 place-and-route。
2. B0 profile 或 QEMU oracle 未定：只允许审计/探针，不派实现任务。
3. C1 双核壳层未通过：不得开始 C2；C2 未通过：不得实例化 4 核以上功能测试。
4. 任何共享协议改动未完成集成者方向审查（若有可用的独立审查通道再补充一次）
   或 evidence 不完整：保持 `review`，不合入长期线。
5. T-067 再现挂起：按既有 recovery steps 转工具/环境排查；不能反复消耗 Gate
   队列，也不能把 A 代理报告写成 B5 结果。

## 13. 批准后的立即行动清单

以下顺序不要求等待 T-067；它们的写集和重型资源可隔离：

1. 集成者以 `7301268` 为规划快照、以功能基线 `78771bf` 为验证锚点，确认 clean
   worktree，并将 T-071/072/073 以 `proposed` 父任务登记；暂不把三个父任务标为
   `active`。
2. 新增一个 scope/feature manifest 决策记录（可作为 ADR-005），批准
   `V82-BASE/V82-SELECTED-EXT/POST-V82-DEFERRED` 和“非 SVE profile”用语。
3. 登记并派发 A0、B0、C0/D0 四个低耦合垂直任务；每项使用唯一 sibling worktree，
   写集不含 QEMU 共享修改和里程碑热点。
4. 集成者先复跑基线的快速检查（`make compile`、`make test`、受影响 P7/P6
   smoke）；Gate D 作为 detached 重型槽排队，不由四个 owner 各自启动。
5. G1/I0 通过后，按 W1/W2 顺序登记 B1、A1、C1；第一次涉及 `core/pkg/commit`
   的改动前冻结端口表、commit envelope 和失败包格式。
6. T-067 继续保持 blocked，按 handoff 的交互会话/分离 synthesis 方案等待外部
   工具条件；只有取得新 fit/STA/SOF evidence 才能打开 F-BOARD 后续节点。
7. 每个波次结束由集成者更新任务台账和阶段快照；未通过的路线只更新新的
   regression/blocked 记录，不改写已归档历史证据。

## 14. 最终验收清单

### A 线

- [ ] 工具版本、输入 SHA、stub/blackbox 清单和两次重放 hash 可审计。
- [ ] 有 core/Cache/SoC 分层资源报告；无法测量的指标明确 `N/A`。
- [ ] 报告明确非 A10 signoff、不替代 Quartus、不解除 T-067。

### B 线

- [ ] profile manifest 的声明 rows 100% 有 RTL、SV/Cocotb、QEMU/参考或明确
  blocked 证据；负向/保留编码不被遗漏。
- [ ] P6/P7 回归、raw-bit FP、系统寄存器/维护/异常、checkpoint 和编译器 C
  套件在同一候选上通过。
- [ ] 未完成扩展（含 SVE、未批准 post-v8.2）仍被明确标注，不以“完整 ARMv8.2-A”
  过度宣称。

### C 线

- [ ] `CORE_COUNT=1` 完整回归无变化；2 核 MSI 和多核协议有可重放证据。
- [ ] 4 核达到正确性 candidate；8/16/32 核只有在 compile/bounded smoke/
  资源报告齐全时才报告规模结果。
- [ ] per-core commit、全局事件序列、目录/cache/GIC/Timer/checkpoint 状态均有
  版本化证据；Linux SMP 若未通过则单独列后置限制。

### 合拢/发布

- [ ] 每一项门都绑定同一个 detached candidate SHA；合并后重新跑任务要求的
  L0–L2，Gate D/F-ISA/F-MEM/F-BOARD 分门记录。
- [ ] `main` 只在本地 Gate D、CI 和阶段门策略满足后快进；不能因 A/B/C 某条线
  的局部绿色而绕过项目 Git 规则。

本 v2 文档批准后，旧初版仅作为审核输入保留；实现状态、精确命令和 artifact
事实分别以任务 JSON、handoff 和 evidence 为准。
