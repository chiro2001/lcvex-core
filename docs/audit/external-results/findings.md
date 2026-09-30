# LCVEX 外部静态审计结果

> 审计执行任务：T-20260829-105
> 材料准备任务：T-20260829-104
> 审计基线：`2edc7573551bcd8e7ab2408858d011aed58fed2c`
> 分支：`verify/T-20260829-105-external-audit-run`
> 方式：静态审计优先；动态回归不作为本轮完成条件
> 后续状态：本报告是 2026-08-29 静态审计的原始结果。截至 2026-08-30，
> 其中部分 action/dynamic 项已由后续内部任务关闭，最新处置状态以
> [`action-items.md`](action-items.md) 与 `docs/audit/action-dag.md` 为准。

## 1. 结论摘要

本轮按 `docs/audit/01` 至 `09` 的范围，独立核对任务 JSON、handoff、evidence、
Git 历史、构建/CI/Gate 入口、RTL、testbench、QEMU 协议、FPGA 平台包和风险声明。
共形成 9 条发现：高 1、中 6、低 2。

| 严重级别 | 数量 | 结论 |
| --- | ---: | --- |
| 高 | 1 | Gate D 的 baremetal-C 前置条件可被静默跳过，门禁仍可能返回全绿 |
| 中 | 6 | 证据定稿、时间线、QEMU 组合 hash、CDC 约束、Gate 产物留存、CI 前置失败处理 |
| 低 | 2 | ROR 状态说明陈旧、测试 registry 未覆盖后续 P7/多核入口 |

没有发现材料刻意把 SVE、EL2/EL3、C3/C4、B5 full flow、Gate F-BOARD 或
checkpoint v4 联合恢复伪装成已完成。06 多核和 08 安全边界的主要限制披露与
静态实现一致；安全扫描未发现私钥头、常见 token 形态或大于等于 5 MiB 的 tracked
文件。

## 2. 范围与方法

- 审计对象是项目自定义的 V82 非 SVE 范围和仓库证据链，不是外部标准认证。
- 对实现声明，优先从源码、testbench 和可追溯 Git 对象反向验证，不直接采信自评。
- 对已披露且边界准确的限制不重复登记为 finding；只有声明不一致、门禁可假绿、
  证据不可复核或风险缺少具体控制时才登记。
- 未读取或复制远端凭据、license 内容、私钥或密码；未访问其他任务的构建现场。
- 用户在审计中途将口径调整为静态优先。本报告不以动态回归发现 bug；需要运行的
  项目统一列入第 6 节，由原开发 Agent 执行。

## 3. Findings

### EXT-05-003（高）：Gate D 可在 baremetal-C 未执行时返回全绿

- **状态**：open
- **方向**：05-verification，交叉影响 02-reproducibility
- **静态证据**：`sim/difftest/run_gate_d.sh:125-137` 在
  `scripts/build-baremetal.sh` 失败时只打印“跳过”，不增加 `fails`；随后仍可输出
  `PASS: Gate D`。但 Gate D 结果和路线图把 baremetal-C 200 条列为门禁组成。
- **工具链不一致**：`scripts/toolcheck.sh:54-59` 检查
  `aarch64-none-elf-gcc`，实际构建脚本在 `scripts/build-baremetal.sh:10-28`
  使用 `aarch64-linux-gnu-gcc` 和硬编码的 `aarch64-linux-gnu-objcopy`。因此
  `make toolcheck` 不能证明 Gate D 实际编译器可用，`AARCH64_GCC` override 也没有
  同步覆盖 objcopy。
- **影响**：冻结候选可能在缺少一项声明为必需的编译器驱动测试时仍获得 Gate D
  全绿，属于发布门假绿路径。T-099 evidence 明确记录该次 baremetal-C PASS，本发现
  不否定该次结果；问题在于门禁实现允许未来跳过。
- **建议**：把 baremetal-C 缺失视为 Gate D 失败，或把它拆成显式可配置且结果中
  必须标为 `SKIP/INCOMPLETE` 的非发布模式；统一检查实际 GCC/objcopy 前缀并固定版本。
- **动态验证**：由 Gate/工具链原开发 Agent 在隔离 PATH 下做缺工具负测，确认发布
  模式非零退出；本轮未执行。

### EXT-01-001（中）：done 任务的 evidence 未定稿，T-104 无法由其 head 重建

