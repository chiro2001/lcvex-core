# 当前任务索引

> 这是任务注册表的持久审计快照，不是实时资源看板。当前为 2026-08-27 的 A0
> 双轨首批派单快照，仅集成者可更新；以后只有手工维护成为瓶颈时才由薄 CLI 生成。
> 历史路线和 handoff 不迁移为活动任务；精确事实以 `active/*.json` 为准。
> 新任务从 `T-YYYYMMDD-NNN` 开始登记，精确事实以 `active/*.json` 为准。
>
> **2026-09-02 增量**：F1a 196 行矩阵全绿（T-20260901-011）；子代理冒烟测试
> T-20260902-003 完成；T-20260902-001（A10 资源探针）与 T-20260902-002
> （JTAG SOP）已重新派发。下方表格为历史快照，完整实时状态以 `active/*.json` 为准。
>
> **2026-09-07 增量**：R21 功能候选 `80b1f813` 已通过 focused 6/6、affected
> L1 8/8 和严格锁步 1155 commits；T-20260906-035 正在执行其50 MHz物理基线。
> 用户决定后续暂停追频并转入25 MHz首板bring-up。T-20260907-036已冻结
> [`BRINGUP_25MHZ_PLAN.md`](../BRINGUP_25MHZ_PLAN.md)，并登记T-037父批次、
> T-038/039/040三条实现lane、T-041只读JTAG预检、T-042物理流、T-043
> assembler权限门和T-044真实JTAG权限门。精确状态以对应`active/*.json`为准。
>
> **2026-09-07 B25实现增量**：R21 physical完成，Fmax 48.57 MHz、50 MHz WNS
> -0.588 ns。T-037 source `259188ac`已合入T-038/039/040及新增T-045 EMIF
> resilience；父线AXI line/EMIF SV、Cocotb 7/7、SoC三场景、MIF/checker/lint全绿。
> T-042 ready，必须fresh携带generated `boot.mif`且禁止assembler。T-043仍缺SOF
> 生成授权；T-044只有指定nios2-terminal console收发授权，没有FPGA配置权限。
>
> **2026-09-10 B25 physical 收口**：T-20260909-013 在 candidate `d2f5cfdd` 上完成
> fresh synthesis/fitter/STA、DDR/metastability、FIFO/data-delay。raw UCP/reset
> `61/626` 与 T-011 的 `63/627` 差异已由 T-20260910-001 v2 完整成员不变量证明为
> fitter-only duplicate 选择，合并 SHA actual T-011/T-013 均 PASS；T-20260910-002
> 完成 evidence provenance 修正。T-013 已 done；用户随后授权且 T-043 只运行一次
> assembler，唯一 SOF `032c82dd...2920b` 已封存。当前停在 T-044 FPGA 易失配置
> 独立权限门；编译加速 T-014 延后。
>
> **2026-09-19 B25 首板结果**：用户授权后，T-20260907-044 两次成功易失配置
> 冻结 B25 SOF，JTAG-UART 均可连接但 monitor 无任何输出或命令响应；完全相同的
> programmer/console 路径换历史 golden 后输出 OpenSBI 与 Linux，故 T-044 以
> `blocked-board-functional` 收口。板卡当前运行 golden；未写 Flash、未 reset/power。
> 下一任务转向综合专用 M20K 同步读响应对齐与 vendor-faithful 回归，旧 SOF 不再重测。
> T-20260919-001 已据此登记，由主 Agent 在独立 worktree 实现；该任务仅到本地
> L0-L2，不运行 Quartus physical、assembler 或任何板级动作。
>
> **2026-09-20 B25 最终收口**：T-20260919-001 的 M20K 修复及厂商时序等价负例、
> T-20260920-023/024 的 logical-immediate 综合修复、T-025 Gate D、T-027 fresh
> physical、T-029 UCP 与 T-030 单次 assembler 已全部通过。T-037 的 sealed candidate
> session 完成 `BOOT/READY/?/PONG/RXDBG/Z` 以及 RXPATH/RXCPU 验收；其单次 golden
> 尝试失败的原始 evidence 保留，T-038 已用独立 golden-only transaction 和最终 chain
> 枚举证明 live exact golden。T-20260907-044 因此由 successor chain 关闭；外部 DDR
> 仍为 `DDR-FAIL`，不把本次 BRAM/JTAG-UART 通过扩张为 DDR/Linux/full-FP 验收。

