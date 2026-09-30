# Handoff T-20260905-003：R16 FP round-pack -> slot-result cut

```text
task=T-20260905-003
state=review
base=1ccbb3baed633c9c64e7a078df4cad4ece69a2a5
head=0c630561e4d458fa3717c040d42efefd53ce1198
branch=timing/T-20260905-003-r16-fp-roundpack-cut
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-003
sent_at=2026-09-05T02:38:19+08:00
received_at=2026-09-05T02:38:19+08:00
reported_at=2026-09-05T04:02:00+08:00
```

## 结论

本 lane 针对 T-20260902-058 round15 top-50 中 28 条
`g_iter.pp_pre.sig -> fp_exec.slot_result_r`（54 levels，slack
`-2.675..-2.633 ns`）插入真实的 `IT_PREP -> IT_PACK` round-pack 寄存器边界：

1. `round_pack_p1` 现在在 `pre.lead_valid=0` 时扫描普通 `pp_pre.sig` 的
   256-bit 前导位；不再把普通 finite 非零 payload 误判为零。已有迭代
   DIV/SQRT 的预解码 `lead/lead_valid` 仍直接复用。
2. `g_iter` 新增 `IT_PACK` 与 `pack_mid/pack_mid_lo/pack_mid_hi`。
   `IT_PREP` 只调用 `round_pack_p1` 并捕获完整 `fp_round_mid_t`；普通
   ADD/SUB、MUL、FMA、SCVTF/UCVTF 和 FCVT 仅在 `IT_PACK` 调用
   `round_pack_p2` 并产生 `iter_done/result`。
3. 原迭代 DIV/SQRT 的 `IT_FIN` 保留为 p1 捕获状态，但随后转入同一个
   `IT_PACK`；这样 `round_pack_p2` 与最终 `iter_done` 的状态边界统一，
   迭代 latency 不变。
4. T-056 的 `IT_ALIGN -> IT_ADD -> pp_pre` 边界未改动；没有 bypass、
   false path、接口/core/package/QEMU/QSF/SDC 变更。

## 状态、reset、kill、valid 与 pause

- `pack_mid*` 是非架构流水 payload，reset 和 `iter_kill` 时全零，
  `it_state_r` 回 `IT_IDLE`；架构状态仍只由既有 slot/response commit 路径更新。
- `IT_PREP` 遇 `valid=0` 回 `IT_IDLE` 并清空 `pack_mid*`，不产生结果。
  `IT_PACK` 遇 `valid=0` 同样回 `IT_IDLE`、清空 payload，并且输出组合逻辑
  不置 `iter_done`。
- `iter_pause` 保持现有状态/寄存器；IT_PREP 不捕获、IT_PACK 不清除或提交，
  且 IT_PACK 的 p2/`iter_done` 输出在 pause 期间被抑制，解除 pause 后继续。
- IT_FIN 的既有 `it_fin_valid_r` 仅标识迭代 p1 payload；IT_PACK 完成后清零。
  特殊值、zero、NaN/DN、FZ、RMode、FPSR flags、FCMP NZCV、slot 顺序、
  held response 和 commit 语义沿用原 helper 规则。
- B1 定向 probe 在普通 ADD 的 IT_PACK、FDIV.S 的 IT_PACK 和 FSQRT.S 的
  IT_PACK 各暂停两个周期；暂停期间均保持 busy、隐藏 `iter_done`、将 result/
  flags 保持为不可消费状态，并改变 live operand 验证寄存 payload 不变。
- pause 不改变名义 latency；只把暂停周期加到观测时间。暂停 probe 使用带超时的
  层次状态等待确认 `g_iter.it_state_r==IT_PACK`，并在每次等待开始先跨过一个
  `posedge+#1` NBA fence，避免前一 probe 的旧 IT_PACK 在 task 边界被误采样；不依赖
  divider/sqrt 固定周期，解除 pause 后只产生一个 done/result/flags 脉冲。pause
  期间同步 `iter_kill` 与异步 reset 的优先级也由新增 probe 覆盖。

## Latency 影响（按实际状态路径）

每个走普通 `pp_pre -> round_pack` 的 scalar slot 增加 1 个周期；NEON
按 scalar slot 累加。以下为当前 T-056 基线到本 lane 后的预期值：