- **状态**：open
- **方向**：01-governance
- **静态证据**：工作流规定 evidence 在 `review` 可留空 `merge_sha`，任务 `done`
  后由集成者补齐并冻结（`docs/MULTI_AGENT_WORKFLOW.md:412-420`）。但 T-086、T-092、
  T-093、T-096、T-098、T-100、T-103、T-104 等任务已为 done，其 evidence 仍是
  `active/review` 且 `merge_sha` 为空。
- **T-104 特例**：`docs/tasks/evidence/T-20260829-104.json:4-7` 的 head 是
  `5f78319`，该提交不包含 `docs/audit/`；材料实际 head 为 `4214a5e`，集成提交为
  `8e3bfb5`。active JSON 又把无关后续提交 `5b2b0ba` 写为 `merge_sha`，而
  `docs/tasks/TASKS.md` 使用 `8e3bfb5`。artifact hash 仍为
  `see git show after commit` 占位文本。
- **影响**：机器事实源不能唯一回答“哪个提交生成了哪份材料、在哪个合并 SHA
  复验”，外部审计无法只按 evidence 重建 T-104。
- **建议**：由集成者新建证据纠错任务，补一份不可变 correction record，统一
  result head、integration merge、artifact tree/hash；不要改写已冻结 handoff。

### EXT-01-002（中）：任务时间戳存在逆序和晚于承载提交的未来时间

- **状态**：open
- **方向**：01-governance
- **静态证据**：`docs/tasks/active/T-20260829-099.json:53-70` 的 dispatch 是
  14:40，integrator review 却是 14:00；T-099 两次 Gate 运行发生在 13:06-13:46，
  同样早于登记的 dispatch。T-104 active JSON 记录 21:30 创建/派发、22:00 合并，
  但承载这些字段的 Git 提交 `2edc757` 时间为 21:15；T-104 evidence 的
  `reported_at=21:20` 也晚于材料提交 `4214a5e` 的 21:13。
- **影响**：规范要求用这些时间计算派单/报告耗时；当前数据不能用于时延审计，
  也无法可靠还原 Gate 与集成顺序。
- **建议**：定义“事件发生时间”和“台账回填时间”两个字段；增加单调性检查，禁止
  `review < dispatch`、`run < dispatch`，并在提交前拒绝明显晚于当前时间的事件。

### EXT-02-001（中）：审计包声明的 QEMU patch 组合 SHA256 不可复算

- **状态**：open
- **方向**：02-reproducibility
- **静态证据**：`docs/audit/02-reproducibility.md:35-51` 的 12 个单文件 SHA256
  均与仓库一致，但“全部 patch 内容组合 SHA256”声明为 `43095d...c89af`。
  按文件名排序后直接串接 12 个 patch 内容得到
  `33abdb70e02fbfd40b6fa784302c6f5ff25410960c97958cc1804f6070615c94`；仓库没有
  定义能产生 `43095d...` 的命令，该值只在审计文档和 T-104 evidence 中出现。
- **影响**：组合摘要不能用于外部重放包的整体身份校验。单文件摘要正确，故不影响
  当前逐文件核对，也不证明 patch 内容损坏。
- **建议**：规定 canonical 命令（包括排序、文件名边界和内容边界），由脚本生成并
  在 CI/fresh replay 中校验；修订材料时同时保留旧值和 correction 记录。
- **复核命令**：
  `find qemu/patches -maxdepth 1 -type f -name '*.patch' -print0 | sort -z | xargs -0 cat | sha256sum`

### EXT-03-001（中）：异步 FIFO CDC 与公共复位释放没有仓库内完整约束

- **状态**：open
- **方向**：03-rtl-quality，交叉影响 07-fpga
- **静态证据**：`rtl/lcvex_axi4_avalon_adapter.sv:230-258` 实例化两组跨
  `cpu_clk/emif_clk` 的 `lcvex_async_fifo`；Gray 指针同步器在
  `rtl/lcvex_async_fifo.sv:103-122`。但仓库 SDC
  `fpga/catapult_a10/quartus/catapult_a10.sdc:15-24` 只为 calibration 状态同步器
  设置 false path，并声称它们是唯一 crossing，没有 FIFO 指针/数据的 clock-group、
  synchronizer、max-delay/max-skew 或等价约束。
- **复位风险**：adapter 用 `cpu_rst_n & emif_rst_n & !cal_fail` 作为两个域的公共
  异步 FIFO reset（`rtl/lcvex_axi4_avalon_adapter.sv:158-162`），没有看到分别针对
  两个时钟域的同步释放链或 recovery/removal 约束。
