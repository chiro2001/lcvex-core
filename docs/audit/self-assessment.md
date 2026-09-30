# 外部审计自评估

> 本文件对 9 个方向分别给出：现状、已做/未做、已知限制、建议外部审计员提问。
> 所有“完成”都以仓库现有 evidence 为限。

## 01-governance

- **现状**：多 Agent 流程规范化，任务 JSON/handoff/evidence/ADR 分离；A/B/C 线
  并行；资源与 cgroup 规则明确；无常驻调度服务。
- **已做**：任务状态机、worktree/写集互斥、QEMU 串行、时间戳、dsh 适配、
  暂停恢复、cgroup 限制、ADR 决策链。
- **未做**：自动化 taskctl；完整跨主机/远端任务状态同步；Gate/资源的全局
  原子 reservation；任务索引实时自动更新。
- **已知限制**：手工排队和手工更新任务索引；“active”目录中很多 done 任务尚未
  归档；外部只能凭 JSON/handoff 追溯。
- **建议审计问题**：
  1. 如何验证一个任务确实只写了自己的 `writes`？
  2. task JSON 的 `base_sha/head_sha/merge_sha` 是否完整可追？
  3. cgroup 限制在所有重型 Verilator 记录中是否实际执行？
  4. 暂停/恢复/blocked 是否有人误改历史？

## 02-reproducibility

- **现状**：工具链固定，QEMU patch 可重放，Makefile/filelist 入口齐全，
  CORE_COUNT 参数化有文档；本地可复现证据充分。
- **已做**：版本锁定；RTL filelist SHA；QEMU patch SHA；干净补丁重放脚本；
  checkpoint/manifest 哈希；C2 baseline 测量记录。
- **未做**：交叉编译器版本未完全固定；没有一键“全量发布构建”脚本；远端 Quartus
  工程不是仓库可重放全集。当前功能 RTL 基线 `a110ba3` 已由 T-20260830-022
  新跑本地 Gate D 13/13；当前 HEAD 相对该基线仅文档/QEMU patch 改动。
- **已知限制**：需要外部 QEMU fork 路径 `../qemu`；部分平台产物是生成后快照；
  license/远程工具不在包内。
- **建议审计问题**：
  1. 能否在全新 clone 只用仓库内容重建 QEMU + 跑 `make test`？
  2. QEMU patch 顺序/内容是否必须与 `qemu/VERSION` 匹配？
  3. CORE_COUNT=1/2 的构建和 smoke 能否按文档复现？
  4. checkpoint manifest 的 artifact hash 是否可从仓库外部获取到？

## 03-rtl-quality

- **现状**：单核 RTL 可 lint/可仿真；FP/NEON 和 FPGA 线有模块级验证；命名和
  参数化总体良好；存在明确综合问题。
- **已做**：RTL 模块/文件清单、lint 入口、参数化、关键资源热点测量、CDC 基础
  设计说明。
- **未做**：无全仓库零 warning 门禁；无正式 lint waiver 台账；无完整 CDC
  形式化/跨时钟仿真。A64_FP_SIMD 已实现真正 generate 门控（T-20260830-004），
  fp_scalar 已改为多周期 256-bit restoring divider（T-20260830-003），
  L2/L1D 已做降规模参数化（T-20260830-002）并在 FPGA-F2 隔离副本中通过
  heavy module standalone <16GB；但仍未证明完整 A10 顶层 fit/STA/SOF。
- **已知限制**：T-102 只完成部分模块 standalone；部分模块未测；远端实验在
  实验副本，不在仓库。
- **建议审计问题**：
  1. 当前 `make compile` 的 warning 是否都在可控范围内？
  2. 为什么 `A64_FP_SIMD=0` 不能移除 FP/NEON 实例？
  3. fp_scalar 的 >64 位除法计划如何可综合？
  4. L1D/L2 writeback 的面积/内存热点的缓解路径是什么？
  5. CDC/异步复位是否有完整约束和验证？

## 04-isa-architecture

- **现状**：V82 非 SVE profile 以机器可检查清单管理，94/117 implemented；
  标量/FP/NEON 选定子集与 QEMU 锁步验证；SVE/POST-V82 后置。
- **已做**：profile manifest 与脚本；系统寄存器/异常/权限/维护/barrier 文档；
  QEMU 固定版本与插件；FP raw-bit。
- **未做**：blocked 的 `EXT-FP-012`；RCpc/MTE/MOPS/LSE128/Crypto
  等；全量 sysreg inventory；EL2/EL3；SVE。logical shifted-register ROR
  已实现，不属于缺口；`ADD/SUB` shifted-register ROR 为保留 UDEF。
- **已知限制**：不是完整 ARMv8.2-A；Linux 35M 只证明动态路径；部分系统寄存器
  只有 shim。
- **建议审计问题**：
  1. 是否有任一“implemented”行缺少 QEMU/定向证据？
  2. blocked/deferred 行是否被误算入完成度？
  3. `LDR/STR H` 不实现是否影响外部用例？
  4. CONTEXTIDR_EL1 的 live core 和 checkpoint 恢复一致性如何证明？
  5. barrier/maintenance 的 EL0 权限矩阵是否与 QEMU 完全对齐？

## 05-verification

- **现状**：L0–L4 分层；功能 RTL 基线 `a110ba3` 本地 Gate D 13/13 PASS；
  随机/覆盖/baremetal-C 有记录；checkpoint v4 联合恢复已通过（AUD-12）。