| ID | 标题 | Assigned owner | 执行模型 | 持久 phase | 依赖 | 验收 | 分支/Worktree |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T-20260826-001 | 分层测试 registry 与查询入口 | root/integrator | 历史集成者 | done | — | L0/L1；不改变默认 runner | `infra/T-20260826-001-test-registry` / archived |
| T-20260826-002 | 压缩 trace/checkpoint manifest 与切片 smoke | luna-implementation-agent / root-integrator | Luna[max]（实现中断后由集成者接管） | done | — | L0–L2；trace manifest + 切片边界 | `infra/T-20260826-002-trace-checkpoint` / archived |
| T-20260826-003 | P6 LSE128 LDCLRP/LDSETP/SWPP 与差分回归 | luna-implementation-agent / root-integrator | Luna[max]（实现中断后由集成者接管） | done | — | L0–L2；LSE128 三族与既有回归 | `infra/T-20260826-003-lse128` / archived |
| T-20260826-004 | P6 Linux lite/main checkpoint 续跑与 Gate E 证据窗口 | luna-monitor-agent / root-integrator | Luna[max]（短窗后由集成者诊断旧 main 链） | done | T-003 | lite 500k + main bootstrap 10k+500k；旧 main 链阻断已取证 | `verify/T-20260826-004-linux-resume` / archived |
| T-20260826-005 | 续跑 checkpoint parent/global provenance 与自动 manifest | luna-implementation-agent / root-integrator | Luna[max]（实现中断后由集成者接管） | done | T-004 | L0–L2；自动发布/失败不发布/全局映射 | `infra/T-20260826-005-resume-provenance` / archived |
| T-20260826-006 | P6 strict root Linux lite/main 链与 Gate E 候选窗口 | luna-monitor-agent / root-integrator | Luna[max]（物理核绑定/长跑监控） | done | T-005 | lite/main strict root 各约 11.51M；Gate E 待冻结候选 | `verify/T-20260826-006-strict-linux-root` / archived |
| T-20260826-007 | P6 strict Linux 深段续跑与 Gate E 首个失败点 | luna-monitor-agent / root-integrator | Luna[max]（物理核绑定/失败点监控） | done | T-006 | lite/main 各 5M strict child；global 16,509,999 | `verify/T-20260826-007-linux-deep` / archived |
| T-20260826-008 | Gate E 冻结候选、验收口径与 P7 入口规划 | root-integrator | Sol[high]（方向性评审） | done | T-007 | Gate E 判据/P7 入口已冻结为规划；不宣称 Gate E 通过 | `verify/T-20260826-008-gate-e-review` / archived |
| T-20260826-009 | Gate D candidate 本地全量回归 | luna-monitor-agent | Luna[max]（detached gate/资源监控） | cancelled | T-008 | 首个 lint 阻断已取证，未运行 Gate D | `verify/T-20260826-009-gate-d-candidate` / archived |
| T-20260826-010 | 修复 ADC/SBC carry 临时量宽度 lint 阻断 | root-integrator | 当前会话 | done | — | L0–L1；不改功能语义 | `fix/T-20260826-010-carry-width` / archived |
| T-20260826-011 | Gate D candidate 全量回归（lint 修复后） | luna-monitor-agent | Luna[max]（detached gate/资源监控） | cancelled | T-010 | 第二个 PINMISSING 阻断已取证 | `verify/T-20260826-011-gate-d-rerun` / archived |
| T-20260826-012 | 补齐 core SV testbench checkpoint restore pins | root-integrator | 当前会话 | done | — | L0–L1；不改功能语义 | `fix/T-20260826-012-core-tb-pins` / archived |
| T-20260826-013 | Gate D candidate 全量回归（TB pin 修复后） | luna-monitor-agent | Luna[max]（detached gate/资源监控） | cancelled | T-012 | 第二个 backpressure PINMISSING 已取证；candidate 已过期 | `verify/T-20260826-013-gate-d-rerun` / archived |
| T-20260826-014 | 补齐 backpressure SV testbench restore pins | root-integrator | 当前会话 | done | — | L0–L1；不改功能语义 | `fix/T-20260826-014-backpressure-pins` / archived |
| T-20260826-015 | Gate D candidate 全量回归（T-014 集成后） | luna-monitor-agent | Luna[max]（detached gate/资源监控） | cancelled | T-014 | `sim-sv-crc` 的 `cin` PINMISSING 已取证；candidate 已过期 | `verify/T-20260826-015-gate-d-rerun` / archived |
| T-20260826-016 | 补齐 CRC SV testbench ALU cin 连接 | luna-implementation-agent | Luna[max]（独立实现/快速验证） | done | T-015 | L0；不改变 CRC 语义 | `fix/T-20260826-016-crc-cin-pin` / archived |
| T-20260826-017 | 实现 EL0 Generic Timer 的 CNTKCTL 访问门控 | root-integrator（接管） | Luna[max] 中断后由当前会话完成 | done | T-016 | L0–L2；EC=0x18 trap 与 QEMU 对齐 | `feature/T-20260826-017-el0-timer-gate` / archived |
| T-20260826-018 | ARMv8.2 维护指令编码与 QEMU 支持矩阵审计 | sol-review-agent | Sol[high]（只读方向评审） | done | T-017 | 只读 probe；冻结后续实现清单 | `review/T-20260826-018-maint-inventory` / archived |
| T-20260826-019 | ARMv8.2 DC CVAP / AT 扩展与维护 tuple 收紧 | root-integrator | 当前会话（Sol[high] 范围评审） | done | T-018/T-017 | L0–L2；CVAP、AT/PAN/PAR 与既有维护回归 | `feature/T-20260826-019-maint-v82` / archived |
| T-20260826-020 | strict Linux lite/main 深段并行续跑 | root-integrator | 当前会话监控 | done | T-017 | lite/main 各 5M strict child；global 21,509,999 | `verify/T-20260826-020-linux-parallel` / archived |
| T-20260826-021 | 恢复 hard_dit 定向回归生成器 | root-integrator | 当前会话 | done | T-019 | L0–L2；Gate D 前置脚本可生成并通过 hard_dit | `infra/T-20260826-021-hard-dit` / archived |
| T-20260826-022 | Gate D candidate 全量回归（T-019/T-021 集成后） | root-integrator | 当前会话 Gate 监控 | cancelled | T-019/T-021 | infra failure：fresh build/difftest + parallel=0 除零 | `verify/T-20260826-022-gate-d-candidate` / archived |
| T-20260826-023 | Gate D 并行 runner 资源排队与 fresh worktree 目录修复 | root-integrator | 当前会话 | done | T-022 | L0–L1；资源零槽位与 fresh 目录 smoke | `infra/T-20260826-023-runner-resource` / archived |
| T-20260826-024 | Gate D candidate 全量回归（T-023 runner 修复后） | root-integrator | 当前会话 Gate 监控 | done | T-019/T-021/T-023 | L0–L3；M2/delay2/hardening/random 全绿 | `verify/T-20260826-024-gate-d-candidate` / archived |
| T-20260826-025 | Gate D 后 Linux lite/main strict continuation | root-integrator | 当前会话（Luna[max] 只读监控） | cancelled | T-024 | provenance failure：plugin 与 parent 不一致 | `verify/T-20260826-025-linux-gate-e` / archived |
| T-20260826-026 | Linux continuation 拆分 QEMU/Verilator 物理核并支持 75% 资源上限 | root-integrator | 当前会话 | done | T-025 | L0；独立 pin 与兼容路径 | `infra/T-20260826-026-pin-split` / archived |
| T-20260826-027 | Linux lite/main strict continuation（parent plugin + split pin） | root-integrator | 当前会话（Luna[max] 只读监控） | done | T-024/T-026 | L4；同 SHA 两线各 5M、child finalized | `verify/T-20260826-027-linux-split-pin` / archived |
| T-20260826-029 | CI difftest zlib 依赖与 nightly 手动触发修复 | root-integrator | 当前会话 | done | T-027 | L0；workflow/zlib/patch replay 本地完成，远端 CI 后置 | `infra/T-20260826-029-ci-zlib` / archived |
| T-20260826-030 | 最新 candidate SHA 的 Gate E Linux continuation | root-integrator | 当前会话（Luna[max] 只读监控） | done | T-024/T-027/T-029 | L4；同 SHA lite/main 各 5M + /init marker | `verify/T-20260826-030-linux-latest-candidate` / archived |
| T-20260826-031 | Gate E 同候选 fresh-root lite /init 稳定窗口 | root-integrator | 当前会话 | cancelled | T-030 | L4；被 T-034/T-044 的 35M fresh-root `/init` 证据取代 | `verify/T-20260826-031-fresh-root` / archived |
| T-20260826-032 | step 锁步 runner 的 plugin 与双物理核参数化 | root-integrator | 当前会话 | done | — | L0；显式 plugin/pin smoke | `infra/T-20260826-032-step-runner-pins` / archived |
| T-20260826-033 | P6 ALLINT PSTATE 与 Linux checkpoint 差分缺口 | root-integrator | 当前会话 | done | T-031 | L0–L2/L4；ALLINT 定向、恢复和失败点续跑 | `feature/T-20260826-033-allint` / archived |
| T-20260826-034 | T-033 集成 SHA 的 Linux lite fresh-root Gate E 窗口 | root-integrator | 当前会话 | done | T-033 | L4；当前 SHA fresh-root 35M、/init、稳定窗口 | `verify/T-20260826-034-linux-fresh-root` / archived |
| T-20260826-035 | 修复 P1 QEMU trace 超时终止导致 trace 缺失 | root-integrator | 当前会话 | done | — | L0/L3；优雅终止并可读 trace | `infra/T-20260826-035-trace-timeout` / archived |
| T-20260826-036 | ALLINT 集成 SHA 本地 Gate D 全量回归 | root-integrator | 当前会话 | cancelled | T-033/T-034 | infra-fail；runner 孤儿进程，未形成 Gate D 结论 | `verify/T-20260826-036-gate-d-current` / archived |
| T-20260826-037 | 修复 step runner run_pinned 的真实 PID 回收 | root-integrator | 当前会话 | done | — | L0；无孤儿 QEMU/协调器 | `infra/T-20260826-037-runner-pid` / archived |
| T-20260826-038 | T-037 runner 修复后的当前 SHA Gate D 全量回归 | root-integrator | 当前会话 | done | T-033/T-034/T-037 | L2/L3；当前 SHA Gate D 全量且无孤儿进程 | `verify/T-20260826-038-gate-d-runner-fixed` / archived |
| T-20260826-039 | Gate E main Linux early-boot 并行 continuation | root-integrator | 当前会话 | done | T-033/T-034 | L4；main 5M continuation/early boot | `verify/T-20260826-039-linux-main` / archived |
| T-20260826-040 | 冻结候选 `a2dd216` Gate D 全量并行重跑 | root-integrator | 当前会话 | done | T-033/T-037 | L2/L3；同一候选全量 Gate D、覆盖率、无孤儿进程 | `verify/T-20260826-040-gate-d-current` / archived |
| T-20260826-041 | 冻结候选 `a2dd216` Gate E lite/main 并行取证 | root-integrator | 当前会话 | cancelled | T-033/T-039 | L4；lite 35M 通过，main 首错转 T-042/T-044 新候选闭环 | `verify/T-20260826-041-gate-e-current` / archived |
| T-20260826-042 | 修复 SCTLR_EL1 PAuth 使能位写掩码 | root-integrator | 当前会话 | done | T-041 | L1/L2/L4；定向 base/cache + main 2.5M 首错重放 | `feature/T-20260826-042-sctlr-pauth-mask` / archived |
| T-20260826-043 | 冻结候选 `b2568a5` Gate D 全量重跑 | gate-d-t043-luna | Luna[max] | done | T-042/T-037 | L3；同一候选 Gate D 全绿、50/50 并行结果、无孤儿进程 | `verify/T-20260826-043-gate-d-sctlr` / archived |
| T-20260826-044 | 冻结候选 `b2568a5` Gate E lite/main 取证 | gate-e-t044-luna | Luna[max] | done | T-042/T-039 | L4；lite fresh-root 35M `/init` + main 5M finalized | `verify/T-20260826-044-gate-e-sctlr` / archived |
| T-20260826-045 | checkpoint finalize 原子性与假 finalized 回归 | checkpoint-finalize-t045-luna | Luna[max] | done | T-044 | L0/L2；失败保持 pending、成功原子发布、联合 smoke 全绿 | `infra/T-20260826-045-checkpoint-finalize-atomic` / archived |
| T-20260826-046 | P6/Gate E 本地验收阶段审计与 P7 进入评审 | root-integrator + Sol | Sol[high] 只读复核 | done | T-043/T-044 | review；P6 本地完成、正式晋级边界与 P7 前置包 | `review/T-20260826-046-p6-stage` / archived |
| T-20260826-047 | SCTLR PAuth 脏 sidecar 联合恢复回归 | sctlr-dirty-t047-terra | Terra[xhigh] | done | T-042/T-045 | L2；脏 bit31/30/27/13 注入后 MRS 与 QEMU 一致 | `verify/T-20260826-047-sctlr-dirty-sidecar` / archived |
| T-20260826-048 | 标量 ISA/阶段文档与 coverage 口径收敛 | isa-baseline-t048-luna | Luna[max] | done | T-043/T-046 | L0；消除旧状态矛盾，coverage 区分 expected/observed | `docs/T-20260826-048-isa-baseline` / archived |
| T-20260826-049 | P7 FP/NEON 架构状态与差分协议冻结 | p7-protocol-t049-terra | Terra[xhigh] + Sol[high] | done | T-045/T-047/T-048 | design/L0；协议通过用户人工审核 | `docs/T-20260826-049-p7-protocol` / archived |
| T-20260827-050 | P7 与 Catapult A10 上板使能并行路线冻结 | root-integrator | 当前会话 | done | T-049 | design/L0；AXI4、单核一致性、双轨DAG与阶段门 | `docs/T-20260827-050-p7-fpga-plan` / archived |
| T-20260827-051 | P7-0 FP/NEON 架构状态、访问陷阱与 checkpoint 垂直实现 | p7-0-luna / root-integrator | Luna[max]（派单省略 model） | done | T-049/T-050 | merge SHA `d453e29`；V/FPEN/trap、QEMU 0012、filelist/core/SoC wiring、FPCR/FPSR raw lockstep、13 列 LCVXFP01 root/resume、max/legacy guard 和负路径均通过；P7-1 arithmetic/memory、Gate D/F 后置 | `feature/p7-fp-neon` / `docs/tasks/archive/T-20260827-051.json` |
| T-20260827-052 | Catapult A10 B0-Platform 平台输入收编与可重生成检查 | b0-platform-luna | Luna[max]（派单省略 model） | done | T-050 | 离线包/checker 已通过；T-063 已创建远程工程并打通 Qsys/IP regenerate；T-062 补顶层骨架并归档（merge `e5313e7`）；SFL 输入与真实 full flow/STA 后置 | `feature/T-20260827-052-b0-platform` / archived |
| T-20260827-053 | B1-AXI4 标准接口、BFM 与协议断言 | b1-axi4-luna | Luna[max]（派单省略 model） | done | T-050 | clean FPGA 线 L0/L1 通过，merge evidence=6200343；B2/L2 后置 | `feature/fpga-catapult-a10` / integration worktree |
| T-20260827-054 | B2-EMIF AXI4 到 512-bit Avalon-MM 适配与 CDC | b2-emif-luna | Luna[max]（派单省略 model） | done | T-050/T-053 | clean FPGA 线 L0/L1 通过，merge evidence=94725bf；B3 后置 | `feature/fpga-catapult-a10` / integration worktree |
| T-20260827-055 | B3-L2-WB 包容式写回缓存与单客户端 probe | b3-l2-wb-luna | Luna[max]（派单省略 model） | done | T-050/T-054 | clean FPGA 线 L0/L1 通过，merge evidence=cfa8b9a；B4/L1 后置 | `feature/fpga-catapult-a10` / integration worktree |
| T-20260827-056 | B4-L1-Coherence 单核 D-L1 写回与维护闭环 | b4-l1-coherence-luna | Luna[max]（派单省略 model） | done | T-050/T-055 | clean FPGA 线 merge evidence=52144b4；模块级 L0/L1 通过，系统接线/Gate F-MEM 后置 | `feature/fpga-catapult-a10` / integration worktree |
| T-20260827-057 | Catapult Windows Quartus 21.4 CLI 环境调研与综合路径验证 | catapult-windows-survey-luna | Luna[max]（派单省略 model） | done | T-050（支援 T-052） | 环境调研已归档；`D:\Projects\fpga-altra\lcvex` 缺失阻塞已由 T-063 创建工程并打通 smoke full flow 解除；SFL 输入与真实 wrapper full flow 后置 | `verify/T-20260827-057-catapult-windows` / archived |
| T-20260827-058 | P7-1 选定 FP32/FP64 标量算术与基础访存垂直实现 | p7-1-scalar-fp-luna / Euclid / root-integrator | Luna[max]（派单省略 model） | done | T-051/T-050 | owner 修复后、合并 SHA `f937352` 的 compile/SV/Cocotb/backpressure、A76 required 28/38/18/388 和 P6 scalar 40 全通过；FMA/转换/NEON/SVE/Cache/AXI/Gate F 后置 | `feature/p7-fp-neon` / `docs/tasks/archive/T-20260827-058.json` |
| T-20260827-059 | P7-2 选定 NEON 128 位整数与单 Q 访存垂直实现 | p7-2-neon-int-luna / Hooke → Archimedes | Luna[max]（派单省略 model） | done | T-058/T-050 | 合并 SHA `072cf12`；compile、SV、Cocotb 普通/延迟 8/8、NEON 31、fetch-fault 20、P7-1 28/38/18/388、P6 40 全通过；fault-BFM 为 assertion-enabled expected-reject；Q store 受限于完整 preflight 后下游不再 fault | `feature/p7-fp-neon` / `docs/tasks/archive/T-20260827-059.json` |
| T-20260827-060 | P7-3 选定 NEON 浮点 2S/4S/2D 垂直实现 | p7-3-neon-fp-luna / Lagrange → Copernicus | Luna[max]（派单省略 model） | done | T-059/T-050 | 合并 SHA `9c6adee`；完整 12 组合 A76 48/48、P7-3 SV/Cocotb 4/4 普通与 delay2、P7-2 8/8/31/31/20/20、P7-1 28/38/18/388、P6 40/40；15/15 evidence provenance 审计通过；FMA/FP16/转换/未列族后置 | `feature/p7-fp-neon` / `docs/tasks/archive/T-20260827-060.json` |
| T-20260827-061 | P7 Gate-F 前置：冻结候选完整 Gate D 与 P6 兼容审计 | root-integrator / Luna 只读审计 | Luna[max]（派单省略 model；Gate D 集成者串行） | done | T-051/T-058/T-059/T-060 | 冻结 SHA `d3dfe7a`；完整 Gate D 全绿：M2/R1 40、delay2 32、hardening 26、Gate C 7、P5a 3、P4b 5、随机 3×100k、coverage 60/60、baremetal-C 200；Gate-F-BOARD/CI/Linux 缺口单独记录 | `detached-gate-T-20260827-061` / `docs/tasks/evidence/T-20260827-061.json` |
| T-20260827-062 | B0 从零创建 Catapult A10 可重生成工程骨架 | b0-bootstrap-luna | Luna[max]（派单省略 model） | done | T-050/T-053/T-054/T-055/T-056 | merge SHA `e5313e7`；顶层 shell/reset gate、QSF/SDC 顶层锚点、skeleton_manifest、check_skeleton/lint_platform 全绿（离线 L0/L1）；Quartus 21.4 regenerate/full flow/STA 与 SFL 输入后置 | `feature/T-20260827-062-b0-bootstrap` / archived |
| T-20260828-063 | Catapult Windows 命令行创建 Quartus 工程与 Qsys/IP 再生成 | catapult-project-create-dsv | deepseek-v4-flash[max]（派单省略 model） | done | T-050（输入 T-052/T-057） | merge SHA `d0f6e82`；远程 `D:\Projects\fpga-altra\lcvex` 已创建且 15/15 payload hash 一致；Qsys/IP regenerate 与 smoke full compile 全通过（SOF 36.8MB）；SFL 输入与主工程顶层后置 | `feature/T-20260828-063-catapult-project-create` / archived |
| T-20260828-064 | Catapult A10 真实顶层 full flow/STA 与 SFL 输入补齐 | catapult-fullflow-dsv | deepseek-v4-flash[max]（派单省略 model） | done | T-062/T-063 | merge SHA `e389c53`；远端真实 `quartus_sh --flow compile catapult_a10` exit 0，0 errors/68 warnings，STA 最差 setup +0.220ns、hold +0.017ns；SFL/EPCQ 39 文件补齐并锁定来源；离线 L0 50 files 全绿 | `feature/T-20260828-064-catapult-fullflow` / archived |
| T-20260828-066 | P7-4 FMA 与 FP/整数转换垂直实现 | p7-4-fma-convert-dsv | deepseek-v4-flash[max]（派单省略 model） | done | T-060 | merge SHA `4b253ad`；标量 S/D FMA 四族、SCVTF/UCVTF/FCVTZS/FCVTZU、FCVT S↔D、NEON 2S/4S/2D FMLA/FMLS/转换；SV/Cocotb 5/5、A76 lockstep 94/54/27/142、P6 scalar 40、checkpoint 5/40 全绿 | `feature/T-20260828-066-p7-4-fma-convert` / archived |
| T-20260828-065 | B5-SoC/Boot：Catapult A10 可综合 SoC 顶层、BRAM 启动与板级门前置 | b5-soc-boot-dsv | deepseek-v4-flash[max]（派单省略 model） | blocked | T-064/T-056/T-062 | 本地 L0/L1 全绿并合入 FPGA 线（merge `23218fb`）：SoC 顶层/BRAM boot/JTAG-UART/地址映射；远端 full flow 因宿主残留 Quartus 进程（~44GB）内存耗尽卡在 synthesis，待清理/重启后重跑 b5l | `feature/T-20260828-065-b5-soc-boot` / FPGA 线 |
| T-20260828-068 | P7-4 冻结候选完整 Gate D（Gate-F ISA candidate） | root-integrator | 集成者串行 | done | T-066 | 冻结 SHA `c007164` 完整 Gate D 全绿：26 并行锁步、Gate C 7、P5a 3、P4b 5、随机 3×100k、coverage 60/60、baremetal-C 200；作为 Gate-F ISA candidate 证据 | `detached-gate-T-20260828-068` / archived |
| T-20260828-067 | Catapult A10 B5 SoC 远端 full flow/STA 重跑（b5l） | catapult-fullflow-rerun-dsv | deepseek-v4-flash[max]（派单省略 model） | blocked | T-065 | FP if/else 优化后重跑仍 OOM：Synthesis ~38min 后 serv_req 77060MB，无 fit/STA/SOF；需 >80GB 或缩减/拆分综合范围 | `verify/T-20260828-067-b5-fullflow-rerun` / worktree 2de73e4 |
| T-20260828-069 | P7-5 FP16 半精度、sqrt、min/max 与 round 垂直实现 | p7-5-fp16-sqrt-minmax-dsv | deepseek-v4-flash[max]（派单省略 model） | done | T-066 | merge SHA `e36b7b1`；修复 H->S FCVT NaN off-by-one；标量 H/S/D FP16、FSQRT、FMIN/FMAX/FMINNM/FMAXNM、FRINT*、FCVT H↔S/H↔D；NEON 4H/8H 与 2S/4S/2D selected；SV(26 raw)/Cocotb 7/7、A76 lockstep 102/59/40/66、P7-1/2/3/4+P6 scalar 40+DIFF_CKPT 全绿 | `feature/T-20260828-069-p7-5-fp16-sqrt-minmax` / archived |
| T-20260828-070 | dsh 工作流试点：同步任务模板到当前模型路由 | root-integrator | dsh 默认通道（deepseek，省略 model） | done | — | merge SHA 实现 `e40f119`/定稿 `eb9d507`；TEMPLATE.json 两处 model_selection 对齐 deepseek 默认、删除 disabled_profiles；owner L0 4 项 + 集成者复跑 2 项全绿；验证 dsh subagent 闭环（登记/worktree/派单/报告/合并/定稿）与 compress 主动压缩可行性 | `infra/T-20260828-070-dsh-pilot-template-routing` / archived |
| T-20260828-071 | 开源综合/面积/关键路径代理线（A 线，A0–A4） | root-integrator（父任务） | 待子任务派单 | done | ADR-005 | 按 v2 计划产出开源综合代理报告；非 A10 signoff、不替代 Quartus、不解除 T-067 | `feature/T-20260828-071-open-synth-proxy` / proposed |
| T-20260828-072 | V82 非 SVE profile 指令补完线（B 线，B0–B5） | root-integrator（父任务） | 待子任务派单 | done | ADR-005 | B0–B5 实现线全部合入（含 B5 freeze/T-097）；Gate D/F 整体门禁仍由集成者后置 | `feature/T-20260828-072-v82-profile` / done |
| T-20260828-073 | 多核演进线（C 线，C0–C6/D0） | root-integrator（父任务） | 待子任务派单 | active | ADR-005 | 2核功能、4核正确性、8/16/32核规模报告；单核全回归不变 | `feature/T-20260828-073-multicore` / proposed |
| T-20260829-074 | A0：开源综合工具链能力矩阵 | opensynth-dsv | dsh 默认通道 | done | T-071 | 工具版本/能力矩阵/失败原因；A0 出口 | `feature/T-20260829-074-a0-toolchain-capability` / proposed |
| T-20260829-075 | B0：V82 非 SVE profile 审计清单 | core-isa-dsv | dsh 默认通道 | done | T-072 | 可机器校验 profile manifest；SVE/POST-V82 后置 | `feature/T-20260829-075-b0-profile-audit` / proposed |
| T-20260829-076 | C0：多核 cluster/一致性契约 | mem-subsys-dsv | dsh 默认通道 | done | T-073 | 端口/状态/reset/backpressure 草案；CORE_COUNT=1 兼容 | `feature/T-20260829-076-c0-cluster-contract` / proposed |
| T-20260829-077 | D0：多核差分 MC-v2 可行性 | difftest-infra-dsv | dsh 默认通道 | done | T-073 | 两核最小序列可重放或 reference fallback；v1 兼容 | `feature/T-20260829-077-d0-mc-diff-feasibility` / proposed |

