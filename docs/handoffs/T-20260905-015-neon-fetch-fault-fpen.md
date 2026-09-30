# T-20260905-015：NEON page-end fetch-fault FPEN/AP 修复交接

```text
task=T-20260905-015
state=accepted
base=0166ede4abab06aff35c06159acdde7570cafa6e
head=ce3df13
merge_sha=738cc142c0dae5269dffe9b8020094cb77ec8094
branch=fix/T-20260905-015-neon-fetch-fault-fpen
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260905-015
sent_at=2026-09-05T12:33:48+08:00
received_at=2026-09-05T12:33:48+08:00
reported_at=2026-09-05T13:14:00+08:00
files=sim/difftest/test_program.py; sim/difftest/check_neon_fetch_fault.py; Makefile; docs/tasks/evidence/T-20260905-015.json
evidence=docs/tasks/evidence/T-20260905-015.json
next=accepted into T-013; keep semantic guard in future P7-2 regressions
```

## 结论

提交 `adc7975` 及其增量修复了 `hard_neon_fetch_fault` 的测试镜像，而没有修改
RTL、QEMU 或参考结果。首条 NEON `MOVI V0.16B,#0xa5` 现在位于：

```text
0x44000028  movz x5,#0x30,lsl#16       (CPACR_EL1.FPEN=0b11)
0x4400002c  msr  cpacr_el1,x5
0x44000030  isb  sy
0x44000034  movi v0.16b,#0xa5           (first NEON)
0x44000038  movz x5,#0xc5,lsl#16
0x4400003c  movk x5,#0x839
0x44000040  msr  sctlr_el1,x5
0x44000044  b    0x44000ffc
0x44000ffc  str  q0,[x10]               (mapped page end)
0x44001000  unmapped                   (following IABT, EC=0x21)
```

`x10=0x44002000`、代码页/handler 页和 handler 保持原值；Q store 数据页的 L3
descriptor 现在是 `0x44002403`（OA=`0x44002000`、AF=1、AP[7:6]=00，即 EL1
可读写、EL0 不可访问）。AArch64 AP 矩阵及仓库 P5a builder 均确认 AP=00 是
EL1-RW；旧值 `0x440024c3` 的 AP=11 是 EL1 只读，会在页末 STR Q 处触发
EC=0x25/ESR=`0x9600004f`/FAR=`0x44002000`，不能用于该 workload。Q store
写入的两条真实 8B tuple 是
`0x44002000/0xa5a5a5a5a5a5a5a5/8` 与
`0x44002008/0xa5a5a5a5a5a5a5a5/8`。镜像仍为固定 90112 bytes、base
`0x44000000`，L3 identity entry `[1]` 仍为零。

## 语义守卫

`sim/difftest/check_neon_fetch_fault.py` 分成三层窄检查：

- 静态检查固定 CPACR/ISB/NEON/branch 编码、页末 Q store、EL1-RW 数据 descriptor
  `0x44002403`、页表、handler 和初始数据布局；旧 `0x440024c3` descriptor 必须
  被拒绝；
- 解析 strict step 的 QEMU 日志与 coordinator 逐提交日志，要求 20 条连续提交、
  页末提交 `next=0x44010200 exc=1`，要求异常绑定页末 PC 的 EC=0x21，并明确拒绝
  任意 EC=0x07；
- 解析 required-profile QEMU trace，要求 CPACR→ISB→MOVI→页末 STR Q 顺序、唯一
  页末 Q store、`next_pc=0x44010200`、`stores=2` 以及两条精确 8B tuple。

QEMU 非锁步 trace 本身不注册 fork discon callback，因此 EC 以 strict step QEMU
日志为权威；trace 只负责可审计的提交顺序和 `mem+mem2`。Makefile 新增
`p7-2-neon-fetch-fault-semantic`（动态 sidecar）与
`p7-2-neon-fetch-fault-semantic-selftest`（不启动模拟器的正/负自测），并让原
`p7-2-neon-fetch-fault` 先执行静态守卫。

## 已完成的轻量验证

`make p7-2-neon-fetch-fault-semantic-selftest` 通过；其 valid synthetic evidence
通过，并拒绝故意把 MOVI 放回 `0x44000028` 的旧镜像、把数据 descriptor 恢复为
`0x440024c3` 的旧只读镜像及 EC=0x07 日志。另有 `py_compile`、registry 一致性、
`git diff --check` 和镜像 layout/AP audit 通过。详细命令、时间、SHA256 和 artifact 路径见
[`docs/tasks/evidence/T-20260905-015.json`](../tasks/evidence/T-20260905-015.json)。

## 集成者重型复验

以下四步必须在集成者合并 SHA 的唯一重型队列串行执行；把 `$PWD` 固定为集成
worktree，并为每个 case 保留独立 socket/log/trace。先生成镜像并准备对应
coordinator：

```sh
mkdir -p build/difftest build/agents/T-20260905-015/l2/base build/agents/T-20260905-015/l2/cache
conda run --no-capture-output -n lcvex python3 -c 'import sys;sys.path.insert(0,"sim/difftest");import test_program;test_program.build_hard_neon_fetch_fault_program("build/difftest/hard_neon_fetch_fault.bin")'
```

分别执行 base/cache strict（必须保留 `PROGRESS_EVERY=1`）：