- **已做**：定向/随机/覆盖；失败保存；checkpoint manifest/provenance；P7
  FP/NEON 分层门；CI workflow；T-20260830-022 当前基线 Gate D；
  T-20260829-117 checkpoint v4 joint restore。
- **未做**：全量 sysreg inventory；完整多核 litmus；可信 CI 全绿；
  nightly/Quartus/板测。
- **已知限制**：覆盖率仅部分 TB；CI 未可信；多核无真实 QEMU lockstep。
- **建议审计问题**：
  1. Gate D 13/13 的具体 SHA 与当前审核 SHA 是否相同？
  2. checkpoint v4 的恢复验证是否已经闭环？
  3. 外部能否从 evidence JSON 重建失败/通过结果？
  4. 负向测试覆盖率是否足以支撑“不实现即 UDEF”的声明？
  5. 是否有针对 CDC/reset 的正式仿真用例？

## 06-multicore

- **现状**：C0–C2 完成，C3 四核功能实现已合入（merge `fccb674`），C4 8/16/32
  规模/趋势测量已完成（T-20260830-018/019）；C2 有模块级+定向系统级证据，
  但仍无 QEMU 多核锁步，无 Linux SMP。
- **已做**：目录式 MSI、双核 message passing、原子/屏障/维护/reset 定向、
  C4 baseline、C3 四核功能矩阵、C4 8/16/32 synthetic/no-FP 趋势、
  CORE_COUNT=1 回归（T-20260830-022）。
- **未做**：完整多核差分；Linux SMP；多核 checkpoint/异步事件完整实现；
  真实多核指令级 litmus/perf；默认 FP 16/32 完整 lint/elab。
- **已知限制**：单事务/single outstanding；目录位宽/探针简化；`core_fault` 恒 0；
  running reset/restart 未验。
- **建议审计问题**：
  1. C2 是否足以支持“双核功能候选”？
  2. C3 四核是否有任何未公开的实现？
  3. 单事务模型对一致性的正确性影响是什么？
  4. 为什么多核没接入 QEMU lockstep？
  5. CORE_COUNT=1 回归缺失如何影响多核合并？

## 07-fpga

- **现状**：平台输入/工程骨架可重生成，T-064 历史 full flow/STA 曾通过；
  FPGA-F2 完成深拆分与 blackbox→QDB→fitter-only 小工程验证；FPGA-F3/F4
  blocked，当前 B5 SoC full flow 仍无 fit/STA/SOF，板级未完成。
- **已做**：平台 manifest/hash，Qsys/IP regenerate，T-064 full flow，B5 SoC
  本地 L0/L1，T-101/T-102 热点定位，T-20260830-001~005 的模块综合/降规模/
  generate-gate/partition 评估，T-20260830-008 F2 突破。
- **未做**：真实 A10/SoC 顶层 fit/STA/SOF；DDR/板测/Linux 板测；Gate F-BOARD。
  F3/F4 已记录具体阻塞（Qsys/`alt_sld_fab`、顶层 glue 内存、复制 DB 不可用）。
- **已知限制**：远程工具/工程在仓库外；T-064 结果不覆盖 B5 最新；开源代理
  只是趋势。
- **建议审计问题**：
  1. 是否有 B5 最新代码的 Quartus full flow 成功记录？
  2. 平台 SHA256SUMS 是否与实际输入一致？
  3. OOM 是否已明确归因且缓解路径可执行？
  4. T-064 的历史结果能否作为当前 F 候选的 F-MEM/F-BOARD 证据？
  5. license/敏感信息是否曾进入材料？

## 08-security-boundary

- **现状**：规则明确：远端写集受限、不读 license、不删未知文件、资源 cgroup、
  Git 不进大文件/敏感项。
- **已做**：任务 JSON 写集；远端操作规则；cgroup 记录；evidence 保留；本包只写
  白名单。
- **未做**：没有独立的敏感信息扫描/自动化防护；没有远程审计日志的完整归档。
- **已知限制**：仓库中的任务 JSON 仍含远程实验路径和工具版本，但无密码/
  license 内容。
- **建议审计问题**：
  1. 是否任何材料包含远程主机密码/内部权限？
  2. 远端 license 是否只验证存在性而未复制内容？
  3. 外部审计结果能否安全地放入 `external-results/`？
  4. 是否有对文件写入范围自动检查的机制？

## 09-risks

- **现状**：开放风险已按 ISA/平台/多核/验证/流程分类，均在文档中标注。
- **已做**：后置/未完成/风险均明确，不冒充完成。
- **未做**：主要剩余风险仍有：FPGA T-067/F3/F4（外部资源）、完整 board/CI、
  多核差分/Linux SMP、完整 ARMv8.2-A 扩展。
- **已关闭/缓解**：checkpoint v4 联合恢复、QEMU fresh replay canonical、
  CORE_COUNT=1 回归、C3/C4 规模数据缺口已由后续任务补上；但本材料包本身
  仍是静态审计基线，不替代新证据。
- **已知限制**：本包只整理，不新跑重型验证。
- **建议审计问题**：
  1. 哪些风险会阻止 F 单核发布？
  2. 哪些风险会阻止 G-MC 多核列车？
  3. 外部审计是否认为 POST-V82/SVE 后置符合项目目标？
  4. 是否需要在进入 main/CI 前先关闭 checkpoint v4 / CORE_COUNT=1 回归？