| T-20260829-078 | B1：标量/解码闭合（ROR 与低风险 V82-BASE 缺口） | core-isa-dsv | dsh 默认通道 | done | T-072 | BASE-DP-018 实现与 L0/L1 证据；不触碰共享热点 | `feature/T-20260829-078-b1-scalar-closure` / active |
| T-20260829-079 | C1：双核壳层（参数化复制/独立启动/reset/IRQ/WFI） | mem-subsys-dsv | dsh 默认通道 | done | T-073/C0/D0 | 双核 shell elaboration + per-core commit；CORE_COUNT=1 不回归；不做 coherence | `feature/T-20260829-079-c1-dualcore-shell` / active |
| T-20260829-080 | A1：核心/内存开源综合代理（Yosys/ABC） | opensynth-dsv | dsh 默认通道 | done | T-071/A0 | 分层 generic synth 统计或明确 N/A；非 A10 signoff | `feature/T-20260829-080-a1-generic-synth` / active |
| T-20260829-081 | A2：SoC stub/tie-off 与顶层开源 elaboration | opensynth-dsv | dsh 默认通道 | done | T-071/A1 | 顶层可 elaboration；外部 IP 全列；非 A10 signoff | `feature/T-20260829-081-a2-soc-stub` / active |
| T-20260829-083 | A3：开源代理与 A10 基线相关性报告 | opensynth-dsv | dsh 默认通道 | done | A1/A2 | 趋势/占比/限制报告；禁止线性换算 A10 | `feature/T-20260829-083-a3-correlation-report` / active |
| T-20260829-082 | B2a：FP/ASIMD 算术闭合 | core-isa-dsv | dsh 默认通道 | done | T-072/B1 | P7 之上补已声明 FP/NEON 算术；L0/L1；非 SVE | `feature/T-20260829-082-b2a-fp-arithmetic` / active |
| T-20260829-084 | B2b：FP/向量转换、舍入、异常与 FPCR 闭合 | core-isa-dsv | dsh 默认通道 | done | B2a | 四种 rounding/NaN/异常/FPCR；L0/L1；非 SVE | `feature/T-20260829-084-b2b-fp-convert-round` / active |
| T-20260829-086 | C2：双核共享 L2 目录式 MSI 一致性 | mem-subsys-dsv | dsh 默认通道 | done | C1/B1 | C2 双核 MSI 一致性与 T-092 定向全部合入；原子正/负、maintenance/barrier、reset/fault、dualcore、L1+MSI 全 PASS；CORE_COUNT=1 全量回归/running-reset-restart 为后续 | `feature/T-20260829-086-c2-dualcore-msi` / merged |
| T-20260829-085 | B2c：向量访存/编码族闭合 | core-isa-dsv | dsh 默认通道 | done | B2b | lane/replicate/结构访存/fault；与 C 热点按窗口协调（DUP/LD1R 已合入） | `feature/T-20260829-085-b2c-vector-memory` / active |
| T-20260829-087 | A4：开源综合趋势回归（轻量阈值/差分报告） | opensynth-dsv | dsh 默认通道 | done | A1/A2/A3 | 可复现趋势/阈值；非 A10 signoff；不替代 Quartus | `feature/T-20260829-087-a4-trend-regression` / active |
| T-20260829-088 | B3：系统寄存器/维护/原子闭合（V82 已批准范围） | core-isa-dsv | dsh 默认通道 | done | B1/B2 | 三个切片+T-093/T-096/T-097 已合入；V82 系统/维护/原子闭合；POST-V82 项后置 | `feature/T-20260829-088-b3-system-maint-atomic` / merged |
| T-20260829-089 | C3 四核系统前置：GIC/PSCI/Timer/IPI/SMP 契约与任务拆解 | mem-subsys-dsv | dsh 默认通道 | done | C0/D0 | 四核前置契约/拆分；C2 未关闭前不实现 4 核功能 RTL | `feature/T-20260829-089-c3-fourcore-prework` / active |
| T-20260829-090 | Verilator 卡顿诊断：定位双核/SoC elaboration 极慢的模块与构造 | toolchain-dsv | dsh 默认通道 | done | C2 现象/B2c 现象 | 分层复现、最小化定位、可操作建议；不修改共享热点 | `feature/T-20260829-090-verilator-stuck-diagnose` / active |
| T-20260829-091 | FP scalar Verilator elaboration 优化：降低 256-bit 组合展开/拆流水线 | core-isa-dsv | dsh 默认通道 | done | T-090 | 默认优化可快速 lint；raw-bit FP 不回归；不引入 SVE（已合入） | `feature/T-20260829-091-fp-scalar-verilator-opt` / active |
| T-20260829-092 | C2 双核 MSI 剩余：原子/屏障/维护/reset-fault 定向闭合 | mem-subsys-dsv | dsh 默认通道 | done | T-073/C2 | merge `c18ba3c`；atomic fail/ok、maint/barrier、reset/fault、dualcore、L1+MSI 全 PASS；CORE_COUNT=1 全量回归/running-reset-restart 后续 | `feature/T-20260829-092-c2-remainder2` / merged |
| T-20260829-093 | B3 剩余：V82 已批准范围系统/维护/原子闭合余量 | core-isa-dsv | dsh 默认通道 | done | T-088 | merge SHA `8b4348d`；新增 OSLSR_EL1（只读复位10），扩展 LSE/CAS/exclusive/barrier 标量矩阵；make compile 与 4 个 SV TB 全绿；CONTEXTIDR/全量 probe 留待后续 | `feature/T-20260829-093-b3-remainder` / merged |
| T-20260829-096 | B3 后续：CONTEXTIDR_EL1 与系统寄存器全量 reset/权限矩阵 probe | core-isa-dsv | dsh 默认通道 | done | T-093 | merge SHA `fb687e0`；CONTEXTIDR_EL1 EL1 RW/reset0 实现与 access TB 全绿；checkpoint sidecar v4 全量恢复留为独立全局任务 | `feature/T-20260829-096-b3-contextidr-probe` / merged |
| T-20260829-097 | B3 全局串行：CONTEXTIDR_EL1 checkpoint sidecar v4 与恢复 | core-isa-dsv | dsh 默认通道 | done | T-096 | merge SHA `fba5144040e5d13686cf6375ccbe62edc4b43078`；sidecar v4/checkpoint.py/lockstep/QEMU plugin 序列化+恢复；v4 smoke+manifest/resume smoke 全绿；完整 joint restore 后置 | `feature/T-20260829-097-checkpoint-sidecar-v4` / merged |
| T-20260829-094 | B4：编译器和覆盖闭合（baremetal-C / 反汇编 / 随机交叉覆盖） | core-isa-dsv | dsh 默认通道 | done | B3/B2c | merge SHA `8949234f764bfbd9d6e89cd1cb80b3b4710690f8`；随机覆盖 62/62、裸机 C O0/O2/Os 无未知 alias、negative 集引用 B3；RTL Gate D/全量 profile 绑定留后续 | `feature/T-20260829-094-b4-coverage-closure` / merged |
| T-20260829-098 | B5：V82 non-SVE profile freeze 与候选冻结 | core-isa-dsv | dsh 默认通道 | done | B4/B3 | merge SHA `3681e6e821c60250d810b648f7c65cbe1c17d5b2`；117 行 manifest、row->evidence matrix、QEMU/plugin hash 锁定；Gate D/full make test/T-097 仍后置 | `feature/T-20260829-098-b5-profile-freeze` / merged |
| T-20260829-099 | F 单核候选 Gate D 全量复跑（B 线/checkpoint v4 后） | root-integrator | dsh 默认通道 | done | B5/T-097 | PASS 13/13 @ `3dcffe0`（本地）；Makefile/planner 修复后全绿；不替代 CI/Gate E/Quartus | `verify/T-20260829-099-gate-d` / done |
| T-20260829-095 | C3：四核功能实现（GIC/PSCI/Timer/IPI/SMP 启动与调度） | mem-subsys-dsv | dsh 默认通道 | done | C2 | WIP 分支 `ea98a88`：sysctrl/cluster4/C2 回归 PASS，timer FAIL，full fourcore 未 PASS；暂不合并 | `feature/T-20260829-095-c3-fourcore-implementation` / review |
| T-20260829-100 | C4 前置：8/16/32 核规模参数化/测量契约与风险拆解 | mem-subsys-dsv | dsh 默认通道 | done | C3-pre/C2 | merge `9377501`；C4_SCALE_PREWORK.md：CORE_COUNT 参数化、8/16/32 验收口径、资源/延迟模板、R-C4/R-C5；仅文档 | `feature/T-20260829-100-c4-scale-prework` / merged |
| T-20260829-101 | T-067 综合优化/standalone Quartus synthesis 调研与 OOM 定位 | fpga-synth-opt-dsv | dsh 默认通道 | done | T-067 | OOM 热点在 B5 SoC 内部 RTL 非 EMIF；A64_FP_SIMD=0 未真正 gate FP/NEON；decode_only 33s/682MB PASS；core lpm_divide>64 独立问题；未重跑 full flow | `feature/T-20260829-101-t067-synth-opt` / merged |
| T-20260829-102 | T-067 第二阶段：逐模块 standalone synthesis、fp_scalar 可综合性修复与 FP/NEON 真 gate | fpga-synth-opt-dsv | dsh 默认通道 | done | T-101 | partial：L2 WB 强热点（>37min/qdb~190MB）、L1D 182k LC；fp_scalar 朴素 256-bit restoring 不可行；余量后续另立任务 | `feature/T-20260829-102-t067-module-synth` / merged |
| T-20260829-103 | C4 双核 baseline 测量（C4-pre 补充：CORE_COUNT=2 规模基线） | mem-subsys-dsv | dsh 默认通道 | done | C4-pre/C2 | merge `cd43247`；DUALCORE 371s/3.36GB、L1MSI 24s/434MB、smoke PASS；仅 baseline，非 4/8/16/32 功能验收 | `feature/T-20260829-103-c4-dualcore-baseline` / merged |
| T-20260829-104 | 外部审计材料准备与结果接收（实现流程/RTL 质量/方法学等 9 方向） | external-audit-prep-dsv | dsh 默认通道 | done | — | merge `8e3bfb5`；9 方向材料包、evidence-index、self-assessment、external-results/action-items 已合入 | `feature/T-20260829-104-external-audit` / merged |
| T-20260829-105 | 外部静态审计执行与结果接收 | primary-external-auditor | 当前会话 | done | T-104 | merge `72e026d`；9 方向静态审计，1 高/6 中/2 低；动态 DYN-01..08 移交原领域 Agent | `verify/T-20260829-105-external-audit-run` / merged |
| T-20260829-106 | AUD-01：修复 Gate D baremetal-C 假绿与工具链检查 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 发布模式 baremetal-C 缺失必须失败；统一 aarch64-linux-gnu-gcc/objcopy 检查；补缺工具负测。 | `feature/T-20260829-106` / active |
| T-20260829-107 | AUD-02：当前 HEAD make test 完整回归 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 独立 worktree、cgroup <16GiB、固定 SHA 下完整 make test；记录结果/RSS；不用中止日志作证据。 | `feature/T-20260829-107` / active |
| T-20260829-108 | AUD-03：当前 HEAD Gate D + CORE_COUNT=1 复跑 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 依赖 AUD-01/02；绑定点 SHA，覆盖 T-099 后 core_wrap/l2_cluster 改动。 | `feature/T-20260829-108` / proposed |
| T-20260829-109 | AUD-04：异步 FIFO CDC 与双域复位约束 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 补 SDC/Report CDC/复位释放/calibration/in-flight 证据；阻塞 Gate F-MEM/F-BOARD。 | `feature/T-20260829-109` / active |
| T-20260829-110 | AUD-05：Gate D 产物持久化与取回 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 迁移 T-099 关键日志/manifest 到持久 artifact root，记录 SHA/retention。 | `feature/T-20260829-110` / active |
| T-20260829-111 | AUD-06：QEMU patch 组合哈希 canonical | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 定义排序/边界/串接命令并生成或修正 combined hash；CI/fresh replay 校验。 | `feature/T-20260829-111` / active |
| T-20260829-112 | AUD-07：CI difftest/nightly 前置失败 fail-fast | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 前置 QEMU/build/plugin/image 步骤显式检查或 run_step；隔离陈旧产物；补负向验证。 | `feature/T-20260829-112` / active |
| T-20260829-113 | AUD-08：evidence 定稿与 T-104 correction | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 统一 result head/merge SHA/artifact hash；新建 correction record；不改写已冻结 han | `feature/T-20260829-113` / active |
| T-20260829-114 | AUD-09：任务时间戳单调性/事件时间字段 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 定义事件时间与回填时间；增加 review>=dispatch、run>=dispatch 校验。 | `feature/T-20260829-114` / active |
| T-20260829-115 | AUD-10：补 test registry 入口与反向检查 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 补 P7/FP/NEON/多核/FPGA/CDC 条目；check 与 Makefile/runner 一致性；明确部分清单。 | `feature/T-20260829-115` / active |
| T-20260829-116 | AUD-11：ROR 文档纠错 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 修正 audit 04/self-assessment/manifest 中 logical ROR 为已实现；保留 ADD/SUB 保留编 | `feature/T-20260829-116` / active |
| T-20260829-117 | AUD-12：checkpoint v4 联合恢复 | audit-action-dsv | dsh 默认通道 | done | 外部审计 | QEMU incoming + DUT restore + CONTEXTIDR 对齐；依赖审计后处理。 | `feature/T-20260829-117` / proposed |
| T-20260829-118 | AUD-13：QEMU fresh replay（12 patches） | audit-action-dsv | dsh 默认通道 | done | 外部审计 | 依赖 AUD-06；干净环境重放全部 patches 并校验 canonical hash。 | `feature/T-20260829-118` / proposed |
| T-20260829-119 | AUD-14：B5 full flow / DDR / 板级 | audit-action-dsv | dsh 默认通道 | proposed | 外部审计 | 仍受 Quartus OOM/宿主资源约束；依赖 AUD-04 等。 | `feature/T-20260829-119` / proposed |
| T-20260830-001 | FPGA-A：T-067 剩余模块 standalone Quartus 综合补齐 | fpga-line-dsv | dsh 默认通道 | done | T-067 | 继续 T-102 未测模块：l2_probe/alu/regfile/muldiv/fp_scalar/neon_fp/ | `feature/T-20260830-001` / active |
| T-20260830-002 | FPGA-B：L2 writeback 降规模/多周期/partition 优化 | fpga-line-dsv | dsh 默认通道 | done | T-067 | 降低 L2 writeback 综合热点：参数探索、多周期化、partition 或结构拆分；保持功能/验证。 | `feature/T-20260830-002` / active |
| T-20260830-003 | FPGA-C：fp_scalar 多周期/分块除法实现 | fpga-line-dsv | dsh 默认通道 | done | T-067 | 将 >64 位 FP 除法改为多周期/分块/查表可综合方案，避免 lpm_divide>64 和 256-bit 组合爆 | `feature/T-20260830-003` / active |
| T-20260830-004 | FPGA-D：FP/NEON 真 generate-gate 实验 | fpga-line-dsv | dsh 默认通道 | done | T-067 | 在实验副本中真正移除/门控 FP/NEON 实例并测量面积/时间；不改主 RTL 功能，提供方案。 | `feature/T-20260830-004` / proposed |
| T-20260830-005 | FPGA-E：Quartus partition/incremental 评估 | fpga-line-dsv | dsh 默认通道 | done | T-067 | 评估 partition/incremental compile 将 core/L1D/L2 拆分；远程实验，不启动完整 | `feature/T-20260830-005` / proposed |
| T-20260830-006 | FPGA-F：缩减设计 B5 synthesis/fit/STA 重跑 | fpga-line-dsv | dsh 默认通道 | blocked | T-067 | 依赖 B/C/D/E；在缩减设计稳定通过 Synthesis 后重跑 B5 full flow，解除 T-067。 | `feature/T-20260830-006` / proposed |
| T-20260830-008 | FPGA-F2：L1D/L2/soc_coh 深拆分与 block-based bottom-up 验证 | fpga-line-dsv | dsh 默认通道 | done | T-067/T-006 | 承接 FPGA-F blocked；隔离副本中深拆分 L1D/L2/soc_coh 并验证 bottom-up 跳顶层重综合 | `feature/T-20260830-008-fpga-f2` / active |
| T-20260830-007 | 关闭 GitHub Actions 自动 CI 并同步仓库 | infra-github-dsv | dsh 默认通道 | done | — | 禁用 push/PR/schedule 自动触发，仅保留 workflow_dispatch；本地测试/合入足够可靠 | `.github/workflows/ci.yml` / done |
| T-20260830-009 | 性能验证工作负载线：规划与集成 | perf-line-dsv | dsh 默认通道 | active | — | P-line：性能 microbench/workload、测量报告基础设施；不替代 Fmax/架构签核 | `feature/T-20260830-009` / active |
| T-20260830-010 | P-INFRA：性能测量/构建/报告基础设施 | perf-line-dsv | dsh 默认通道 | active | T-009 | perf 单独编译、JSON cycle/参数/SHA 报告；扩展 microbench runner | `feature/T-20260830-010` / active |
| T-20260830-011 | P-ALU：整数/控制流性能 workload | perf-line-dsv | dsh 默认通道 | done | T-009 | 依赖链延迟、ILP、branch/bitfield/muldiv 吞吐 | `feature/T-20260830-011` / active |
| T-20260830-012 | P-MEM：访存层次/带宽/延迟 workload | perf-line-dsv | dsh 默认通道 | done | T-009 | L1/L2/DRAM 延迟、顺序/随机、copy/read/write 带宽 | `feature/T-20260830-012` / active |
| T-20260830-013 | P-FP：FP/NEON 标量与向量吞吐/延迟 | perf-line-dsv | dsh 默认通道 | done | T-009 | add/mul/fma/fdiv/scalar/vector/FP16 等吞吐延迟 | `feature/T-20260830-013` / active |
| T-20260830-014 | P-MC：双核/多核消息/竞争/伸缩 workload | perf-line-dsv | dsh 默认通道 | done | T-009 | C2 可测；C3 稳定后扩展；cacheline contention/ping-pong | `feature/T-20260830-014` / active |
| T-20260830-015 | P-MIXED：混合真实 kernel | perf-line-dsv | dsh 默认通道 | done | T-009 | CRC/矩阵乘/排序/哈希等端到端 IPC 代理 | `feature/T-20260830-015` / active |
| T-20260830-016 | FPGA-F3：B5 bottom-up fit/STA/SOF 组装尝试 | fpga-line-dsv | dsh 默认通道 | blocked | T-008/T-067 | 使用 black-box stub + QDB import + fitter/STA/assembler 跳过顶层重综合，尝试产出 B5 fit/STA/SOF | `feature/T-20260830-016-fpga-f3` / active |
| T-20260830-017 | P-FIX：性能 workload 运行时标定与超时修复 | perf-line-dsv | dsh 默认通道 | done | T-010 | 修复 alu/mem/fp/kernel/mixed 在 perf_runner 下超时；标定迭代/最大 cycles | `feature/T-20260830-017-perf-fix` / active |
| T-20260830-018 | C4 8核规模测量：参数化 elaboration/有限 smoke/趋势 | mem-subsys-dsv | dsh 默认通道 | done | C4-pre | CORE_COUNT=8；不宣称完整功能/架构合规/Linux SMP | `feature/T-20260830-018-c4-8-scale` / active |
| T-20260830-019 | C4 16/32核规模趋势测量（synthetic/no-FP优先） | mem-subsys-dsv | dsh 默认通道 | done | C4-pre/C4-8 | 16/32 lint/elab/有限 smoke 趋势；不宣称完整功能/架构合规 | `feature/T-20260830-019-c4-16-32-scale` / active |
| T-20260830-020 | FPGA-F4：绕过 Qsys/IP 与顶层 glue 的 B5 bottom-up 替代路径 | fpga-line-dsv | dsh 默认通道 | blocked | T-016/T-067 | 复用原 IP DB、整 SoC 黑盒、独立 IP generate，争取进入 fitter/STA/assembler | `feature/T-20260830-020-fpga-f4` / active |
| T-20260830-021 | P-SNAPSHOT：性能线全量快照（14 workload 实测+JSON 归档） | perf-line-dsv | dsh 默认通道 | done | T-010/T-017 | 重建 runner、跑全部 perf workload、输出汇总 JSON | `feature/T-20260830-021-perf-snapshot` / active |
| T-20260830-022 | FINAL-GATED：当前主线 make test + Gate D + CORE_COUNT=1 综合回归 | root-integrator | dsh 默认通道 | done | — | C3/C4/性能线合入后完整本地回归；记录 SHA/资源 | `feature/T-20260830-022-final-gated` / active |
| T-20260830-023 | AUD-13FIX：QEMU patch 集对账/重生成与 fresh replay 修复 | audit-action-dsv | dsh 默认通道 | done | AUD-13 | 修正 0012/补录 LCVXSYS4+contextidr+timer kick；干净 apply/build/smoke 通过 | `feature/T-20260830-023-aud-13-fix` / active |
| T-20260830-024 | STATUS-SYNC：项目状态/路线图/候选总结同步 | root-integrator | dsh 默认通道 | done | — | 更新 PROJECT_STATUS/ROADMAP/audit，汇总本地回归与外部阻塞 | `feature/T-20260830-024-status-sync` / active |
| T-20260830-025 | EXT-01-FIX：evidence 定稿与时间戳单调性闭合 | audit-action-dsv | dsh 默认通道 | done | EXT-01-001/002 | correction records、head/merge/artifact hash、时间戳脚本/逆序修正 | `feature/T-20260830-025-ext-01-fix` / active |
| T-20260830-026 | EXT-03-FIX：异步 FIFO CDC/公共复位约束闭合 | audit-action-dsv | dsh 默认通道 | done | EXT-03-001 | 审计/SDC/设计说明与静态验证方案；不启动 Quartus | `feature/T-20260830-026-ext-03-fix` / active |
| T-20260830-027 | HIST-EVID-FIX：历史 evidence 批量定稿与时间戳残留清理 | audit-action-dsv | dsh 默认通道 | done | EXT-01 | 收敛 live 时间戳/历史 evidence 残留；保留旧值 | `feature/T-20260830-027-hist-evid-fix` / active |
| T-20260830-028 | FPGA-G1：真正全 stub SoC 顶层外壳 synthesis 实验 | fpga-line-dsv | dsh 默认通道 | done | FPGA-F4 | 被 FPGA-G2 取代：G2 证明 31.3GB 主因是行为级 BRAM 而非顶层 glue；SoC-only 黑盒换 altsyncram 后 8s/0.63GB | `feature/T-20260830-028-fpga-g1` / superseded |
| T-20260830-029 | FPGA-G2：BRAM M20K/MLAB 显式映射与容量矩阵 | fpga-line-dsv | dsh 默认通道 | done | FPGA-F4 | merge `0a5cf8d`；显式 altsyncram 16KB-1MB 3-4s/0.66GB PASS，SoC-only 黑盒 8s/0.63GB PASS；L1D/L2 ramstyle 不生成 M20K | `feature/T-20260830-029-fpga-g2` / merged |
| T-20260830-030 | FPGA-G3：A10 Qsys/debug fabric 关闭与原工程路径副本 | fpga-line-dsv | dsh 默认通道 | done | G2 | merge `b908fee`；A10 黑盒+altsyncram 到 SOF 全通过；原路径副本无效；alt_sld_fab 非 blocker | `feature/T-20260830-030-fpga-g3` / merged |
| T-20260830-031 | FPGA-G2-INT：将显式 altsyncram/M20K BRAM wrapper 正式纳入主 RTL | fpga-line-dsv | dsh 默认通道 | done | T-029/T-030 | merge `726f7ca`；SYNTHESIS 走 altera_syncram M20K，Verilator 走行为级；make compile/BRAM TB/SoC lint/smoke 全绿 | `feature/T-20260830-031-fpga-g2-int` / merged |
| T-20260830-032 | FPGA-G4：真实 SoC RTL A10 顶层 synthesis/fit 实验（含显式 M20K BRAM） | fpga-line-dsv | dsh 默认通道 | done | T-031 | synthesis PASS 46m/13.5GB；fitter 未收敛，L1D/L2 cache 仍 LUT 化，需显式 RAM wrapper | `feature/T-20260830-032-fpga-g4` / done |
| T-20260830-033 | 性能增强线：先审计规划，再按规划实施 | root-integrator（父任务） | 待子任务派单 | active | — | core/cache/总线性能审计与优化实施；以 P-line 为 baseline | `T-20260830-033-pe` / proposed |
| T-20260830-034 | PE-A：core/cache/总线外部性能静态审计与优化规划 | perf-arch-dsv | dsh 默认通道 | active | T-033 | 更深流水/顺序多发射/outstanding 访存/cache 多 bank/总线加宽等候选、优先级、风险、验证策略 | `feature/T-20260830-034-pe-audit-plan` / active |
| T-20260830-035 | PE-EXT：独立外部性能审计与最终综合路线图 | perf-ext-audit-dsv | dsh 默认通道 | done | T-033 | 外审完成；产出 FINAL_PLAN/ROADMAP；含 F0-F10 DAG | `feature/T-20260830-035-pe-ext-audit` / merged |
| T-20260830-036 | RTL-COMPAT-AUDIT：未提交 Quartus 兼容 RTL 改动审计与处理 | fpga-line-dsv | dsh 默认通道 | done | T-067 | merge `8cbe41d`；decode/alu/fp/neon/pkg/core/l2 Quartus 21.4 兼容；make compile+FP/decode/ALU/L2/Core TB PASS | `feature/T-20260830-036-rtl-compat-audit` / merged |
| T-20260830-037 | PE-F0：性能计数与缓存配置矩阵基线 | perf-line-dsv | dsh 默认通道 | done | T-033 | merge `ed72c10`；9配置×14 workload=126行；缓存主要降事务不降周期；建议F3优先 | `feature/T-20260830-037-pe-f0-baseline` / merged |
| T-20260907-043 | B25 易失 SOF 生成与封存 | root-integrator | 主会话 | done | T-20260909-013 + 用户明确授权 | Quartus assembler Successful、0 errors/0 warnings；唯一 SOF 36,842,093 bytes / `032c82dd...2920b`，源与 fitted payload 不变，无持久格式/JTAG | `verify/T-20260907-043-b25-sof-package` / integrated |
| T-20260907-044 | B25 易失配置与 polling serial 首板交互 | root-integrator | 主会话 | done | T-041/T-043 + 用户明确授权 | 原始失败证据保留；M20K/logic-imm 修复后 T-037 通过 BOOT/READY/?/PONG/RXDBG/Z 与 RXPATH/RXCPU，T-038 恢复并证明 live golden；DDR/Linux 后置 | `batch/T-20260907-037-b25-bringup` / resolved by T-038 |
| T-20260909-008 | B25 FIFO payload SDC 精确闭包 | b25_fifo_payload_sdc | 默认通道（省略 model） | done | T-20260909-005/T-011 | section 3b 补齐 txn_local/read_len/read_beat；六 family checker 6/6，fitted payload 路径消失，剩余 hold +0.018 ns | `fix/T-20260909-008-b25-fifo-payload-sdc` / integrated |
| T-20260909-009 | B25 CDC data-delay SDC 闭包 | b25_cdc_data_delay_sdc | 默认通道（省略 model） | done | T-20260909-006/T-011 | 五条 max-delay 改为独立 set_data_delay；四 corner 共 20 组 0 violation，最差 +0.927 ns | `fix/T-20260909-009-b25-cdc-data-delay-sdc` / integrated |
| T-20260909-010 | B25 UCP/reset exact waiver checker | b25_ucp_waiver_checker + integrator | 默认通道（省略 model） | done | T-20260909-007/T-011 | 冻结 SHA、空 exception、duplicate-key fail-closed；18/18 fault，实际 T-011 inventory PASS | `infra/T-20260909-010-b25-physical-ucp-waiver-checker` / integrated+corrected |
| T-20260909-011 | B25 SDC signoff batch | root-integrator | 当前会话 | done | T-008/T-009/T-010/T-012 | 本地 union 与独立 fitted clone overlay 全绿；源 manifest 0 漂移；下一步最终 fresh synthesis/fitter/STA | `batch/T-20260907-037-b25-bringup` / integrated |
| T-20260909-012 | B25 physical waiver inventory exporter | b25_physical_inventory_exporter | 默认通道（省略 model） | done | T-007/T-011 | 从 raw TimeQuest 报告推导 exact inventory；13/13 fault，T-007/T-011 实际报告均通过 exporter+checker | `infra/T-20260909-012-b25-physical-inventory-exporter` / integrated |
| T-20260909-013 | B25 最终 fresh physical | b25_final_fresh_physical + root-integrator | 默认通道（省略 model）/主会话 | done | T-011/T-20260910-001/T-20260910-002 | fresh synthesis/fitter/STA、DDR/metastability、FIFO/data-delay 与 UCP v2 invariant 全绿；25 MHz setup/hold +8.085/+0.019 ns | `verify/T-20260909-013-b25-final-fresh-physical` / integrated |
| T-20260910-001 | B25 UCP normalized invariant waiver v2 | root-integrator（subagent额度中断后接管） | 主会话 | done | T-010/T-012/T-013 raw evidence | 保留 v1；完整规范化成员 60/624；actual T-011/T-013 PASS，fixture 2/2 + 27/27 | `infra/T-20260910-001-b25-ucp-invariant-v2` / integrated |
| T-20260910-002 | T-013 evidence/provenance 修正 | root-integrator（subagent额度中断后接管） | 主会话 | done | T-013 | 区分 candidate/evidence/integration；25 个 artifact 0 mismatch；不改测量结论 | `verify/T-20260910-002-t013-evidence-correction` / integrated |
| T-20260919-001 | B25 M20K 同步读响应对齐 | root-integrator | 主会话 | done | T-20260907-044 | 旧 RTL 稳定复现首读/换地址/debug stale；修复后 focused、BRAM oracle、三场景 SoC、compile/lint 全绿，合入 `bd59d4fc` | `fix/T-20260919-001-b25-m20k-read-alignment` / integrated |
| T-20260919-002 | M20K 修复合并候选完整 Gate D | root-integrator | 主会话 | done | T-20260919-001 | 完整 Gate D PASS：M2 80、delay2 33、hardening 26、random 3×100002、coverage 62/62、baremetal 200；无跳过/残留 | `verify/T-20260919-002-b25-m20k-gate-d` / evidence `8066f0c4` |
| T-20260919-003 | B25 no-FP 标量快速 bring-up profile | root-integrator | 主会话 | done | T-20260919-001 | 仅板顶 A64_FP_SIMD 默认 1→0；no-FP CAL-OK/WAIT/FAIL、READY/PONG/echo 全绿；明确非 full-FP release | `fpga/T-20260919-003-b25-nofp-bringup-profile` / evidence `072cd4e8` |
| T-20260919-004 | corrected no-FP profile fresh physical | root-integrator | 主会话 | done | T-20260919-001；T-003/T-005 | synthesis/fitter/STA/custom 全绿；74,652 ALM、21 DSP，sys 25MHz setup/hold +7.336/+0.019ns，FIFO 24/24、data-delay 20/20、UCP v2 PASS | `verify/T-20260919-004-b25-nofp-fresh-physical` / evidence `5f366b27` |
| T-20260919-005 | fresh no-FP UCP/reset invariant profile | root-integrator | 主会话 | done | T-001 + T-004 raw TimeQuest bundle | 仅新增 T-004 content-addressed profile；normalized UCP/reset 60/624，T-011/T-013 replay 与 27/27 fault matrix 全绿 | `infra/T-20260919-005-b25-nofp-ucp-invariant-profile` / implementation `4ef63a70` |
| T-20260919-006 | accepted no-FP fitted DB volatile SOF package | root-integrator | 主会话 | done | T-002/T-004/T-005 | Assembler 45s PASS；唯一 SOF 36,842,110 bytes / `04218557...0abb7`；physical DB payload 0 变化，无持久格式 | `verify/T-20260919-006-b25-nofp-volatile-sof` / evidence `0b6f6ec9` |
| T-20260919-007 | corrected no-FP volatile board interaction | root-integrator | 主会话 | blocked | T-006 + 既有用户授权 | 配置与 BOOT/READY PASS；参考文件输入仍无 status/PONG/echo；golden 输出正控 PASS、当前输入正控未到 shell；最终板上 golden | `verify/T-20260919-007-b25-nofp-board-interaction` / evidence `f2308192` |
| T-20260920-001 | B25 JTAG-UART RX 厂商时序等价复现与修复 | root-integrator | 主会话 | done | T-006；由 T-007 触发 | focused Icarus/Verilator 与 65,536 空轮询 full-SoC 全绿；未复现 production 缺陷，RTL 零改动；修正一拍 TX 观测器假失败 | `fix/T-20260920-001-b25-jtag-rx-vendor-timing` / evidence `d63ec88e` |
| T-20260920-002 | corrected B25 首会话普通文件输入正控 | root-integrator | 主会话 | blocked | T-006；由 T-007 方法歧义触发 | 配置/首会话/BOOT/READY PASS，历史文件 stdin 仍无 status/PONG/Z；golden 回滚 PASS，方法歧义已排除 | `verify/T-20260920-002-b25-first-session-file-input` / evidence `5f598d9a` |
| T-20260920-003 | 当前 golden VexRiscv 直连 JTAG-UART 交互正控 | root-integrator | 主会话 | blocked | T-002；用户确认当前 Flash golden | 直连与 Linux 输出 PASS；当前实例停在 PLIC 后且无 prompt/echo；历史同命令双向 transcript PASS；只读重扫可恢复 UART 节点 | `verify/T-20260920-003-golden-vexriscv-live-uart` / evidence `d76e3a28` |
| T-20260920-004 | corrected B25 标准 server 延迟重枚举正控 | root-integrator | 主会话 | blocked | T-001/T-003 | candidate 配置与两次延迟重扫 PASS，唯一 terminal 仍无 status/PONG/Z；golden 回滚与清理 PASS，排除节点 stale | `verify/T-20260920-004-b25-standard-server-rescan-control` / evidence `894f67ab` |
| T-20260920-005 | B25 RX 物理自报告可观测性 | root-integrator | 主会话 | done | T-001/T-004 | DATA read/RVALID/last-byte + RXDBG 已实现；focused、262144 空轮询 vendor/behavioral full-SoC、BRAM oracle 13/13 全绿 | `fix/T-20260920-005-b25-rx-physical-observability` / evidence `44fa5c12` |
| T-20260920-006 | B25 RX 可观测性合并候选完整 Gate D | root-integrator | 主会话 | done | T-005 | 完整 Gate D 全绿：coverage 8760、40+40、delay2 32、hardening 26、random 3×100002、62/62、baremetal 200 | `verify/T-20260920-006-b25-rx-observability-gate-d` / evidence `0b4b4705` |
| T-20260920-007 | B25 RX 可观测性 fresh no-FP physical | root-integrator | 主会话 | done | T-006/T-008/T-009 | 74,583 ALM；25MHz setup/hold +9.147/+0.018ns；DDR/metastability、FIFO 24/24、data-delay 20/20、UCP 60/624 全绿 | `verify/T-20260920-007-b25-rx-observability-fresh-physical` / evidence `25f9825b` |
| T-20260920-008 | RX 可观测性 no-FP 组合 profile | root-integrator | 主会话 | done | T-003/T-005/T-006 | 精确 `85992f53` 上仅 board-top A64_FP_SIMD 1→0；新 profile `05ea2488`；affected lint/focused + T-005 exact-input SoC 组合证据全绿 | `fpga/T-20260920-008-b25-rx-observability-nofp-profile` / evidence `8e1a4d62` |
| T-20260920-009 | RX physical UCP/reset invariant profile | root-integrator | 主会话 | done | T-007 raw TimeQuest | 仅追加 T-007 profile/digest；normalized UCP/reset 60/624、family 606/4/13/1；三组 replay 与 27/27 fault 全绿 | `infra/T-20260920-009-b25-rx-observability-ucp-invariant-profile` / evidence `2e9a5b2b` |
| T-20260920-010 | RX accepted fitted DB volatile SOF | root-integrator | 主会话 | done | T-006/T-007/T-009 | Assembler 47s PASS；唯一 SOF 36,842,100 bytes / `7e9c6064...a2f2` / checksum `0x316ED173`；0 持久格式 | `verify/T-20260920-010-b25-rx-observability-volatile-sof` / evidence `9547bd95` |
| T-20260920-011 | RX SOF volatile board interaction | root-integrator | 主会话 | blocked | T-010 + 既有用户授权 | 配置与 BOOT/READY PASS，bridge RX 计数增加但 CPU 未消费；golden 回滚 PASS，转 CPU-visible observability | `verify/T-20260920-011-b25-rx-observability-board-interaction` / evidence |
| T-20260920-012 | RX bridge→core→firmware→TX 联合可观测性 batch | root-integrator | 主会话 | done | T-001/T-005 | 合入 T-013/T-014；vendor full-SoC 与 hardware/firmware observability 联合验收通过 | `batch/T-20260907-037-b25-bringup` / evidence |
| T-20260920-013 | RX hardware response trace | rx_rtl_trace | 默认通道（省略 model） | done | T-001/T-005 | 非侵入 bridge/PoC/dmem response trace 与 vendor-timed focused 覆盖；重型联合复跑由 T-012 完成 | `verify/T-20260920-013-b25-rx-hardware-response-trace` / integrated |
| T-20260920-014 | RX firmware command trace | monitor_disasm | 默认通道（省略 model） | done | T-001/T-005 | getc/dispatch/putc 有界可观测性及镜像合同通过；重型联合复跑由 T-012 完成 | `verify/T-20260920-014-b25-rx-firmware-command-trace` / integrated |
| T-20260920-015 | CPU-visible RX candidate Gate D | rx_verify_plan | 默认通道（省略 model） | done | T-012 | release-mode Gate D 完整通过，冻结候选可派生 no-FP profile | `detached@17d8d6f2` / evidence |
| T-20260920-016 | CPU-visible RX no-FP profile | monitor_disasm | 默认通道（省略 model） | done | T-012/T-015/T-20260919-003 | 仅 board-top A64_FP_SIMD 1→0；受影响 L0-L2 通过 | `fpga/T-20260920-016-b25-rx-cpu-observability-nofp-profile` / integrated |
| T-20260920-017 | CPU-visible RX fresh physical | monitor_disasm | 默认通道（省略 model） | done | T-015/T-016 | fresh synthesis/fitter/STA/custom 与 physical invariants 通过 | `verify/T-20260920-017-b25-rx-cpu-observability-fresh-physical` / evidence |
| T-20260920-019 | CPU-visible RX UCP/reset profile | rx_verify_plan | 默认通道（省略 model） | done | T-017 | T-017 normalized UCP/reset 绑定、exporter/checker 与 fixtures 全绿 | `infra/T-20260920-019-b25-rx-cpu-observability-ucp-profile` / integrated |
| T-20260920-020 | CPU-visible RX volatile SOF | monitor_disasm | 默认通道（省略 model） | done | T-017/T-019 | 从 accepted fitted DB 单次 assembler；源与 physical DB 不变 | `verify/T-20260920-020-b25-rx-cpu-observability-volatile-sof` / evidence |
| T-20260920-021 | CPU-visible RX board interaction | board_t021 | 默认通道（省略 model） | blocked | T-020 + 用户授权 | 配置、BOOT/READY、RXPATH 部分通过，但 CPU-visible load/dispatch 错值；golden 回滚 PASS，触发 logic-imm 综合修复 | `verify/T-20260920-021-b25-rx-cpu-observability-board-interaction` / evidence |
| T-20260920-022 | logical-immediate 综合修复 batch | root-integrator | 主会话 | done | T-021 | 旧负例复现、RTL 修复、warning 消失、16,384 编码穷举和受影响 L0-L2 全绿 | `batch/T-20260907-037-b25-bringup` / integrated |
| T-20260920-023 | logical-immediate Quartus 回归 | logicimm_test | 默认通道（省略 model） | done | T-021 | 两个 uart_getc 失败 immediate 的综合可见负例与 exhaustive reference regression 完成 | `verify/T-20260920-023-b25-logic-imm-quartus-regression` / integrated |
| T-20260920-024 | Quartus-safe logical-immediate RTL | logicimm_rtl | 默认通道（省略 model） | done | T-021 | decoder 改为 Quartus-safe pure expression；exhaustive 与本地 L0-L1 通过 | `fix/T-20260920-024-b25-logic-imm-quartus-safe-rtl` / integrated |
| T-20260920-025 | logical-immediate repair Gate D | gate_t025 | 默认通道（省略 model） | done | T-022 | release-mode Gate D 全绿：random 3×100002、coverage 62/62、baremetal 200，无 skip/断言关闭 | `detached@c31b3aea` / evidence |
| T-20260920-026 | logical-immediate repair no-FP profile | profile_t026 | 默认通道（省略 model） | done | T-025 | 单行 no-FP derivative 与受影响 L0-L2 通过 | `fpga/T-20260920-026-b25-logic-imm-repair-nofp-profile` / integrated |
| T-20260920-027 | logical-immediate repair fresh physical | physical_t027 | 默认通道（省略 model） | done | T-025/T-026 | synthesis/fitter/STA 0 errors；25 MHz setup/hold +7.481/+0.017 ns，FIFO/data-delay/UCP 全绿 | `verify/T-20260920-027-b25-logic-imm-repair-fresh-physical` / evidence |
| T-20260920-028 | Quartus SLD warning 16788 provenance | sldwarn_t028 | 默认通道（省略 model） | done | T-027 | 证明为固定 vendor SLD padding；tracked RTL 0，规范化 topology hash 封存 | `verify/T-20260920-028-b25-sld-warning-provenance` / integrated |
| T-20260920-029 | logical-immediate repair UCP/reset profile | ucp_t029 | 默认通道（省略 model） | done | T-027 | production normalized UCP/reset 60/624、family 606/4/13/1、2/2 正例与 27/27 负例通过 | `infra/T-20260920-029-b25-logic-imm-repair-ucp-profile` / integrated |
| T-20260920-030 | logical-immediate repair volatile SOF | asm_t030 | 默认通道（省略 model） | done | T-026/T-027/T-028/T-029 | 单次 assembler PASS；SOF 36,842,105 bytes / `bb292699...fd264` / `0x315AC2B3`，0 持久格式 | `verify/T-20260920-030-b25-logic-imm-repair-volatile-sof` / evidence |
| T-20260920-031 | 首次 final board closeout | board_t031 | 默认通道（省略 model） | blocked | T-027/T-028/T-029/T-030 | candidate/golden 编程均成功，但过强 design-hash gate 跳过 terminal；转 live-identity 合同审计 | `verify/T-20260920-031-b25-logic-imm-repair-board-closeout` / evidence |
| T-20260920-032 | candidate live-identity contract | identity_t032 | 默认通道（省略 model） | done | T-031 | 采纳 fail-closed composite identity，禁止把 cached standard-server design hash 当先验门 | `verify/T-20260920-032-b25-candidate-live-identity-contract` / integrated |
| T-20260920-033 | composite-identity board closeout | board_t033 | 默认通道（省略 model） | blocked | T-030/T-032 | inline PowerShell parser transport 在 preflight 前失败；硬件调用 0 | `verify/T-20260920-033-b25-composite-identity-board-closeout` / evidence |
| T-20260920-034 | board runner transport seal | runner_t034 | 默认通道（省略 model） | blocked | T-032 | 旧 bootstrap 参数集在远端 root 创建前失败；硬件调用 0 | `infra/T-20260920-034-b25-board-runner-transport-seal` / evidence |
| T-20260920-035 | board runner remote seal | runner_t035 | 默认通道（省略 model） | blocked | T-032 | PowerShell Generic.List binder 在 AST 验证阶段失败；硬件调用 0 | `infra/T-20260920-035-b25-board-runner-remote-seal` / evidence |
| T-20260920-036 | board runner AST-compatible seal | runner_t036 | 默认通道（省略 model） | done | T-032 | 修正 parser/binder；远端 AST 6/6、seal 9/9、静态审计全绿，未触发硬件 | `infra/T-20260920-036-b25-board-runner-ast-compat-seal` / integrated |
| T-20260920-037 | sealed final board closeout | board_t037 | 默认通道（省略 model） | done | T-030/T-032/T-036 | candidate BOOT/READY/?/PONG/RXDBG/Z、RXPATH/RXCPU 全 PASS；本轮 golden 单次失败保持原证据，由 T-038 解决 | `verify/T-20260920-037-b25-sealed-runner-final-board-closeout` / resolved |
| T-20260920-038 | golden-only volatile recovery | golden_t038 | 默认通道（省略 model） | done | T-030/T-036 | 唯一 golden programmer transaction 与最终 chain enumeration PASS；live exact golden 已证明，禁止重跑 | `verify/T-20260920-038-b25-golden-only-volatile-recovery` / integrated |
| T-20260920-039 | B25 post-bring-up microbench/CoreMark 集成批次 | root-integrator | 主会话 | done | T-038 | required DAG 全绿：tracked runner、m 控制、BRAM correctness、官方 CoreMark 真板有效分数、Gate D、fresh physical、volatile SOF、final exact golden；T-046/T-048 blocked 尝试由后继修复/收口，原证据保留 | `batch/T-20260920-039-b25-post-bringup` / integrated at `4ba3ad28` |
| T-20260920-040 | tracked/parameterized board runner 与 SOP | root-integrator | 主会话 | done | T-036/T-038 | tracked contract/seal runner；本地 19/19、registry 89、最终远端 AST 7/7 + seal 12/12，无硬件调用 | `infra/T-20260920-040-b25-board-runner-repro` / integrated |
| T-20260920-041 | late-calibration DDR m-command 正控 | root-integrator | 主会话 | done | T-030/T-038/T-040 | candidate 与 `?→CAL-OK; m→DDR-OK; ?→DDR-OK` PASS；原轮 golden 失败由 T-047 解决 | `verify/T-20260920-041-b25-ddr-m-control` / resolved |
| T-20260920-042 | BRAM CPU correctness microbench + CoreMark | root-integrator | 主会话 | done | T-038 | t=24 项/`8679CF21`，v=官方 CRC/1,479,468 cycles/INVALID；20,448-byte clean-build，D-L1 同拍丢请求修复，behavioral+vendor L0-L2 全绿 | `feature/T-20260920-042-b25-bram-coremark` / integrated |
| T-20260920-043 | microbench/CoreMark candidate Gate D | root-integrator | 主会话 | done | T-042 | detached `f6633e70` Gate D：151 green/0 red、coverage 8760、random 3×100002、ISA 62/62、baremetal 200；affected L0-L2 同 SHA PASS | detached `f6633e70` / evidence |
| T-20260920-044 | microbench/CoreMark fresh physical | root-integrator | 主会话 | done | T-042/T-043 | frozen `f6633e70` fresh physical 全绿；25 MHz `+9.398/+0.018 ns`，UCP/reset `60/4/624`，T-028 16788 合同 PASS，配置产物 0 | `verify/T-20260920-044-b25-coremark-fresh-physical` / evidence `dc6be4ae` |
| T-20260920-045 | microbench/CoreMark volatile SOF | root-integrator | 主会话 | done | T-043/T-044 | 单次 assembler PASS；唯一 SOF 36,842,099 bytes / `c648f9fe...27df4f` / `0x31585D80`，持久格式 0 | `verify/T-20260920-045-b25-coremark-volatile-sof` / evidence `50c6d22d` |
| T-20260920-046 | B25 microbench/CoreMark 真板与 golden | root-integrator | 主会话 | blocked | T-040/T-043/T-044/T-045 | candidate programmer 与 `t` PASS；`v` summary 因 TX WSPACE 64-poll timeout 被截断，parser fail，`c` 未发；golden error 86、live identity unproven | `verify/T-20260920-046-b25-coremark-board` / evidence `52654d5e` |
| T-20260920-047 | T-041 后 golden-only recovery | root-integrator | 主会话 | done | T-036/T-038；消费 T-041 blocker | candidate/terminal/m 均 0；唯一 golden transaction + final chain 证明 exact live golden | `verify/T-20260920-047-b25-ddr-golden-recovery` / integrated |
| T-20260920-048 | T-046 后 golden-only recovery | root-integrator | 主会话 | blocked | T-036/T-038/T-046 | 唯一 golden-only 事务未配置器件；两次 FTDI enumeration 均为 0，GamePC 当前无 Blaster；禁止同任务重试 | `verify/T-20260920-048-b25-coremark-golden-recovery` / evidence `4588c659` |
| T-20260920-049 | B25 CoreMark UART 背压与完整摘要 | root-integrator | 主会话 | done | T-042/T-046 | 有限 TX 等待 0x00100000 poll；behavioral/vendor-timing paced drain 下完整 CMSELF 与 parser PASS；新 MIF `0743295f...610a2f` | `fix/T-20260920-049-b25-coremark-uart-backpressure` / evidence `c11c8e83` |
| T-20260920-050 | corrected payload 完整 Gate D | root-integrator | 主会话 | done | T-043/T-049 | candidate `5b33c451`：152 green/0 red、coverage 8760、M2 40+40、delay2 32、random 3×100002、ISA 62/62、baremetal 200 | `verify/T-20260920-050-b25-coremark-uart-gate-d` / evidence `47d7a55f` |
| T-20260920-051 | corrected payload fresh physical | root-integrator | 主会话 | done | T-050 | fresh synthesis/fitter/STA/FIFO/data-delay/UCP，精确 MIF `0743295f` 绑定，25 MHz setup/hold `+9.398/+0.018 ns` | `verify/T-20260920-051-b25-coremark-uart-fresh-physical` / evidence `6cfe397b` |
| T-20260920-052 | corrected payload volatile SOF | root-integrator | 主会话 | done | T-050/T-051 | accepted T-051 fitted DB 单次 assembler PASS；唯一 SOF `39c29454...a2def`，0 持久格式，源/副本一致 | `verify/T-20260920-052-b25-coremark-uart-volatile-sof` / evidence |
| T-20260920-053 | corrected payload 真板 t/v/c 与 golden | root-integrator | 主会话 | done | T-040/T-050/T-051/T-052/T-048/T-054/T-055 | candidate PGM、t/v/c 输出与 parser-recomputed CoreMark PASS；`16.937 CM/s / 0.677 CM/MHz`；final golden PGM+postflight PASS。direct-terminal 连续行 regex 有 120 列显示伪影，raw transcript 经 T-055 严格归一解析；无重试 | `verify/T-20260920-053-b25-coremark-uart-board` / attempt-02 evidence |
| T-20260920-055 | normalize terminal soft-wrap before CoreMark strict parsing | root-integrator | 主会话 | done | T-042/T-053 artifact | 精确 CSI 右边界重复字符单例归一；9/9 parser tests、T-053 原始 transcript full parse PASS；clean-build L0 双构建与同 MIF SHA 全绿 | `fix/T-20260920-055-coremark-terminal-wrap-parser` / evidence |
| T-20260920-054 | explicit user-attested Flash baseline preflight policy | root-integrator | 主会话 | done | T-032/T-040/T-053 | 默认 exact-golden gate 不变；user-attested 仅适用于固定 T-053 candidate/golden 与固定 token；cable/JTAG-ID/UART/PHY 和最终 golden 交易仍必需；本地 25/25 PASS | `infra/T-20260920-054-attested-flash-boot-preflight` / evidence |

历史实现进度请查看 [`docs/PROJECT_STATUS.md`](../PROJECT_STATUS.md) 和
[`docs/ROADMAP.md`](../ROADMAP.md)。
