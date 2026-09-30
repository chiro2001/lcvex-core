# 09 开放风险清单

> 以下均为**未解决/待审计**风险，按主题列出。标注“后置”表示当前范围明确不要求，
> “风险”表示已有识别或有部分证据但未闭合。

## 1. ISA / 架构后置风险

| 风险 | 状态 | 影响 | 证据/说明 |
| --- | --- | --- | --- |
| POST-V82-DEFERRED（RCpc、MTE、MOPS、Crypto、剩余 LSE128、剩余 FP/ASIMD、剩余 maintenance、PMU） | 后置 | 不能宣称完整 ARMv8.2-A / 完整扩展 | `docs/V82_PROFILE_MANIFEST.md` |
| SVE256 / SVE2 / SME | 后置（P8 未开始） | 无向量长度/谓词/SVE 访存 | SVE 只有 Linux probe shim |
| EL2 / EL3 虚拟化和安全态 | 后置/off | 无 hypervisor/安全世界 | QEMU `el2/el3=off` |
| RCpc `LDAPR/LDAPUR` | 后置 | 弱一致性 acquire 语义未覆盖 | `DEF-RCPC-001` |
| 其它 LSE128 家族与多核一致性 | 后置/C 线 | 完整 128-bit 原子/多核语义未覆盖 | `DEF-LSE128-001` |
| FP exception enable/trap 和完整 IEEE 异常 | 后置 | 仅选定 raw-bit 子集 | `DEF-FPEXC-001` |
| 标量 FP16 memory LDR/STR H | blocked | 当前明确不实现 | `EXT-FP-012` |

## 2. 平台 / 板级风险

| 风险 | 状态 | 影响 | 证据/说明 |
| --- | --- | --- | --- |
| B5 SoC Quartus Synthesis OOM / 顶层 Qsys+glue 阻塞 | blocked/外部 | 当前无法取得 fit/STA/SOF；FPGA-F3/F4 blocked，T-067 未解除 | T-101/T-102、T-20260830-008/016/020；F2 已证明模块级 <16GB 与小工程 bottom-up 流程 |
| fp_scalar 大位宽除法 Quartus 兼容 | 已修复方案/待完整验证 | 已用多周期 256-bit restoring divider 替代 `lpm_divide >64`；默认 FP 完整顶层仍 pending | T-20260830-003 |
| `A64_FP_SIMD` 未真正门控 FP/NEON | 已修复 | 真正 generate-gate 已实现，no-FP 可移除实例 | T-20260830-004/FPGA-F2 |
| Gate F-BOARD（DDR March、板测、Linux 板测） | 未完成/外部阻塞 | 发布门未过 | `FPGA_PLAN.md` |
| 完整 2GiB/ECC/RAS/量产签核 | 后置 | 非当前 F 发布范围 | `FPGA_PLAN.md` |

## 3. 多核 / 一致性风险

| 风险 | 状态 | 影响 | 证据/说明 |
| --- | --- | --- | --- |
| Linux SMP | 后置 | 多核 OS 启动不在当前交付 | ADR-005 |
| C3 四核功能 | 已关闭（功能矩阵） | C3 已合入并通过 4 核 message-passing/sysctrl/timer；无 TLB shootdown/多核 checkpoint/Linux SMP | merge `fccb674`、T-20260829-095 |
| 8/16/32 核扩展性 | 规模数据已测量，功能未完成 | 8/16/32 参数化/no-FP/synthetic 通过；16 核默认 FP 未完成，32 核未测；不是合规 | T-20260830-018/019 |
| 单事务/单 outstanding | 风险/已知限制 | 多核性能/并发模型局限 | C2 baseline |
| 多核差分协议 | 部分 | QEMU 多 vCPU 严格锁步未实现，仅 D0 设计 | `LCVX_DIFF_MC_V2.md` |
| IRQ/PSCI/TLBI 竞态、异步事件顺序 | 风险 | C3/C4 需专门验证；C3 为 GIC/PSCI-lite | C3-pre R-C4 |
| full-core fault 正向注入 | 风险 | `core_fault` 恒 0，仅负向检查 | T-092 |
| running-reset-restart | 风险 | 运行中直接 reset 后 restart 未验证 | T-092 |
| CORE_COUNT=1 全量回归 | 已关闭 | T-20260830-022 已重跑 cluster/l2_cluster lint，F 单核 Gate D 全绿 | T-20260830-022 |

## 4. 验证 / 晋级风险

| 风险 | 状态 | 影响 | 证据/说明 |
| --- | --- | --- | --- |
| Gate E 正式验收 | 部分/后置 | 本地 P6 功能完成，正式 Gate E/CI/main 未晋级 | ROADMAP/PROJECT_STATUS |
| CI 可信度 | 风险 | CI 未完全可信前不能替代本地 Gate D；`main` 晋级后置 | GIT_WORKFLOW |
| Gate F-ISA / F-MEM / F-BOARD / F-RELEASE | 部分 | 本地 Gate D、C3/C4、性能、checkpoint 证据已具备；仍缺真实 A10 fit/STA/SOF、DDR/板测和同一最终 SHA 绑定 | ADR/ROADMAP |
| checkpoint v4 完整联合恢复 | 已关闭 | AUD-12 完成 QEMU incoming + DUT restore + CONTEXTIDR 对齐，smoke 全绿 | T-20260829-117 |
| 全量 QEMU sysreg inventory | 未完成 | 系统寄存器 reset/权限矩阵未全量 probe | T-098/T-093 |
| 覆盖度量 | 部分 | 仅特定 SV TB 覆盖；无全模块行/翻转覆盖 | `VERIFICATION.md` |
| 多核/长 Linux/Quartus 长期稳定性 | 未完成 | L4 不充分 | 各任务 known_limits |

## 5. 流程/治理风险

| 风险 | 状态 | 影响 |
| --- | --- | --- |
| 无常驻任务服务/自动调度 | 已知设计 | 手工排队；任务多了可能成瓶颈 |
| 大文件/远程产物不在 Git | 已知设计 | 外部审计需要请求 artifact store/持久 URI |
| 单一共享 QEMU fork / checkpoint 串行 | 已知设计 | 多 Agent 并行受限 |
| 只读审计材料未重跑重型验证 | 本材料包限制 | 结论不能代替新鲜回归结果 |

## 6. 建议外部审计优先关注

1. 当前功能 RTL 基线 `a110ba3` 的 `make test` / Gate D 是否仍可复现（已记录 T-20260830-022）。
2. checkpoint v4 联合恢复证据已存在；后续可关注更宽寄存器/最长链恢复。
3. B5 SoC 的真实顶层 fit/STA/SOF 仍被外部资源/Qsys+glue 阻塞；fp_scalar 方案已落地但完整顶层未验证。
4. 多核 C3 功能与 C4 规模数据应区分“功能/趋势”边界，避免误读为 Linux SMP/架构合规。
5. V82 profile 中 blocked/deferred 行是否在外部审计适用范围内。
