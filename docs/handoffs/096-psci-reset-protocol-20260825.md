# 096 PSCI SYSTEM_RESET/SYSTEM_OFF 差分协议终止（2026-08-25）

前置：handoff 094（HVC#0 分歧根因：panic → PSCI SYSTEM_RESET）
分支：`feature/p6-system-reg-shim`

## 结论

访客请求整机复位/关机（PSCI SYSTEM_RESET/SYSTEM_OFF）在 QEMU 侧执行
machine reset/shutdown，架构状态不再连续（GPR 清零、PC 回复位向量），
与 RTL 的 NOT_SUPPORTED 返回必然分歧。本阶段把它定义为**协议级窗口终止
事件**：差分窗口在“访客复位/关机”处结束，退出码 3（区别于 FAIL=1、
参数错误=2），绝不静默 PASS——qemu.log 中复位前的原因仍需人工确认。

## 实现

### 协议头（qemu/plugins/lcvex_protocol.h）

- `lcvex_discon.kind=4`（`LCVEX_DISCON_GUEST_RESET`）：
  访客请求整机复位/关机；`pc`=HVC 地址，`data`=PSCI 函数号。

### QEMU 插件（qemu/plugins/lcvex_difftest.c）

`vcpu_discon` 的 step 模式 HOSTCALL 分支新增分类：用 `last_pre_state.x[0]`
（HVC 执行前状态）识别：

- `0x84000008` / `0xC4000008`：PSCI SYSTEM_OFF；
- `0x84000009` / `0xC4000009`：PSCI SYSTEM_RESET。

命中时发送 `LCVEX_MSG_DISCON` kind=4 并 `sync_stopped`；其余
PSCI/semihosting hostcall 保持原有“延迟到普通 COMMIT”路径。

### 协调器（sim/difftest/lockstep_coordinator.cc）

`LCVEX_MSG_DISCON` 且 kind==4 时：打印“访客请求复位/关机（PSCI
fn=0x..）at pc=.. seq=..”，写诊断文件（note 标明窗口终止，含
DISCON/最近窗口），返回退出码 3。

### Runner（run_lockstep_step.sh / run_lockstep_resume.sh）

协调器退出码 3 → 打印“窗口以访客复位/关机终止（非 FAIL，需人工确认
qemu.log 中复位前的原因）”并退出 3，不再走泛化“失败明细”路径。

## 验证

```sh
python3 -c 'import sys; sys.path.insert(0, "sim/difftest");
import test_program; test_program.build_hard_psci_reset_program(
"build/difftest/hard_psci_reset.bin")'
IMAGE=build/difftest/hard_psci_reset.bin MAX_INSNS=10 \
  COORD=build/verilator_lockstep/lockstep_coordinator \
  bash sim/difftest/run_lockstep_step.sh   # 期望退出码 3
```

- `hard_psci_reset`：seq=0/1 正常通过，seq=3 的 HVC 触发
  `fn=0x84000009` 检测，协调器退出 3，fail.txt 记录
  `DISCON kind=4 from_pc=.. to_pc=0x84000009`；
- `hard_psci`（正常 PSCI hostcall 返回路径）：base/cache 两配置
  `run_m2_4b.sh --only hard_psci` 全绿，确认无回归。

## 约束与后续

- 严格差分原则不变：不跳过 HVC、不忽略寄存器差异；只在“访客请求整机
  复位/关机”时终止窗口，且每次都需要人工确认 qemu.log 中复位前的原因。
- RTL 对 SYSTEM_RESET/SYSTEM_OFF 仍返回 NOT_SUPPORTED，不参与比较；
  `lcvex_decode.sv` 注释已同步说明。
- 真实复位语义（两侧同时回复位向量继续差分）留待未来需要时实现。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,200p' docs/handoffs/096-psci-reset-protocol-20260825.md
cat build/tmp/psci-reset-test/fail.txt
```