- **影响**：模块级 RTL 仿真不能证明 FPGA CDC 收敛；TimeQuest 可能误计时、漏报，
  或在复位释放/Gray 总线偏斜时出现硬件相关失败。该项必须在 Gate F-MEM/F-BOARD
  前闭合。
- **建议**：由原 EMIF/FPGA Agent 提供生成后完整 SDC/Report CDC 证据；为 FIFO
  synchronizer 添加明确约束和属性，为每个域实现 async-assert/sync-deassert reset，
  并补 reset/calibration/in-flight 跨域定向验证。
- **动态验证**：TimeQuest/Report CDC 和板级复位压力测试列为可选移交，本轮未执行。

### EXT-05-001（中）：Gate D 关键产物 URI 不是持久位置且 retention 已到期

- **状态**：open
- **方向**：05-verification
- **静态证据**：工作流要求大产物记录持久 URI、hash、owner、retention；T-099
  evidence 的 Gate 日志、随机 trace、coverage 和协调器 URI 全是 task worktree 内
  `build/...` 相对路径（`docs/tasks/evidence/T-20260829-099.json:96-159`），且
  `retain_until` 均为 `task review complete`。T-099 已经 done，evidence 自己也声明
  完整产物只在 worktree build 目录。
- **影响**：worktree 按规范回收后，外部方只剩 hash，不能取得日志验证 13/13 或
  分析首次 RED；当前保留着旧 worktree 不能替代持久 artifact 契约。
- **建议**：发布/Gate 证据将小日志压缩保存到批准的 artifact root，记录绝对稳定
  URI、有效 retention 和 hash；至少保留最终 summary、环境 manifest 和首错片段。

### EXT-05-002（中）：CI difftest/nightly 的前置失败未纳入失败计数

- **状态**：open
- **方向**：05-verification
- **静态证据**：`scripts/ci-difftest.sh:6-20` 使用 `set -uo pipefail`，但 QEMU
  apply、build、plugin build 在受控 `steps` 之外，退出码未检查；
  `scripts/ci-nightly.sh:6-20,39-56` 对 QEMU/plugin/lockstep build、delay2 build 和
  镜像生成也没有 fail-fast 或累加 `fail`。
- **影响**：在保留旧 binary/image 的非干净工作区中，前置命令失败后脚本仍可能
  使用陈旧产物继续并最终返回成功。GitHub workflow 的独立准备 step 可降低当前
  PR 路径风险，但本地直接入口和未来 workflow 复用仍有假绿可能。
- **建议**：前置步骤统一通过 `run_step` 或显式 `|| exit`；每次运行清理/隔离输出，
  并记录实际 QEMU/plugin/coordinator/image hash。由 CI 原开发 Agent 补负向测试。

### EXT-04-001（低）：审计材料仍把已实现的 logical ROR 写成缺口

- **状态**：open
- **方向**：04-isa-architecture
- **静态证据**：`docs/audit/04-isa-architecture.md:43-45`、自评和
  `docs/V82_PROFILE_MANIFEST.md:57` 把 logical shifted-register ROR 写成 blocked；
  但机器源 `scripts/v82_profile_check.py:225-233` 将 `BASE-DP-018` 标为
  `implemented`，decode、SV TB 和 Cocotb 定向也明确接受 logical ROR。ADD/SUB
  shifted-register 的 `shift_type=3` 才是架构保留编码并正确 UDEF。
- **影响**：对实现能力做了过时的低估，并让 manifest 摘要与其内嵌机器数据冲突。
- **建议**：重新生成/修订 manifest 摘要、04 和 self-assessment，只保留 ADD/SUB
  保留编码说明；不要改变 94/117 统计，除非 profile 脚本重新计算后给出证据。

### EXT-05-004（低）：测试 registry 未覆盖已有 P7、多核和 FPGA/CDC 入口

- **状态**：open
- **方向**：05-verification
- **静态证据**：`docs/TEST_ENHANCEMENT_PLAN.md:114-132` 说明 registry 描述现有
  入口并可用于生成受影响的 L0-L2 套餐；当前 `scripts/test_registry.json` 只有
  22 项，搜索不到 P7/FP/NEON、多核 cluster/C2 或 FPGA/CDC 条目，而 Makefile、
  `tb/sv/` 和 `sim/cocotb/` 已存在这些入口。`--check` 只验证现有 JSON schema，
  不检查与 Makefile/runner 的完整性。
- **影响**：按 registry 规划回归时会漏掉后续新增域；“registry check PASS”不能
  解释为测试入口清单完整。