```sh
systemd-run --user --wait --collect --unit=lcvex-t015-neon-base -p WorkingDirectory=$PWD -p MemoryMax=16G -p MemorySwapMax=0 -p CPUQuota=50% -- env FP_NEON=required IMAGE=$PWD/build/difftest/hard_neon_fetch_fault.bin MAX_INSNS=20 PROGRESS_EVERY=1 COORD=$PWD/build/verilator_lockstep/lockstep_coordinator PLUGIN=$PWD/qemu/plugins/lcvex_difftest.so QEMU_BIN=/home/chiro/projects/mycpu/qemu/build/qemu-system-aarch64 SOCK=$PWD/build/agents/T-20260905-015/l2/base/step.sock DUMP=$PWD/build/agents/T-20260905-015/l2/base/fail.txt COORD_LOG=$PWD/build/agents/T-20260905-015/l2/base/coord.log QEMU_LOG=$PWD/build/agents/T-20260905-015/l2/base/qemu.log bash sim/difftest/run_lockstep_step.sh > $PWD/build/agents/T-20260905-015/l2/base/run.log 2>&1

systemd-run --user --wait --collect --unit=lcvex-t015-neon-cache -p WorkingDirectory=$PWD -p MemoryMax=16G -p MemorySwapMax=0 -p CPUQuota=50% -- env FP_NEON=required IMAGE=$PWD/build/difftest/hard_neon_fetch_fault.bin MAX_INSNS=20 PROGRESS_EVERY=1 COORD=$PWD/build/verilator_lockstep_l1dl2/lockstep_coordinator PLUGIN=$PWD/qemu/plugins/lcvex_difftest.so QEMU_BIN=/home/chiro/projects/mycpu/qemu/build/qemu-system-aarch64 SOCK=$PWD/build/agents/T-20260905-015/l2/cache/step.sock DUMP=$PWD/build/agents/T-20260905-015/l2/cache/fail.txt COORD_LOG=$PWD/build/agents/T-20260905-015/l2/cache/coord.log QEMU_LOG=$PWD/build/agents/T-20260905-015/l2/cache/qemu.log bash sim/difftest/run_lockstep_step.sh > $PWD/build/agents/T-20260905-015/l2/cache/run.log 2>&1
```

每个 strict case 通过后，使用独立的 read-only QEMU trace sidecar：

```sh
systemd-run --user --wait --collect --unit=lcvex-t015-neon-guard-base -p WorkingDirectory=$PWD -p MemoryMax=16G -p MemorySwapMax=0 -p CPUQuota=50% -- conda run --no-capture-output -n lcvex python3 sim/difftest/check_neon_fetch_fault.py --image build/difftest/hard_neon_fetch_fault.bin --trace build/agents/T-20260905-015/l2/base/qemu.trace --strict-log build/agents/T-20260905-015/l2/base/qemu.log --coord-log build/agents/T-20260905-015/l2/base/coord.log --runner-log build/agents/T-20260905-015/l2/base/run.log --qemu-bin /home/chiro/projects/mycpu/qemu/build/qemu-system-aarch64 --plugin $PWD/qemu/plugins/lcvex_difftest.so --run-qemu --qemu-log build/agents/T-20260905-015/l2/base/trace-qemu.log

systemd-run --user --wait --collect --unit=lcvex-t015-neon-guard-cache -p WorkingDirectory=$PWD -p MemoryMax=16G -p MemorySwapMax=0 -p CPUQuota=50% -- conda run --no-capture-output -n lcvex python3 sim/difftest/check_neon_fetch_fault.py --image build/difftest/hard_neon_fetch_fault.bin --trace build/agents/T-20260905-015/l2/cache/qemu.trace --strict-log build/agents/T-20260905-015/l2/cache/qemu.log --coord-log build/agents/T-20260905-015/l2/cache/coord.log --runner-log build/agents/T-20260905-015/l2/cache/run.log --qemu-bin /home/chiro/projects/mycpu/qemu/build/qemu-system-aarch64 --plugin $PWD/qemu/plugins/lcvex_difftest.so --run-qemu --qemu-log build/agents/T-20260905-015/l2/cache/trace-qemu.log
```

最后复跑 `p7-2-neon-int`：

```sh
systemd-run --user --wait --collect --unit=lcvex-t015-neon-int -p WorkingDirectory=$PWD -p MemoryMax=16G -p MemorySwapMax=0 -p CPUQuota=50% -- env VERILATOR_JOBS=1 make p7-2-neon-int
```

上述 strict base/cache 都必须是 20/20，两个 semantic sidecar 都必须输出
`SEMANTIC_GUARD_PASS`，并且 `p7-2-neon-int` 回归通过后，集成者才可在 evidence
中补 `merge_sha`。本 owner 未执行这些重型命令，也未进行 assembler、Quartus、
JTAG、烧写、上电或板测。

## 风险与边界

- 守卫绑定当前固定测试镜像布局；若将来有意改变 page table、handler、Q 数据或
  AP 权限，必须同步更新任务并重新审计，而不能放宽守卫。
- `docs/tasks/active/T-20260905-015.json`、`TASKS.md`、`PROJECT_STATUS.md` 和
  `ROADMAP.md` 由集成者更新；owner 只提供本 handoff/evidence。
- physical/STA 与 R17 timing 结论不在本任务范围内。
