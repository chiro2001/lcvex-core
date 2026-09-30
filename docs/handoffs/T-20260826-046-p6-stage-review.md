# T-20260826-046：P6/Gate E 本地验收阶段回顾

日期：2026-08-26（Asia/Shanghai）  
审计基线：`aefa7f2a362ce99e71a7958825581a0bae84a4e0`  
冻结功能候选：`b2568a506088ac34ef1529975b120a3f0849b0c1`  
证据：[T-20260826-046.json](../tasks/evidence/T-20260826-046.json)

## 阶段结论

**“P6 本地退出条件已满足”有充分证据，但“正式 Gate E/main 已晋级”尚不成立。**

同一冻结候选 `b2568a5` 已具备：

- T-043 本地 Gate D 全量退出 0；
- T-044 lite fresh-root 35M 到 `/init ready` 且保持稳定；
- T-044 main 从 finalized parent 连续 5M，并跨过 SCTLR 旧首错；
- 两条有效链均 finalized，且本次审计再次实际 `read_manifest` 成功；
- 输入、QEMU、plugin、coordinator、filelist、资源、失败现场与 artifact hash
  均有记录，无 QEMU/Verilator 孤儿进程。

main 无 initrd，只证明 early boot；用户态判据由 lite no-FP `/init` 线提供。
这是已声明的 Gate E 分工，不是证据矛盾。

## 证据矩阵摘要

| 项目 | 结论 |
| --- | --- |
| 同 SHA Gate D | 充分：M2/R1 40/40、delay2 32、hardening 26、随机 3×100k、coverage、baremetal-C、50/50 `rc=0` |
| 固定输入与 QEMU | 充分：QEMU 11.1.0 与 Image/DTB/CPU/machine/icount/plugin/coordinator/filelist 均有 SHA |
| lite fresh-root/EL0 | 充分：35M、`/init ready`、用户地址 SVC 后继续稳定、70 checkpoints |
| main continuation | 充分但范围受限：5M early boot、10 checkpoints；不宣称 main 用户态 |
| 失败分类 | 充分：0 条 socket 失败、pending 链和 invalid plugin 链均未复用 |
| 正式 CI/main 晋级 | 未完成：用户要求本轮不等待 CI；Git 的 `main` 晋级规则没有被取消 |
| finalize 原子性 | 明确缺陷：失败前写完成态，已登记 T-045 |
| PAuth 脏 restore | 只有间接覆盖：不推翻 P6，但应在扩展 P7 checkpoint 前补 fixture |

T-039 parent plugin 与 `b2568a5` 的 `qemu/plugins` 源码没有差异；不同二进制
SHA 来自不同 worktree 构建产物。严格 child provenance 仍必须绑定 parent
实际二进制，所以 `main/chain-final` 使用 parent plugin；当前 plugin 的另一轮
5M 架构锁步也全绿，但其 child 因二进制 SHA 不匹配被正确列为无效链。

## P7 前的真实前置条件

1. **T-045 是新 checkpoint 发布前的阻断项。** 它不否定已有两条有效链，
   但在 P7 增加 V/FP 状态前必须让 finalize 失败保持 pending/原状态。
2. 增加 SCTLR bit31/30/27/13 脏 sidecar restore fixture，关闭 T-042 仅间接
   覆盖的负路径。
3. 收敛标量 ISA 文档基线：`ISA_GAPS.md` 是较新的事实快照，
   `ISA_SCOPE.md` 顶部和 `DEVELOPMENT_PLAN.md` 仍混有早期状态；Gate D 的
   `61/60` 表示“seen/expected 中含额外已知族”，不是测试失败，但展示口径应改清楚。
4. P7 首个任务应先定义协议而不是直接堆指令：V0–V31、FPCR/FPSR reset/权限/
   提交时机、可选 vector commit 字段、QEMU 比较、失败转储和 checkpoint 新版本；
   既有 scalar commit 字段保持不变。

## 建议顺序与决策点

推荐顺序是：

```text
确认 P6 本地完成策略
  → T-045
  → PAuth dirty-sidecar + 标量范围文档收敛
  → P7 架构/验证协议设计
  → FPCR/FPSR
  → FP32/FP64 标量
  → NEON 整数/访存
  → 选定 NEON 浮点
```

需要用户确认的核心选择只有一个：

- 延续当前策略，在上述最小前置包完成后从 feature 分支启动 P7，把可信 CI、
  QEMU 干净 patch replay 和 `main` 晋级后置；或
- 先完成可信 CI/patch replay 与 `main` 晋级，再启动 P7。

本评审推荐第一种，因为它与“完整核功能完善前以本地测试为主”的既定策略一致；
但文档必须继续保持“P6 本地完成、正式 Gate E/main 待晋级”的黄色状态。

## 停止点

本任务只做阶段审计。T-045、PAuth fixture、CI/main 晋级和 P7 均未启动，
当前停在用户决策点。
