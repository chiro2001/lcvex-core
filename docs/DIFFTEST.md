# QEMU 逐指令差分测试

## 目标

每条 RTL 指令在 COMMIT 阶段产生的架构结果，都与 QEMU 执行同一条 A64
指令后的结果比较。QEMU 是参考模型，RTL 是被测实现。

## 版本策略

- 使用最新稳定 release，不跟踪 git master。
- 固定版本记录在 `qemu/VERSION`（git tag + commit hash）。
- QEMU 源码克隆在 `../qemu`，不使用 tarball。
- release 升级必须单独建分支并重新跑完整差分回归。

当前 `qemu/VERSION` 固定的是 QEMU 11.1.0 release；其发布信息见
[QEMU 11.1.0 release note](https://www.qemu.org/2026/08/11/qemu-11-1-0/)。
以后“最新 release”指项目开始该阶段时选定并记录的最新稳定版本，不指向
随时变化的 `master`。

## P1 实现方式：TCG 插件

P1 的"单指令执行 + 状态导出 + 内存写记录"用官方 TCG 插件实现，源码在
`qemu/plugins/lcvex_difftest.c`，**不修改 QEMU 源码**：

- 每条 guest 指令注册执行回调（`QEMU_PLUGIN_CB_R_REGS`，回调在指令
  执行前触发，此时状态为上一条指令执行后的状态，与 RTL 的 COMMIT 语义
  对齐）。
- 寄存器通过 `qemu_plugin_get_registers()` / `qemu_plugin_read_register()`
  读取（x0~x30、sp、cpsr；NZCV 取 cpsr bit31:28）。
- 内存写通过 `qemu_plugin_register_vcpu_mem_cb` +
  `qemu_plugin_mem_get_value()` 记录地址、数据和宽度。
- `next_pc` 直接取当前回调指令的地址，不读 `env->pc`（TCG 在 TB 内不
  保证逐指令更新 `env->pc`）。

选择插件而不是 fork 钩子的原因：插件 API 已经覆盖 P1 全部需求，release
升级无需重打补丁。插件 API 没有精确的 post-instruction/异常退休回调，P4
（同步异常）起再改用 fork 内钩子，补丁按 `qemu/patches/` 流程管理。

## P2 实时锁步方式

当前插件首先用于批量 trace。标量流水线开始后，增加 `mode=sync`：插件通过
Unix `SOCK_SEQPACKET` 与运行 Verilator DUT 的 C++ 协调器通信。

```text
QEMU 插件：PRE(N) → 等待 GO → 执行 N
QEMU 插件：COMMIT(N) → 等待 ACK → PRE(N+1)
协调器：收到 PRE(N) → DUT 执行 N → 比较并保存 → 发送 GO
协调器：收到 COMMIT(N) → 与 DUT commit 比较 → 发送 ACK
```

插件协议、Verilator wrapper、超时、异常处理和里程碑见
[DIFFTEST_QEMU_PLAN.md](DIFFTEST_QEMU_PLAN.md)。

## QEMU 构建

```sh
cd ../qemu
./configure --target-list=aarch64-softmmu --enable-plugins \
    --disable-werror --disable-docs
make -j$(nproc)
```

## 差分插件与测试入口

```sh
make -C qemu/plugins    # 编译 lcvex_difftest.so
make difftest           # 生成程序、跑 QEMU、解析 trace、参考模型比较、确定性检查
```

`make difftest` 会：

1. 用 `sim/difftest/a64.py` 生成裸机测试程序（ADD/SUB/ADDS/MOVZ/STR/
   NOP/B）。
2. 以 `-machine virt -cpu max -accel tcg,thread=single` 启动 QEMU，
   用 `-device loader` 加载程序并设置初始 PC。
3. 插件输出 `lcvex-qemu-trace v1` 格式 trace（`limit=8` 限制行数，
   避免死循环无限输出）。
4. `sim/difftest/state_model.py` 参考模型逐条重放并比较全部寄存器、
   SP、NZCV、next_pc 和内存写。
5. 连续运行两次，比较输出是否完全一致（确定性验收）。

## Trace 格式（lcvex-qemu-trace v1）

首行为初始状态，后续每行为一条指令提交后的完整状态：

```text
# lcvex-qemu-trace v1
init pc=0x0000000044000000 x0=0x... ... x30=0x... sp=0x... next_pc=0x... nzcv=0x4 stores=0
commit pc=0x0000000044000000 insn=0x91000400 disas="add x0, x0, #1" x0=0x... ... stores=1 s0_addr=0x... s0_data=0x... s0_size=8
```

字段约定：

| 字段 | 说明 |
| --- | --- |
| `pc` | 本条指令地址 |
| `insn` | 指令编码（`%08x`） |
| `disas` | 反汇编文本 |
| `x0`~`x30` | 提交后通用寄存器 |
| `sp` | 提交后 SP |
| `next_pc` | 下一条指令地址 |
| `nzcv` | NZCV（bit3=N bit2=Z bit1=C bit0=V） |
| `stores` | 本条指令内存写次数 |
| `s<i>_addr` / `s<i>_data` / `s<i>_size` | 第 i 次写的地址、数据、字节数 |

## 与 RTL 提交包的对应

`docs/COMMIT_PACKET.md` 定义 RTL 侧提交包（写回事件）；QEMU 侧导出的是
完整状态快照。Cocotb 差分比较器（P2 起实现）维护一份寄存器状态：

1. 用 `init` 行初始化 RTL 与参考状态。
2. 每条 RTL commit 提交后，用提交包更新参考状态。
3. 与对应 `commit` 行比较全部寄存器、SP、NZCV、next_pc 和内存写。

## P2 RTL 差分流程

```sh
make difftest     # P1（QEMU 确定性）+ P2（RTL↔QEMU 差分）
```

流程：

1. `sim/difftest/test_program.py` 用极简汇编器（`a64.py`）生成 P2 程序。
2. QEMU 生成 `build/difftest/rtl.trace`。
3. Cocotb（`sim/cocotb/test_lcvex_core.py`）复位期间把程序写入
   1-cycle SRAM，释放复位后收集提交包，逐条与 QEMU 比较。

比较内容：PC、next_pc、x0~x30、SP、NZCV 与内存写（地址/数据/宽度）。
当前 P2 样例覆盖 33 条指令，全部与 QEMU 一致。

## P2 实时锁步（Q2/Q3 里程碑）

按 `docs/DIFFTEST_QEMU_PLAN.md` 的设计实现了实时锁步：

```sh
make lockstep
```

- 二进制协议：`qemu/plugins/lcvex_protocol.h`（Unix `SOCK_SEQPACKET`，
  HELLO/CONFIG/INIT/PRE/GO/COMMIT/ACK/STOP）。
- QEMU 插件 `mode=sync`：每个指令边界与协调器同步（PRE 等 GO，
  COMMIT 等 ACK），不做批量 trace。
- 协调器：`sim/difftest/lockstep_coordinator.cc`（Verilator DUT 封装 +
  时钟推进 + shadow state 比较 + 失败诊断），由
  `sim/difftest/run_lockstep.sh` 编排启动。
- 验收：P2 程序 36 条指令（含循环第二轮）逐条与 QEMU 一致。

锁步与批量 trace 模式并存：trace 用于快速回归与失败样本，锁步用于
逐指令实时比较。Cocotb 仍负责 RTL 功能测试与批量差分，锁步热路径
由 C++ 协调器驱动（同一个 DUT 不同时由两者驱动时钟）。

## 随机标量回归（Q4 里程碑）

固定种子随机程序 + 批量 trace + Cocotb 提交比较，用于扩大标量指令
覆盖并暴露定向样例未覆盖的组合（Q4 验收：10 万条以上无不可重放
mismatch）。

```sh
make difftest-random          # 默认 seed=1 length=2000
make difftest-random SEED=7 LENGTH=10000
make difftest-random-big      # seed=1 length=100000
```

生成器 `sim/difftest/random_program.py` 的约束：

- 只生成 RTL 已支持指令（见 `docs/ISA_SCOPE.md`）。
- 分支只向前且目标必须是程序内指令边界，QEMU 与 RTL 动态指令流一致，
  trace 行数与 RTL 提交数严格对齐；程序末尾追加自循环 `b .` 收尾。
- 访存基址固定 x20=0x44080000，数据区避开程序区，禁用自修改代码。
- 32 位宽立即数只允许 hw=0/1；W 形式移位寄存器运算移位量必须 < 32
  （其余编码为保留 UNDEFINED，由解码器拒绝）。
- 随机程序写 `build/difftest/random.bin`，Cocotb 从镜像文件读入 SRAM。

### MMIO 差分（P6）

- QEMU 插件对 MMIO store 照常记账（vcpu_mem 回调），MMIO load 经 GPR
  写回比较；RTL 侧 MMIO 窗口由 `lcvex_mem_router` 路由到 `lcvex_pl011`；
- 参考行为先用 `qemu_probe.py` 探针取证（PL011 复位值、TX 后 RIS、
  LBE 回环 FR/DR、FEN FIFO、字节/8B 访问布局），再在 RTL 复刻；
- 注意 a64.py 的 `ldr/str` imm12 按 8 字节缩放、`ldrw/strw` 按 4 字节
  缩放、`ldrh/strh` 按 2 字节缩放，探针/定向程序传字节偏移会读错
  寄存器（实证教训，handoff 036）。

比较内容与 P2 批量差分一致（PC、next_pc、x0~x30、SP、NZCV、内存写）。
当前 seed=1 length=100000（100002 条提交）与 QEMU 完全一致。

## P3 流水线 hazard 差分（D2）

P2 的 FSM 核心已重构为 5 级顺序流水线（IF→ID→EX→MEM→WB/COMMIT）：
EX/MEM/WB 三级写回前递到 ID、load-use 与单端口 SRAM 争用 stall、
分支在 ID 解析并冲刷 IF/ID。定向 hazard 程序与随机回归共同覆盖
forwarding、stall、flush：

```sh
make difftest-hazard      # 定向 34 条（ALU/load-use/分支/NZCV/MOVK/乘除）
make difftest-random-big  # 10 万条随机（含乘除）无不可重放失败
```

`make lockstep` 与 `make lockstep-q5` 在流水线下继续通过，提交协议不变。

多周期乘除（P3 Gate B）：`rtl/lcvex_muldiv.sv` 移位累加乘法 + 恢复余数
除法（64 位 64 周期、32 位 32 周期），EX 忙时冻结流水线，完成拍组合
输出结果并与取指推进对齐；随机回归约 5% 指令为 MUL/UDIV/SDIV（含 W 形式
和除零），与 QEMU 完全一致。

## 锁步停止与 discon 处理（Q5 里程碑）

插件在 `mode=sync` 下注册 vcpu discontinuity 回调：异常/中断/host call
造成 PC discontinuity 时上报 `DISCON` 并停止参与协议（P2 阶段视为失败），
QEMU 退出时上报 `EXIT`；收到协调器 `STOP` 后不再阻塞 socket。协调器
严格校验消息 `seq`，对 DISCON/EXIT/EOF/超时都快速失败并写入诊断文件
（最近 32 条提交窗口、完整寄存器、内存写）。

```sh
make lockstep-q5
```

覆盖四个场景：正常锁步 36 条、提前 STOP（`MAX_INSNS=8`）快速回收、
store 到未映射地址触发数据 abort 后上报 DISCON、运行中强杀 QEMU 后
检测连接中断。`run_lockstep.sh` 支持 `EXPECT_FAIL`/`KILL_QEMU_AFTER`
环境变量；QEMU 在协调器结束后立即回收，不再依赖外部 20 秒超时。

## 差分 checkpoint（P6）

`DIFF_CKPT=1` 时，协调器在已比较的 COMMIT 与 ACK 之间发送 `CKPT_REQ`，
QEMU fork 保存设备 VMState，并分别压缩 RAM 页链、架构摘要、系统寄存器、
Generic Timer、单核 GICv2 和 C++ MMIO fabric sidecar。manifest 的新格式为：

```text
kind  seq  parent  ram_bytes  pages  ram.gz  dev.gz  arch.gz  sys.gz  timer.gz  gic.gz  mmio.gz
```

Timer sidecar 的 `cntpct` 是下一条 guest 指令可见值；DUT 注入时写入
`cntpct_r=cntpct-1`，因为 RTL 的 EX 级 MRS 会加一。读取和边界 smoke：

```sh
python3 sim/difftest/checkpoint.py read-timer --chain <dir> --seq <n>
python3 sim/difftest/checkpoint.py read-gic --chain <dir> --seq <n>
python3 sim/difftest/checkpoint.py read-mmio --chain <dir> --seq <n>
make checkpoint-timer-smoke
make checkpoint-gic-smoke
make checkpoint-mmio-smoke
```

从 QEMU `-incoming` 做联合恢复时，插件在第一条指令回调前读取未压缩的
timer sidecar，并通过 `LCVEX_TIMER_RESTORE_PATH` 校正
`QEMU_CLOCK_VIRTUAL` 基准；普通运行不设置该变量。统一脚本还会比较 QEMU
和 DUT 恢复后的下一条 `CNTVCT`：

```sh
bash sim/difftest/checkpoint_timer_smoke.sh
```

旧的 7/8/9/10 列 manifest 仍可读取，但没有 timer/GIC sidecar 的旧链不能宣称
对应外设状态已恢复；同理，11 列链没有 C++ MMIO sidecar 时只能恢复 fabric
reset，不能宣称 PL031/future C device 状态已恢复。GIC sidecar 只截取 RTL
支持的前 96 个 IRQ；QEMU 超出
范围存在 live 状态时保存会拒绝。大 RAM backend 只在运行目录中使用，测试结束默认删除，
不应提交到 git 或放入 `/tmp` 长期保留。项目新增的临时文件、trace 反汇编
中间文件和探针 socket 默认写入 `build/tmp`（可用环境变量 `LCVEX_TMP_DIR`
或脚本参数覆盖）；`/tmp` 仅保留历史输入兼容路径，不作为新任务的输出目录。
`KERNEL=1` 且 `DIFF_CKPT=1` 时，FDT 必须在与实际 QEMU 完全相同的
`-machine` 配置（包含 `memory-backend`）下导出；runner 将其写入独立
checkpoint 链，不能复用普通 virt 配置导出的 DTB。

### 续跑 checkpoint 的 parent/global provenance

`run_lockstep_resume.sh` 设置 `CKPT_EVERY>0` 时，输出目录必须是新的空目录。
脚本先校验 parent 的 Image/DTB/INITRD、QEMU、`qemu/VERSION` 和运行上下文，
再写入 `manifest.json` 的 `pending` 状态；协调器/sidecar 内部继续使用本窗口
的 local seq，不改写二进制 header。成功后才写 `manifest_tsv_sha256`、artifact
摘要、`chain` 端点并原子标记 `status/state=complete`；失败现场不会被
`read_manifest` 当作可恢复链。

若 parent 保存点为 `P`，child 的全局映射为：

```text
global_seq_offset = P_global + 1
global_seq        = global_seq_offset + local_seq
```

manifest context 同时记录 parent manifest SHA256、parent local/global seq、
窗口半开端点和 artifact 的闭区间端点。无完整 manifest provenance 的旧链仍可
按历史格式读取，但不能作为新的全局续跑 parent。低资源 fixture 入口：

```sh
make checkpoint-resume-manifest-smoke
```

含 C++ fabric 的锁步 runner 统一增加
`-rtc base=2000-01-01T00:00:00,clock=vm`。这使 PL031 与 `-icount shift=0`
共享确定性虚拟时间；任何绕过 runner 的定向 QEMU 启动也必须保留该参数，否则
读取 RTC 数据寄存器会重新引入宿主时间差异。

### 等待指令时间同步（P6）

`WFI/WFE/WFIT/WFET` 的 QEMU helper 有两条不同路径：如果
`cpu_has_work()` 为真会立即返回；只有实际 halt 才会经历虚拟时钟跳变。插件
在真实 idle callback 后发送无载荷 `WAIT`，在下一条 PRE 前发送
`WAIT_RESUME{cntvct}`。协调器据此：

- 无 `WAIT` 的普通 PRE：释放 DUT 的非架构 idle，并抵消 wake 同拍的一个
  RTL 计数增量；
- 带 `WAIT_RESUME` 的普通 PRE：用 QEMU 当前 `CNTVCT` 重设 DUT 计时基准，
  再释放 idle；
- `ASYNC`：保持既有的真实 IRQ 唤醒提交比较。

该同步不再通过 coordinator 直接写 Verilator 内部变量，而是经
`lcvex_soc_tb`/`lcvex_core` 的验证专用单拍端口
`difftest_wait_release`、`difftest_wait_cntvct_valid`、
`difftest_wait_cntvct` 进入核心。核心在时钟边界锁存早到的 release，并在
真正 wake 时更新非架构 `cntpct_r`；独立 SV/Cocotb、microbench 和未来 FPGA
顶层必须把这些端口固定为 0。

普通指令仍受 `--max-cycles-per-insn=1000` 约束；等待恢复单独使用
`--max-wait-cycles`（runner 环境变量 `MAX_WAIT_CYCLES`，默认 1,000,000），
防止 WFIT 的合法长虚拟 timeout 被误报为流水线 hang。

### Checkpoint 系统状态注入端口（P6）

QEMU checkpoint 恢复不能由 C++ 协调器直接改写 Verilator 的 core 层级
寄存器：这会绕过时钟边界，也使 RTL 的恢复行为无法独立验证。恢复路径使用
`lcvex_soc_tb`/`lcvex_core` 的验证专用输入：

- `difftest_restore_sys_valid`：只在 reset 释放后的恢复边界有效一个时钟；
- `difftest_restore_*`：PC、PSTATE（EL/SP/NZCV/DAIF/PAN/DIT）、EL1
  系统寄存器、线程指针、PAR、SVE/SME 控制寄存器、CSSELR，以及 Generic
  Timer 的 CVAL/CTL/计数基准；
- core 在该时钟沿接受状态并清空所有可能由 reset 释放同拍生成的取指/提交
  痕迹；下一拍从 sidecar 的 `next_pc` 正常取指。

该端口仅用于 checkpoint 恢复，普通 PRE/COMMIT 锁步**绝不**回灌 QEMU
架构状态；正常执行中仍由 RTL 自己更新并被严格比较。SV/Cocotb、microbench
和未来 FPGA 顶层必须把该端口固定为 0。

`LCVXSYS3` 在 v2 基础上补齐 `PMUSERENR_EL0`、`TCR2_EL1`、`PIRE0_EL1`
和 exclusive monitor（地址/低值/高值；地址 `~0` 表示无效）。`checkpoint-sys-v3-
smoke` 在 `LDXR` 后保存，恢复后读回三项系统状态并要求 `STXR` 成功，故不是
只检查 sidecar 字节而是 QEMU/DUT 联合恢复闭环。协调器仍可读取旧
`LCVXSYS1/2`：缺失的新增 sysreg 取 reset 值，exclusive monitor 强制无效，
不得把旧链误解释为含 monitor 的恢复点。

### 异步 IRQ exception note（P6）

IRQ 的架构结果仍须由 QEMU 与 RTL 各自产生并严格比较，不能因 QEMU 已跳到
异常向量就容忍缺失的 `exc_valid`。QEMU fork 在异常入口记录单 vCPU 的 pending
note；plugin 先走正常 discontinuity 路径，若在下一条普通指令回调才观察到
IRQ 向量，则在生成前一条 COMMIT 前再消费该 note。note 的消费不能依赖
`current_cpu`：plugin 回调时该 TLS 上下文可能已清空；固定单 vCPU 模式改为
校验 `qemu_get_cpu(0)` 存在。这样 `exc_valid=1/exc_code=0x40` 与 RTL 的
EXC_IRQ packet 仍一一比较，不引入宽松匹配。

## P7 FP/NEON 协议冻结（P7-0 协议切片已实现，QEMU replay 待集成）

P7 保持 header V1 和 scalar PRE/COMMIT/seq 字节布局。只有 plugin
`fp=required`、coordinator `--fp-neon=required`、`HELLO.api_version==2` 与
`CONFIG.state_mask` bit31 全部成立，才按
`INIT->FP_INIT`、`COMMIT->FP_COMMIT->[CKPT_REQ/READY]*->ACK` 发送 full-init+
无损 state-delta；WAIT/WAIT_RESUME/ASYNC 保持 V1，ASYNC 不等待 FP frame。任一
required peer/capability/preflight 不匹配在 INIT 前明确拒绝。Gate-F 使用 Cortex-A76；
max z-low128 adapter 仅可跑高 Z 半始终为零、无 SVE、无 checkpoint 的兼容 smoke。
P7 trace 为 v2：一次 full sync + 每条 delta，tail/checkpoint 点重发 full sync；
NaN/FPSR 均 raw-bit，DN=0 仅按逐指令有限允许集合/掩码，不使用 epsilon。

checkpoint 使用带 seq 的 552B 独立 `LCVXFP01` gzip sidecar 与 manifest 第13列，
原 sys sidecar/QEMU incoming device state 不变；fp raw/gzip/TSV 行均原子发布，
失败清理本行 artifact。P7 初期限制两段 Q store，RTL ABI 已预留8段；结构化多
寄存器访存仍不在范围。完整 wire/sidecar/恢复/验收定义见
[P7_FP_NEON_PROTOCOL.md](P7_FP_NEON_PROTOCOL.md)。

T-20260827-051 的协议切片已在仓库侧落实严格 datagram 长度/seq 校验、
`FP_INIT`/`FP_COMMIT` 配对、普通提交的 FP frame 状态边界、以及 `WAIT`/
`WAIT_RESUME`/`ASYNC` 不携带 FP frame 的 coordinator/plugin 路径；批量 trace
增加 V2 FP frame 校验，checkpoint reader 接受并校验 13 列 `LCVXFP01`。QEMU
`qemu_lcvex_difftest_read_fp_state()` 的 0012 patch replay、真实 A76 lockstep
和顶层 FP restore 端口仍须由集成者串行完成，不能据此宣称 L2/Gate-F 已通过。

## 已知限制（P1）

- 不导出精确异常退休状态（插件 API 不保证 post-instruction/异常回调），P4
  改用 fork 钩子。
- 每条指令最多记录 8 次内存写，超出丢弃（LDP/STP 等不会触发）。
- 单 vCPU、TCG 单线程；guest 不得使能异步中断。
- 最后一条指令的状态在下一指令回调时导出，测试程序以死循环收尾即可。
- 状态读取依赖 TCG 的 global 同步语义：读回的值以回调时刻为准，
  已验证与参考模型一致。
- QEMU virt 机器复位状态下非对齐访存会触发对齐异常，P2 测试程序
  使用对齐地址；非对齐支持与异常语义在 P4 处理。

官方文档说明普通指令回调发生在指令执行前，不能保证指令完成；成功访存的
内存回调发生在访问后，faulting access 不会作为成功访存回调出现。因此 P1
只覆盖无异常、无中断、无 MMIO 的标量指令。不能把当前插件的“下一条指令前
回调”机制扩展解释为完整的 QEMU 架构退休接口。

## 确定性要求

- 早期关闭 MMU、Cache 和异步中断。
- 不访问有时间变化或外部副作用的设备。
- 所有内存内容由测试程序明确初始化。
- 固定随机种子。
- 禁止未记录的 DMA、定时器和异步事件。

## 差分测试分层

| 层级 | 内容 |
| --- | --- |
| D0 | 单条整数指令 |
| D1 | 无分支短指令序列 |
| D2 | 分支、调用、返回和流水线 hazard |
| D3 | Load/Store 和内存副作用 |
| D4 | 同步异常和 `ERET` |
| D5 | MMU、TLB、Cache |
| D6 | FP/NEON |
| D7 | SVE256 |

## P1 验收状态

已完成：QEMU 可逐条执行 A64 指令并导出完整状态（ADD/SUB/ADDS/MOVZ/
STR/NOP/B 端到端样例通过参考模型比较），两次运行输出逐字节一致。

P2 状态：RTL 标量核心（寄存器堆/ALU/解码器/1-cycle SRAM）已实现，
定向 33 条指令与固定种子随机回归（seed 1~5 各 2000 条、seed 1 十万条）
的 RTL 提交包均与 QEMU 逐寄存器一致。

## 外部参考

- [QEMU TCG Plugins 官方文档](https://www.qemu.org/docs/master/devel/tcg-plugins.html)
- [QEMU `execlog` 插件](https://github.com/qemu/qemu/blob/master/contrib/plugins/execlog.c)
- [OpenXiangShan DiffTest](https://github.com/OpenXiangShan/difftest)
- [XiangShan Function Verification](https://tutorial.xiangshan.cc/asplos25/FunctionVerification/)
