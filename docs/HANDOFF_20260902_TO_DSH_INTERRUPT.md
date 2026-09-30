# LCVEX 上下文交接：dsh 中断恢复后更新（2026-09-02）

> 本文更新自 dsh 中断恢复交接。`T-20260902-004` 与 `T-20260902-005` 已完成并合入；
> 当前暂停新任务派发，等待后续按依赖继续。

## 1. 当前 Git / 工作区

- 仓库：`/home/chiro/projects/mycpu/lcvex`
- 分支：`feature/p7-final`
- HEAD：`bd31dec`（`tasks: accept T-20260902-004 Quartus FP/NEON compat fixes`）
- 相对 origin 领先 8 个提交，未推送（上次推送点为 `4a257b0`）；`main` 未晋级。
- 未跟踪：`docs/HANDOFF_20260902_TO_DSH.md`（保留，勿删）。
- 本交接文件：`docs/HANDOFF_20260902_TO_DSH_INTERRUPT.md`（已更新）。

## 2. 已完成并合入的成果

| 任务 | 内容 | merge/accept |
| --- | --- | --- |
| T-20260902-003 | 子代理调用冒烟测试 | `be1bef6` |
| T-20260902-002 | A10 JTAG 烧写 SOP 调研 | merge `18befa1` / accept `31263a0` |
| T-20260902-001 | A10 分阶段综合资源探针与门限重评估 | merge `9bde1d2` / accept `732aa56` |
| T-20260902-005 | F1a 默认启用参数传播 | merge `057a1c1` / accept `bdde0d5` |
| T-20260902-004 | Quartus FP/NEON 兼容修复 | merge `922d4f8` / accept `bd31dec` |

关键结论：
- T-001：历史 35GB 先验门不再一票否决；当前安全窗口约 36GB；真实 full-FP synthesis 的阻断是 RTL Quartus 21.4 elaboration 兼容错误，不是内存。
- T-002：参考项目真机路径为自建 jtagserver（端口 1310，15MHz）+ `quartus_pgm -c 'MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310' -m JTAG -o 'p;<sof>'`；LCVEX 上板前需确认 JTAG identity 并冻结 SOF/hash。
- T-005：F1a 参数已传播到 `core_wrap`/`cluster_top`/`catapult_soc_top`/`catapult_a10_top`/`lcvex_soc_tb`/`Makefile`，默认 `FETCH_FIFO_ENABLE=1`，保留显式 `0` 关闭 F0 路径。
- T-004：修复 `lcvex_fp_scalar.sv` 非定常 loop、`lcvex_neon_int.sv`/`lcvex_neon_fp.sv` lane out-of-range；合并 SHA 上 `make compile` 与 `sim-sv-fp-scalar` 已复跑通过；已知无关 P7-2 Cocotb 失败已记录。

## 3. 当前状态：T-004/T-005 已合入，暂停新派发

- `T-20260902-004`：`done / merged`，worktree 分支 `fix/T-20260902-004-quartus-fp-neon-compat`。
- `T-20260902-005`：`done / merged`，worktree 分支 `feature/T-20260902-005-f1a-default-on`。
- 本轮之后暂停新任务派发；后续若继续，从本文与任务 JSON 恢复上下文。

## 4. 后续建议步骤

1. 推送当前 `feature/p7-final` 到 origin（当前领先 8 个提交）。
2. 重跑远端真实 full-FP synthesis（T-004 修复后），确认 Quartus elaboration 不再报三类错误；成功后按单阶段队列进入 fitter → STA → assembler/SOF。
3. 派发 T-013：F1a 默认-on 完整 Gate D，并同步文档/最终 FPGA candidate。
4. 如需要 P7-2 Cocotb 全绿，另开 decode B2c DUP/SQADD 编码重叠修复任务（不属于 T-004 写集）。
5. 上板前人工确认 JTAG identity（`10AT115S(1|2)` vs QSF `10AX115N4F40E3SG`）并冻结 SOF/hash。

## 5. 已知阻塞 / 边界

- JTAG identity 文本未闭合，上板编程前必须人工确认。
- 当前 LCVEX 候选 SOF 未冻结；JIC/EPCQ 真机烧写无参考成功记录，需单独授权。
- `sim-cocotb-p7-2-neon` 存在一个与本任务无关的既有失败（SQADD 被 B2c DUP decode 分支捕获）。
- `scripts/check_task_timestamps.py --scope live --exit-code` 仍因历史任务报错；本次新增任务无新增时间戳问题。
- 所有“完成”以仓库 evidence 为限，不宣称 A10/Fmax、板级启动、CI/main 晋级或完整发布。

## 7. 15:1x 更新：T-006/T-007 均 blocked

- T-20260902-006（F1a 默认-on Gate D）：**blocked**。完整串行 Gate D 退出 1；9 个 F1a-on 定向锁步失败（timer/RNDR off-by-one、ADC/SBC/NGC、post-index load/store）。默认-on 暂不能通过 Gate D。
- T-20260902-007（A10 full-FP synthesis 重跑）：**blocked**。远端 probe-only 全 lane-width 钳位后 full-FP synthesis PASS（ALM ~493k、DSP 186、PM 12.6GB）；但仓库 `rtl/lcvex_neon_int.sv` 仍缺 32-bit lane clamp，正式 RTL 在 Quartus 21.4 elaboration 仍失败。
- 已合入证据：T-006 merge `1635369` / record `852edee`；T-007 merge `60738c3` / record `ab3ca19`。
- 当前 HEAD：`ab3ca19`，相对 origin 领先 13 个提交，未推送。
- 后续（14:00 后不派发新任务）：
  1. 修复 `lcvex_neon_int.sv` 全 lane-width 钳位并合入；
  2. 修复 F1a-on 三类锁步问题；
  3. 修复后在合并 SHA 重跑完整 Gate D 与 full-FP synthesis，再进入 fitter/STA/SOF。

## 8. 20:3x 更新：T-008/T-009/T-010/T-011 已完成

- T-20260902-008（NEON lane clamp）：done/merged，`c4e7904` / `8777742`。
- T-20260902-009（F1a lockstep 修复）：done/merged，`386f62f` / `a4503d0`。
- T-20260902-011（F1a-on 完整 Gate D 复跑）：done/merged，PASS 151/0；`7c35dda` / `62beb31`。
- T-20260902-010（full-FP synthesis merge SHA 重跑）：done/merged，PASS，正式 RTL 直接通过；`cfc0bc5` / `0ba06d1`。
- 当前 HEAD：`0ba06d1`；相对 origin 领先 33 个提交，未推送。
- 后续：fitter → STA → assembler/SOF（单阶段队列）；同步文档与最终 FPGA candidate；如需正式把 FETCH_FIFO_ENABLE=1 作为默认，已有 Gate D 证据。