- **建议**：补齐稳定入口并增加最低限度的反向一致性检查；在完成前把 registry
  明确标为 A0 部分清单，不作为自动影响分析的唯一来源。

## 4. 九方向结论

| 方向 | 静态结论 | 新发现 |
| --- | --- | --- |
| 01-governance | 流程文档完整，但 evidence 定稿和时间线执行不一致 | EXT-01-001/002 |
| 02-reproducibility | 单文件 hash/工具版本/QEMU base 可核；组合 hash 与实际 Gate 工具链检查有缺口 | EXT-02-001、EXT-05-003 交叉项 |
| 03-rtl-quality | 单核提交边界、XZR/SP、32 位零扩展静态结构未见新增回归；已知综合风险准确 | EXT-03-001 |
| 04-isa-architecture | profile 机器数据自洽；SVE/POST-V82 边界清楚；摘要有一处陈旧 | EXT-04-001 |
| 05-verification | PRE/COMMIT/seq 协议结构与文档一致；门禁/CI/产物治理存在假绿或不可复核路径 | EXT-05-001/002/003/004 |
| 06-multicore | C2 双核、C3/C4 未完成、single-outstanding、core_fault/reset 限制披露准确 | 无新增 |
| 07-fpga | B5 OOM、fp_scalar、A64_FP_SIMD、板测未完成披露准确；CDC finding 同时阻塞本方向 | EXT-03-001 交叉项 |
| 08-security-boundary | 未发现 tracked 私钥/token 形态或 >=5 MiB 文件；敏感边界与规则一致 | 无新增 |
| 09-risks | 既有开放风险分类基本准确；需吸收本报告新增 action items | 本报告全部 |

## 5. 已确认但不重复登记的已知限制

- checkpoint v4 已有结构和 smoke，完整 QEMU/DUT 联合恢复未闭环。
- `A64_FP_SIMD=0` 不会真正移除 FP/NEON 实例；fp_scalar 大位宽除法和 L1D/L2WB
  综合热点未解决。
- C3 四核、C4 8/16/32、多核 QEMU 锁步、Linux SMP、running-reset-restart、
  full-core fault 注入和 CORE_COUNT=1 全量回归未完成。
- B5 最新 Quartus full flow、DDR/板测、Gate F-BOARD、可信 CI/main 晋级未完成。
- SVE/SVE2/SME、EL2/EL3 和列入 POST-V82-DEFERRED 的扩展不在当前完成声明中。

## 6. 动态审计可选移交

以下项目没有在本轮完成或据此下结论，应由原开发 Agent 在新任务、独立 worktree、
资源限制和固定 SHA 下执行：

| 可选项 | 建议 owner | 目标 |
| --- | --- | --- |
| DYN-01 当前 HEAD `make test` | 单核验证/集成 Agent | 完整重跑；本轮中途停止的运行不得复用为结果 |
| DYN-02 当前 HEAD Gate D + CORE_COUNT=1 | Gate/C2 原 Agent | 覆盖 T-099 后的 `core_wrap/l2_cluster` 改动，绑定同一 SHA |
| DYN-03 checkpoint v4 联合恢复 | T-097/QEMU checkpoint Agent | QEMU incoming + DUT restore + CONTEXTIDR 对齐 |
| DYN-04 CDC/reset | T-054/T-063/T-067 FPGA/EMIF Agent | Report CDC、TimeQuest、复位释放、calibration/in-flight 压力 |
| DYN-05 Gate/CI 负向门禁 | 验证基础设施 Agent | 缺 GCC、QEMU apply/build 失败、陈旧产物存在时必须非零退出 |
| DYN-06 QEMU fresh replay | QEMU/profile Agent | 定义 canonical combined hash，并在干净 release 重放 12 patches |
| DYN-07 Gate artifact 取回 | Gate runner/集成者 | 从批准 artifact store 取回 T-099 日志并核对 SHA256/retention |
| DYN-08 B5/板级 | FPGA 原 Agent | B5 full flow、CDC/STA、DDR 和板级门；仍受现有资源/授权约束 |

## 7. 本轮命令边界

在用户调整为静态优先之前，曾完成一次受 `MemoryMax=15G`、无 swap、CPUQuota=600%
约束的 `make compile`，结果 PASS；随后启动的 `make test` 在完成 core smoke、开始
backpressure build 时按用户新口径中止，退出 130，**没有总体结果**。此外完成了
工具版本、profile、registry schema、平台 hash/skeleton、任务 JSON 等静态机器检查。
这些执行事实记录在 T-20260829-105 evidence；后续不得把中止日志当回归证据。
