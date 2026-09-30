# LCVEX 交接文档 049：PSCI HVC 最小闭环

日期：2026-08-24（Asia/Shanghai）

## 1. 触发与取证

Linux 锁步在 `seq=14854103` 首次遇到 QEMU `DISCON kind=3`。QEMU 日志
显示 PSCI 正在探测 conduit；独立 gzip 尾迹
`build/difftest/failures/linux-psci-tail-20260824.trace.gz` 进一步确认：

- 运行时 alternatives 已把 `0xffff8000800a73a0` 修改为 `HVC #0`
  （编码 `0xd4000002`），而非 vmlinux 静态反汇编中的 `BL`；
- HVC 前 `x0=0x84000000`（`PSCI_VERSION`），QEMU 返回 `x0=0x10001`，
  `next_pc=pc+4`；
- 失败地址 `0xffff8000800a73a4` 是 HVC 返回后的下一条指令，属于
  hostcall 回调的 PC 语义，不是 RTL 状态分歧。

独立 trace 模式在长跑时 RSS 达到约 1.2 GiB，超过资源约束，已停止；尾迹
文件保留为压缩诊断资产。后续长跑继续使用 `mode=step` 锁步（QEMU RSS
约 153 MiB、协调器约 138 MiB）。

## 2. 实现

- `qemu/plugins/lcvex_difftest.c`：step 模式收到 `HOSTCALL` 时不再发送
  `DISCON`，而是保留 pending 指令；下一条指令回调观察 QEMU 更新后的
  返回寄存器/PC，并把 HVC/SMC/semihosting 作为普通 `COMMIT` 完成。
  IRQ/FIQ 仍保持 `DISCON` 失败语义；无 pending 的 hostcall 仍报错。
- `rtl/lcvex_decode.sv`：识别 `HVC/SMC #imm16`，按 QEMU virt HVC PSCI
  conduit 直接写回 `x0`、顺序 `next_pc=pc+4`。已实现：
  `PSCI_VERSION=1.1`、`PSCI_FEATURES`（已支持函数返回 0）、
  `MIGRATE_INFO_TYPE=2`（QEMU 无 Trusted OS）、单核 `AFFINITY_INFO`、
  单核 `CPU_ON`；未知
  函数返回 `-1`。SYSTEM_OFF/RESET、CPU_OFF/SUSPEND 的停机/电源状态
  尚未实现。
- `sim/difftest/a64.py`、`check_encoders.py`：加入 HVC/SMC 编码器和交叉
  汇编自检；`test_program.py` 新增 `hard_psci` 定向镜像，并纳入
  `run_m2_4b.sh` 的可筛选测试列表。

## 3. 验证

```text
make compile                                      PASS
python3 sim/difftest/check_encoders.py            PASS（78 条）
make lockstep-build                               PASS
hard_psci，mode=step，MAX_INSNS=29                PASS（base/cache）
```

`hard_psci` 覆盖 VERSION、MIGRATE_INFO_TYPE、FEATURES(VERSION)、
AFFINITY_INFO(MPIDR=0)、CPU_ON（CPU0 已上电和无效 MPIDR）；base/cache
两配置均通过。

Linux 重新锁步在 `seq=14867468` 发现 `MIGRATE_INFO_TYPE` 返回值缺口：QEMU
返回 2，旧 RTL 返回 0；已修正并由上述定向测试覆盖。修正后的 Linux 长跑
尚未重跑到该位置。

## 4. 资源与文件

- 当前无后台 QEMU/Verilator 进程；独立 trace 长跑已停止。
- 大 trace 不进入 git；该尾迹仅用于本地失败诊断，正式 CI 仍需 release
  资产与总大小限制（见 handoff 044/048）。

## 5. 下一步

1. 运行 `run_m2_4b.sh --only hard_psci`（base/cache）并执行 Gate D 相关
   快速回归。
2. 重新构建 `lockstep-build-kernel`，以 `taskset -c 0`、
   `PROGRESS_EVERY=100000` 将 Linux 锁步推进到 15M 以上，定位下一缺口。
3. 若 Linux 进入更深 PSCI 调用，按 QEMU `psci.c` 逐个补齐返回/停机语义，
   不把 SYSTEM_OFF/RESET 等不可返回调用误当作普通提交。
4. 差分 checkpoint 按 handoff 044/050 独立阶段推进；当前仅有全量 gzip
   基线，不能将旧 `.gz` 当作差分链恢复输入。
