# QEMU–Verilator 锁步差分测试详细计划

本文档是在现有 P1 批量 trace 插件基础上，设计可与 Verilator 实时同步的
逐指令 difftest。目标不是让 QEMU 和 RTL 在同一个时钟周期运行，而是让两边
每次只推进一条架构指令，并在每个提交点比较架构状态。

## 1. 在线资料和结论

本设计参考了以下资料：

- [QEMU TCG Plugins 官方文档](https://www.qemu.org/docs/master/devel/tcg-plugins.html)
- [QEMU TCG plugin API 头文件](https://qemu.googlesource.com/qemu/+/master/include/qemu/qemu-plugin.h)
- [QEMU `execlog` 插件示例](https://github.com/qemu/qemu/blob/master/contrib/plugins/execlog.c)
- [OpenXiangShan DiffTest](https://github.com/OpenXiangShan/difftest)
- [XiangShan Function Verification 教程](https://tutorial.xiangshan.cc/asplos25/FunctionVerification/)

可迁移到 LCVEX 的核心经验是：DUT 只在指令提交时产生 commit 包，参考模型
执行相同指令，比较提交后的架构状态；同时保存最近提交记录、随机种子和
失败前后的状态用于定位问题。OpenXiangShan 的具体接口是 RISC-V/Chisel
专用的，LCVEX 只借鉴其提交边界、参考状态和失败诊断思想。

QEMU 官方文档明确了以下限制：

1. `qemu_plugin_register_vcpu_insn_exec_cb()` 的回调发生在指令执行前，只能
   确认指令被 dispatch，不能保证指令成功完成。
2. 成功 Load/Store 的内存回调在访问完成后触发；faulting access 不会作为
   成功内存回调报告。
3. 指令和 translation block handle 只在相关回调期间有效，需要立即复制所需
   数据。
4. `qemu_plugin_read_register()` 只有在注册回调时请求
   `QEMU_PLUGIN_CB_R_REGS` 才能读取寄存器。
5. TCG 插件是被动监视接口，不能依赖它修改 QEMU 架构状态。
6. QEMU 插件 API 可能在 release 之间变化，必须与 `qemu/VERSION` 中固定的
   release 一起编译和测试。

因此，普通非异常指令可用“当前指令前回调 + 下一条指令前回调”完成上一条
指令的 post-state 采样；同步异常、精确 fault 和系统事件需要后续 QEMU fork
钩子，不能只依赖通用插件 API。

## 2. 两种运行模式

### 2.1 批量 trace 模式（当前 P1）

现有 `qemu/plugins/lcvex_difftest.c` 将 QEMU 执行结果写入文本 trace，
`sim/difftest/run_qemu.py` 离线解析和比较。这种模式适合：

- 验证 QEMU 插件寄存器读取和内存记录是否正确；
- 验证 A64 编码器和 Python 参考状态模型；
- 调试 QEMU release 升级；
- 生成可保存、可审阅的失败样本。

它不要求 Verilator 同时运行，保留为快速 smoke test 和回归基线。

#### 2.1.1 压缩 trace manifest 与可切片恢复

压缩 trace 是可发布的输入 artifact，不能只依赖文件名。`scripts/trace_manifest.py`
为每个 trace 生成 `LCVX-trace-manifest-v1` JSON，至少绑定以下内容：

- `trace` 与 `artifacts[role=trace]`：相对路径、字节数和 SHA256；
- `compression`：`gzip` 或 `none`。gzip 只接受一个完整 member，必须通过 CRC
  校验，不接受截断、尾垃圾或未声明的拼接 member；
- `inputs`：实际运行的 `image`、`dtb`、`qemu`、`plugin` 和 `qemu_version`，
  每项均保存相对路径、字节数和 SHA256。manifest 校验时会重新读取这些文件；
- `summary`：首尾 PC/指令、init/header 摘要、提交数以及全局半开区间
  `[seq_start, seq_end)`；`seq_end - seq_start` 必须等于提交数。

root trace 的全局起点默认为 0；QEMU `tail` 或窗口 trace 必须用
`--seq-start` 显式声明原始全局起点，不能把记录重新编号。切片命令的
`--start/--end` 始终是全局序号：

```sh
python3 scripts/trace_manifest.py create --trace full.trace.gz \
  --out full.trace.json --input image=Image --input dtb=virt.dtb \
  --input qemu=../qemu/build/qemu-system-aarch64 \
  --input plugin=../qemu/plugins/lcvex_difftest.so \
  --input qemu_version=../qemu/VERSION --seq-start 0
python3 scripts/trace_slice.py --in full.trace.gz --start 5652000 --end 5653000 \
  --out build/difftest/slice.trace.gz --source-manifest full.trace.json \
  --manifest build/difftest/slice.trace.json
python3 scripts/trace_manifest.py verify --manifest build/difftest/slice.trace.json
```

child manifest 固定 parent manifest/trace 的 SHA256、全局范围和 parent 对应
commit 记录的 canonical SHA256，并继承 Image/DTB/QEMU/plugin 输入摘要。这样
即使重写同长度 child payload、换用错误输入或移动 release artifact，也会被
拒绝；二级切片继续按 parent 的 `seq_start` 做 global→local 映射。切片保留
parent 的 init/header，只用于协调器从完整镜像 `--skip <seq_start>` 快进，不能
把切片当作独立启动负载。

输出和 manifest 都先写到目标目录内的临时文件，成功后原子替换；输入输出或
manifest 路径相同直接拒绝。低资源回归入口为：

```sh
make trace-manifest-smoke
make trace-slice-help
```

完整 trace、RAM、checkpoint 和波形不进 Git；发布时使用 release artifact，
并由仓库外的大小策略限制总 trace/checkpoint 空间。

差分 checkpoint 续跑也采用同一 provenance 原则：`CKPT_EVERY>0` 的
`run_lockstep_resume.sh` 在启动协调器前创建 pending manifest，绑定当前
Image/DTB/INITRD、QEMU/plugin、CPU/machine/icount 参数和 parent manifest
SHA256；成功后才 finalize 为 complete。协调器内部 local seq 保持不变，
`global_seq_offset=parent_global_seq+1`，由 context 显式记录 local/global
窗口与 artifact 端点。未完成 manifest、输入 hash 变化、parent 追加或输出目录
冲突都必须拒绝；fixture 入口为 `make checkpoint-resume-manifest-smoke`。

### 2.2 实时锁步模式（P2 推荐）

QEMU 插件连接一个运行 Verilator DUT 的 C++ 协调器。插件在每个指令边界
暂停 QEMU，协调器推进 DUT 一条指令，随后放行 QEMU；两边在提交点比较。

```text
                 Unix domain SOCK_SEQPACKET
┌──────────────┐  PRE/COMMIT/ACK/GO  ┌────────────────────┐
│ QEMU + plugin│◄───────────────────►│ Verilator coordinator│
│  vCPU thread │                     │ DUT + clock driver │
└──────────────┘                     └─────────┬──────────┘
                                               │
                                      Cocotb/SV test control
```

推荐让 C++ 协调器处于热路径，Cocotb 负责启动测试、加载镜像、读取结果和
回归管理。不要让 QEMU 插件直接链接 Verilator 生成的 C++ 模型：这样会耦合
两个运行时、增加退出/异常处理风险，也不利于替换 Verilator 或 QEMU。

## 3. 锁步时序

### 3.1 插件侧回调语义

插件维护一个 `pending` 指令和该指令的 Store 列表。`vcpu_insn_exec()` 在
每条指令执行前被调用，处理顺序如下：

```text
vcpu_insn_exec(N):
  1. 如果 pending=N-1：读取当前寄存器，形成 N-1 的 post-state
  2. 发送 COMMIT(N-1)，等待协调器 ACK
  3. 读取当前寄存器，形成 N 的 pre-state
  4. 发送 PRE(N)，等待协调器 GO
  5. 保存 N 为新的 pending，清空 Store 列表
  6. 返回，允许 QEMU 执行 N
```

指令 N 执行期间，成功的 Store 回调追加到 pending 的 Store 列表。下一条
指令 N+1 的前回调看到的寄存器状态，就是 N 执行后的状态，因此可以完成
N 的提交比较。

### 3.2 协调器侧时序

收到 `PRE(N)` 后：

1. 检查序号、PC 和指令编码。
2. 推进 Verilator 时钟，直到 DUT 产生 `commit_valid`。
3. 检查 DUT commit 的 PC/指令是否与 PRE 一致。
4. 保存 DUT commit 包和更新 DUT 参考 shadow state。
5. 发送 `GO(N)`，允许 QEMU 执行 N。

收到 `COMMIT(N)` 后：

1. 将 QEMU post-state 与保存的 DUT 状态比较。
2. 比较寄存器、SP、NZCV、next PC 和内存写。
3. 一致时发送 `ACK(N, OK)`。
4. 不一致时发送 `ACK(N, FAIL)` 和 `STOP`，保存完整诊断。

这样 QEMU 的指令 N 在收到 GO 前不会执行，DUT 和 QEMU 之间最多只有一条
待确认指令，不会出现大批量 trace 难以回溯的问题。

## 4. 二进制协议

实时模式使用 Unix `SOCK_SEQPACKET`，避免文本解析和半包处理。所有整数均为
little-endian。每个消息有固定头：

```c
struct lcvex_msg_header {
    uint32_t magic;       /* 'LDFT' = 0x5446444c */
    uint16_t version;     /* 当前为 1 */
    uint16_t type;
    uint32_t flags;
    uint32_t payload_len;
    uint64_t seq;
};
```

建议消息类型：

| 类型 | 方向 | 作用 |
| --- | --- | --- |
| `HELLO` | QEMU → Host | QEMU release、plugin API、目标架构、vCPU 数 |
| `CONFIG` | Host → QEMU | 单 vCPU、最大步数、状态掩码、超时 |
| `INIT` | QEMU → Host | 初始 PC/GPR/SP/PSTATE |
| `PRE` | QEMU → Host | 当前指令和执行前状态 |
| `GO` | Host → QEMU | 放行指定序号的指令 |
| `COMMIT` | QEMU → Host | 上一条指令 post-state 和 Store 列表 |
| `ACK` | Host → QEMU | 比较结果和错误码 |
| `DISCON` | QEMU → Host | 异常、IRQ、host call 等 PC discontinuity |
| `STOP` | Host → QEMU | 停止运行并输出诊断 |
| `EXIT` | QEMU → Host | vCPU 或 QEMU 退出 |

### 4.1 `PRE` 内容

至少包括：

- `seq`
- `pc`
- `insn`
- `x[0..30]`
- `sp`
- `pstate/nzcv`
- 可选状态 hash

### 4.2 `COMMIT` 内容

至少包括：

- `seq`
- `pc`
- `insn`
- `next_pc`
- 完整 GPR、SP、PSTATE/NZCV
- `gpr_we/gpr_rd/gpr_wdata`
- `sp_we/sp_wdata`
- `nzcv_we/nzcv`
- Store 数量和每个 Store 的地址、数据、字节掩码
- `exc_valid/exc_code`

早期发送完整寄存器快照，先保证正确性；每 1000～10000 条指令稳定后，
可以改为“提交写回 + 周期性全量快照”以降低 IPC 开销，但失败时必须能
请求最近一次全量状态。

## 5. Verilator 协调器

建议新增以下组件：

```text
sim/difftest/
  protocol.h/.cc          # 二进制协议编解码
  verilator_dut.h/.cc     # Vlcvex_* 封装和时钟推进
  lockstep_coordinator.cc # QEMU socket + DUT + compare
  run_lockstep.py         # 构建、启动和回归入口
```

### 5.1 DUT C++ 接口

```cpp
class VerilatorDut {
public:
    void reset();
    void load_image(const char *path);
    bool step_until_commit(uint64_t max_cycles, CommitPacket *out);
    const CommitPacket &last_commit() const;
    void dump_failure(const char *path) const;
};
```

`step_until_commit()` 每次执行：

```text
clk=0; eval();
clk=1; eval();
```

直到 `commit_valid=1` 或达到最大周期。默认最大等待周期建议为 1000，
超过即判定 DUT 死锁、流水线未提交或输入协议错误。

### 5.2 与现有 testbench 的关系

- SystemVerilog testbench：负责协议断言、复位、SRAM 行为和单元测试。
- Verilator C++ wrapper：负责高频时钟推进和 socket 锁步。
- Cocotb：负责镜像生成、进程启动、回归参数、失败报告和结果归档。

同一个 DUT 不应同时由 Cocotb 和 C++ wrapper 驱动时钟。锁步回归使用
C++ wrapper，Cocotb 负责测试控制；纯 RTL 功能测试继续使用 Cocotb/SV。

## 6. 内存一致性

早期 QEMU 和 DUT 各自拥有一份同样初始化的内存镜像。每条指令顺序执行，
因此前一条 Store 在 QEMU 放行后会更新 QEMU 内存，在 DUT commit 时也已更新
DUT 内存。协调器比较每条 Store 的地址、数据和字节掩码即可。

以下场景必须在早期禁用或显式建模：

- MMIO
- DMA
- 异步定时器
- 中断
- 自修改代码
- Cache maintenance
- 外部随机输入

进入 MMU/Cache/Linux 阶段后，协调器需要增加统一物理内存服务或内存事件
同步，不能只比较寄存器。

## 7. 异常和 QEMU fork 阶段

### P2/P3：正常标量指令

使用官方插件的 PRE/下一条 PRE 机制。只测试无异常、无中断、无 MMIO 的
A64 指令。注册 `qemu_plugin_register_vcpu_discon_cb()` 记录异常/中断的
PC discontinuity，但不把它当作精确退休事件。

### P4：同步异常

使用本地 QEMU fork patch 增加精确的架构提交钩子，目标 API：

```c
int qemu_lcvex_difftest_take_exception(unsigned int vcpu_index,
                                       uint32_t *ec);
```

状态：**Q6 已完成**（fork 补丁见 `qemu/patches/0001-*.patch`，
验证命令 `make q6`）。实现与早期设计的差异说明：

- 插件 `mode=step` 继续驱动锁步协议（HELLO/INIT/PRE/GO/COMMIT/ACK），
  QEMU fork 只补上插件 API 无法提供的“精确退休事件”：
  - `LCVEX_DIFFTEST_STEP=1` 时 `curr_cflags()` 强制单指令 TB
    （`CF_NO_GOTO_TB | CF_NO_GOTO_PTR | 1`），插件回调与异常入口都
    落在指令边界上；
  - `arm_cpu_do_interrupt()` 在异常入口先记录 ESR.EC 再触发插件
    discon 回调；插件在回调里调用 `qemu_lcvex_difftest_take_exception()`
    取走 EC，把同步异常转成带 `exc_valid/exc_code` 的 COMMIT，不再
    按 Q5 语义 DISCON 失败。
- 该 API 能区分：
  - 指令正常完成并退休：COMMIT `exc_valid=0`；
  - 指令触发同步异常但未退休：COMMIT `exc_valid=1`、
    `exc_code=ESR.EC`、`post.pc=异常指令 PC`、`post.next_pc=异常向量
    入口`（异常入口的 PC discontinuity 由同一个 COMMIT 表达）；
  - IRQ/FIQ 等异步事件：`take_exception` 返回 kind=2，插件仍按
    DISCON 失败处理（P4 测试不产生 IRQ，Q7 再扩展）。
- 经验：ARM discon 回调的 `from_pc` 是首选返回地址（SVC 为指令+4，
  即 ELR 值），不是异常指令地址；异常指令地址以 pending 指令为准。
- 插件 `mode=sync`（P2/P3/Q5）保持原语义：任何 discontinuity 都按
  DISCON 失败处理，与 `mode=step` 互斥。
- 每个 QEMU release 都需要重新验证 hook 的位置和提交语义。

### P5 以后：系统寄存器和 Cache

逐步导出系统寄存器、TLB fault、Cache maintenance、原子操作和中断状态。
只有架构可见的状态放入 commit 消息；TLB/Cache 内部事件另用可选诊断通道。

## 8. 超时、停止和错误处理

- 所有 socket 读写设置超时，禁止无限阻塞。
- `seq` 必须严格递增，收到旧序号或跳号立即停止。
- `PRE.pc/insn` 与 DUT commit 不一致时，报告 fetch/内存/PC 错误。
- DUT 超过 `max_cycles` 未提交时，保存波形和最近提交窗口。
- QEMU 进程退出、插件断开或协议版本不兼容时，测试失败而不是静默结束。
- 首次 mismatch 保存前后各 32 条记录、完整寄存器、内存写、QEMU stderr、
  Verilator 波形和随机种子。

## 9. 性能分级

| 模式 | 连接方式 | 用途 |
| --- | --- | --- |
| Trace | 文件 | P1 smoke、审阅、release 回归 |
| Lockstep-text | Unix stream + 文本 | 协议调试，低速 |
| Lockstep-bin | Unix `SOCK_SEQPACKET` | 日常逐指令回归 |
| In-process | 后期可选 | 性能实验，不作为第一版接口 |

不建议第一版把 QEMU 和 Verilator 强行链接到同一进程。跨进程 socket 会带来
少量开销，但能隔离崩溃、简化版本管理，并允许分别替换 QEMU、Verilator 和
Cocotb。

## 10. 实施里程碑

| 里程碑 | 工作 | 验收 |
| --- | --- | --- |
| Q0 | 保持现有 trace 插件 | P1 trace 回归两次完全一致 |
| Q1 | 增加 `mode=sync` 和 Unix socket | HELLO/PRE/GO/COMMIT/ACK 可循环 |
| Q2 | C++ Verilator wrapper | DUT 每条指令可提交且有超时 |
| Q3 | 端到端标量 lockstep | ADD/SUB/MOVZ/B/STR 与 QEMU 一致 |
| Q4 | 随机标量回归 | 10 万条以上无不可重放 mismatch |
| Q5 | discon 和停止处理 | 分支、退出和异常不会死锁 |
| Q6 | QEMU fork 精确 step hook | ✅ 精确上报（`make q6`）+ RTL 异常锁步（`make p4b`） |
| Q7 | MMU/Cache 状态扩展 | Linux bring-up 前完整回归 |

## 11. 失败定位顺序

1. 协议：magic、version、length、seq、socket 方向。
2. Fetch：PRE 的 PC/指令是否与 DUT commit 一致。
3. 初始状态：GPR、SP、NZCV、内存镜像是否一致。
4. 执行语义：写回数据、32/64 位宽度、XZR/SP 语义。
5. 控制流：next PC、分支 flush、BL/RET 链接地址。
6. 内存：地址计算、字节掩码、Store 次序和扩展。
7. QEMU 边界：是否把 before callback 错当成 after callback，是否遇到 fault。
8. 流水线：stall、forward、提交顺序和复位。