| 路径 | 变更前 | 变更后 |
| --- | ---: | ---: |
| scalar FADD/FSUB S/D/H | 7 | 8 |
| scalar FMUL/FMA 四族 | 6 | 7 |
| scalar SCVTF/UCVTF | 5 | 6 |
| scalar FCVT（含 H source 的单 lane） | 4 | 5 |
| NEON FADD/FSUB.2S | 13 | 15 |
| NEON FADD/FSUB.4S | 25 | 29 |
| NEON FMUL/FMA.2S | 11 | 13 |
| NEON SCVTF/UCVTF.2S | 9 | 11 |
| CMP | 4 | 4 |
| FMIN/FMAX、FRINT、FCVTZS/FCVTZU | 5 | 5 |
| NEON FRINTZ.2S | 9 | 9 |
| FDIV.S/FSQRT.S,D/FSQRT.H/FDIV.H | 261/69/69/70/518 | 不变 |
| NEON FSQRT.2S | 137 | 不变 |
| FMOV | 组合 passthrough | 不变 |

其它 NEON 非迭代 round-pack 格式按实际 slot 数累加 1 周期/slot；CMP、
minmax、FRINT、FP->int 使用既有 `pp_other/ot_mid` 路径，未误加 round-pack
周期。

## 定向测试变更

`tb/sv/lcvex_fp_exec_tb.sv` 增加直接 FP_ITER 的 IT_PREP/IT_PACK
valid-drop、kill、reset 后 reissue 检查，并更新/增加以下 latency 断言：

- scalar FADD S/D/H `8`、FMUL `7`、FMADD `7`、FCVT S->D `5`；
- NEON FADD.2S `15`、FADD.4S `29`、FMUL.2S `13`、SCVTF.2S `11`；
- CMP/minmax/FCVTZS/FRINT、FDIV/FSQRT 原有不变断言保留。

## 验证状态

按 Timing Batch 规则，本 worktree 只执行了轻量静态检查：

- `git diff --check`：PASS；
- 人工结构检查：PASS（新状态/寄存器 reset、kill、valid-drop、pause、
  output 分支及 write set 已核对）；暂停 probe 的状态时序、payload 改写、
  单次释放和 kill/reset 优先级均已逐项审阅；修正后的 locator 使用
  `it_fin_valid_r` 区分普通/迭代 IT_PACK，先跨 NBA fence，并有显式超时。

没有在 lane worktree 运行 Verilator、Cocotb、QEMU、锁步、生成器或
Quartus/physical flow。它们必须在集成者按登记顺序合入的 batch candidate
SHA 上统一执行，不能拼接本 lane 之外的绿色结果。

## 下一步与风险

1. batch candidate `449f48c` 的固定 FDIV prep-count probe 已 fail-fast，随后
   candidate `cb4da06` 的旧 helper 又在普通 pause probe line 597 暴露 task 边界
   的 stale-IT_PACK NBA 采样；两次现场与日志 hash 均见 evidence。集成者将本修正
   与 T-20260905-004 按 batch 顺序合入独立 candidate，
   在精确合并 SHA 上运行完整 P7-1/P7-3/P7-4/P7-5 SV+Cocotb；strict
   lockstep 按仓内实际 acceptance 集合执行：P7-3 仅 `p7-3-neon-fp`
   base，P7-1/P7-4/P7-5 执行各自已登记的 base/edge/rounding/sequence 集合。
2. 联合 L0-L2 全绿后，按同一 QSF/SDC/IP manifest 运行一次 FP physical
   synthesis -> fitter -> signoff STA，确认 28 条 FP cone 是否离开 top-50、
   新 top、latency/寄存器/面积代价及所有 timing/DDR/Metastability 门禁。
3. 当前 review 的唯一限制是上述重型验证和 physical STA 尚未运行；
   `merge_sha` 保持 `null`，不能把本 handoff 视为验收完成。

修改文件：

- `rtl/lcvex_fp_scalar.sv`
- `tb/sv/lcvex_fp_exec_tb.sv`
- `docs/handoffs/T-20260905-003-r16-fp-roundpack-cut.md`
- `docs/tasks/evidence/T-20260905-003.json`
