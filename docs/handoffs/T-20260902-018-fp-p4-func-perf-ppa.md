# Handoff T-20260902-018: FP-P4 Function/Performance + One/Two-lane PPA

```text
task=T-20260902-018
state=review
base=1d57fa9dadc92d9c85ad755ce0debd0c6fc0acb7
head=1d57fa9dadc92d9c85ad755ce0debd0c6fc0acb7
branch=verify/T-20260902-018-fp-p4-func-perf-ppa
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-018
sent_at=2026-09-03T04:18:30+08:00
received_at=2026-09-03T04:20:00+08:00
reported_at=2026-09-03T05:25:11+08:00
```

## 摘要

FP-P4 完成全量功能/性能验证和一/二 lane PPA 证据收集。

- 功能：compile/SV raw-bit/Cocotb 全绿；A76 required L2 锁步
  p7-1（28）、p7-3（48）、p7-4（94）、p7-5（102）全部 PASS。
- 性能：在共享单 lane 事务化后重跑 fp_scalar、fp_fp16、neon_vect 和两条
  纯计算链；所有 workload 均 PASS。周期对比 P0 明显上升，符合“单在途阻塞、
  无年轻绕过”的预期。
- FP 观测：新自定义 runner 直接读 RTL 事务接口，记录 fp_issue、
  fp_busy_cycles、fp_rsp_wait_cycles 和 fp_slot_done；op/format 由动态
  commit trace + Capstone 分类。
- PPA：远端 Quartus 隔离 probe 跑一 lane `lcvex_fp_exec` 和二 lane 面积
  探针；只 synthesis，不 fit/STA/SOF。详细结果见 PPA 文档。

## 功能结果

| 层 | 结果 |
| --- | --- |
| L0/RTL lint | `make compile` PASS |
| L1 SV raw | fp-scalar/p7-2/p7-3/p7-4/p7-5 全 PASS |
| L1 Cocotb | fp-scalar 5/5, p7-3 4/4, p7-4 5/5, p7-5 8/8 PASS |
| L2 lockstep | p7-1/3/4/5 A76 required main PASS（28/48/94/102 条） |

## 性能结果（摘要）

| workload | cycles | retired | fp_issue | fp_busy | fp_rsp_wait | slots |
|---|---:|---:|---:|---:|---:|---:|
| fp_scalar | 255,382 | 65,963 | 41,176 | 98,736 | 57,560 | 41,176 |
| fp_fp16 | 311,633 | 82,013 | 65,605 | 131,210 | 65,605 | 65,605 |
| neon_vect | 310,977 | 66,721 | 36,891 | 135,267 | 98,376 | 98,376 |
| neon_fp_chain | 35,409 | 5,654 | 4,608 | 23,040 | 18,432 | 18,432 |
| scalar_fp16_chain | 38,999 | 10,266 | 8,201 | 16,402 | 8,201 | 8,201 |

## PPA 结果

- 一 lane `lcvex_fp_exec`：93,564 ALM / 133,689 comb ALUT / 1,733 regs /
  24 DSP，wall 1,487.9 s，peak VM 2,255 MB。
- 二 lane 面积探针（两个完整 `lcvex_fp_exec`）：187,024 ALM / 267,283 ALUT /
  3,466 regs / 48 DSP，wall 1,706.1 s，peak VM 4,343 MB。
- 结论：默认保持 **keep-1**；二 lane 没有功能 scheduler、fit/STA 或性能收益
  证据，不满足晋级条件。

## 边界/风险

- 纯计算链为重建等价版本，不是 FP-P0 字节级原源码；cycle 对比仅方向性。
- 自定义 runner 链接到同 SHA Cocotb SoC 模型（默认参数），非全新 Verilator
  build；功能/数据结构同源，证据中已记录。
- 二 lane 探针不是功能二 lane scheduler，不能作为性能收益证据。
- 未跑 full-top synthesis/fit/STA/SOF；未跑 P7-2 Cocotb。
- L2 只跑 main 子集，未跑全部 edge/rounding/sequence 镜像。

## 下一步

集成者复跑/审核后，若需要 full-FP synthesis/fit/STA 再登记 FP-P5。
