# LCVEX 交接文档 069：P6 LSE 原子实现进行中

日期：2026-08-25（Asia/Shanghai）  
前置：`068-p6-lse-atomic-first-gap.md`  
当前分支：`feature/p6-system-reg-shim`  
当前提交：`7edd7fd docs: record first Linux LSE atomic gap`

## 1. 交接边界

本次交接立即暂停在“首次 LSE 差分缺口已定位、`LDADD` 实现骨架已写入但
尚未验证”的状态。不要把当前 RTL 改动当作已完成或已通过差分，也不要
回退、覆盖或清理这些未提交改动。下一位执行者应先从现有 checkpoint 复现
缺口，再逐项修正和验证。

## 2. 工作区与运行状态

当前 `git status --short --branch`：

```text
## feature/p6-system-reg-shim
 M rtl/lcvex_core.sv
 M rtl/lcvex_decode.sv
 M rtl/lcvex_pkg.sv
```

当前没有后台 QEMU、Verilator、锁步或 Gate D 进程。最近一次检查的存储
状态为：根文件系统约 83 GiB 可用，`/tmp` 约 6.6 GiB 可用；启动长跑前
仍须重新检查 `/tmp`、磁盘和单个物理核负载。遵循本项目约束，普通测试最多
使用约 50% 主机资源，构建线程不超过 6，长跑绑定单个物理核。

QEMU fork 在 `../qemu`，固定 release 为 11.1.0；其中已有的 dirty 改动
是预期内容，禁止对该目录执行 `git reset --hard` 或 `git checkout`。

## 3. 已完成的基线

- P0～P5、Gate D 基础验证已完成；P6 平台已有 PL011、Generic Timer、
  GICv2/GICv2m、DT、PSCI 和系统寄存器 shim。
- Linux 逐指令锁步在多个深段已推进到约 28M；前置差异已经关闭的项目
  见 `docs/ROADMAP.md` 和 handoff 063～068。
- 最近已知通过：`make compile`、`make test`、`make checkpoint-sys-smoke`、
  `make m2-4b`（base/cache）、`hard_p6_isa` 101 条、`hard_gic` 52 条。
  这些是前一工作阶段的结果；本次 LSE 骨架变更尚未完成同等回归。
- 最新稳定 checkpoint：
  `build/difftest/tail-resume-ckpt17-20260825`，manifest 使用绝对路径，
  最近记录为 `diff-999999`。

## 4. 未提交的 LSE 骨架

当前改动涉及：

- `rtl/lcvex_pkg.sv`：增加 `atomic_op_t/ATOMIC_ADD`，并在
  `decoded_insn_t`、`ex_pipe_t` 中增加 `is_atomic/atomic_op`。
- `rtl/lcvex_decode.sv`：按 LSE 编码识别 `LDADD` 的 W/X 形式；目前把
  acquire/release 位作为顺序模型下的同一条两阶段事务处理，其他
  `LDSET/LDCLR/LDEOR/LDUMAX/LDUMIN/SWP/CAS` 仍为 UDEF。
- `rtl/lcvex_core.sv`：EX/MEM 先发读请求捕获旧值，再计算按访问宽度回绕
  的新值并发写请求；旧值复用 load WB，提交包携带一次 Store 副作用。

前一阶段已经成功执行过 `make compile` 和 `make lockstep-build-kernel`，
但这不能证明运行时语义正确；本次交接后必须重新针对 `LDADDAL` 实测。

## 5. 首个复现点

从 checkpoint 继续运行的入口：

```bash
conda activate lcvex
CHAIN=build/difftest/tail-resume-ckpt17-20260825 \
RESUME_SEQ=999999 MAX_INSNS=100000 PIN=0 \
setsid bash sim/difftest/run_lockstep_resume.sh \
  > /tmp/lcvex-ldadd-repro.log 2>&1 < /dev/null &
```

首次真实 Linux 分歧为：

```text
0xffff8000801e7868: 0xb8f80001  ldaddal w24, w1, [x0]
```

固定 QEMU 观察到的语义：读取 `[x0]` 的旧值 `1` 写入 `W1`，将
`0xffffffff + 1` 按 32 位回绕为 `0` 并写回 `[x0]`，该指令退休时有一次
32 位 Store。旧实现把它判为 UDEF。

## 6. 下一步顺序

1. 先审阅 `git diff` 和上述复现日志；确认 dmem 请求/响应的两阶段握手，
   包括随机延迟、fault、D-L1/I-L1/L2 和 MMU 路径不会重复发请求。
2. 修正并验证 W/X 访问宽度、字节使能、32 位回绕、`Rt` 旧值写回、
   commit packet 的单次 Store，以及 load-use/forwarding。
3. 增加 `hard_lse_atomic` baremetal/QEMU 定向测试，覆盖
   `LDADD/LDADDA/LDADDL/LDADDAL`、W/X、零值/最大值回绕和 acquire/release；
   默认开启 difftest，失败时保留指令、执行前状态、RTL/QEMU 状态和提交尾迹。
4. 通过定向测试后再跑 checkpoint 深段和必要的全回归；验证前不要提交
   当前三份 RTL 改动。
5. 按 Linux 实际轨迹依次补 `LDSET/LDCLR/LDEOR/LDUMAX/LDUMIN/SWP/CAS`，
   不得把原子指令降级为普通 Load/Store 或跳过内存比较。
6. LSE 稳定后继续 WFE/WFI、Timer IRQ 唤醒、稳定 early boot 和用户空间
   入口验收，并同步更新 `docs/ROADMAP.md`、`docs/PROJECT_STATUS.md`。

## 7. 提交与安全注意

- 本文可单独提交；LSE RTL 骨架应与实现、测试分逻辑提交，且必须附测试
  命令和结果。若只提交本文，不要误把工作区 RTL 一并 `git add`。
- 不要删除 `tail-resume-ckpt17-20260825`，也不要改写其 manifest 的绝对
  路径；新的 checkpoint 使用新的目录名并先检查磁盘空间。
- 回复、文档和交接记录使用中文。完成本阶段后先报告当前状态、剩余缺口和
  测试证据，再决定是否继续长跑或提交。
