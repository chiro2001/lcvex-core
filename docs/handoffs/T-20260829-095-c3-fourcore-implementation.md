# T-20260829-095 C3 四核功能实现（owner handoff）

> 状态：**review candidate；当前已列定向/完整四核测试全部通过，尚未 merge**。
> 本任务完成 C3 RTL、定向 TB、完整四核 message-passing；已知架构限制见下文。

```text
task=T-20260829-095 state=review base=0a134db800ffda1e10d2a7955c85ca0f2c3c4f32 head=4e09dc13387377a9e17b74e2b32b1337c3ca6c80 branch=feature/T-20260829-095-c3-fourcore-implementation worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-095 sent_at=2026-08-30T03:40:00+0800 received_at=2026-08-30T03:40:00+0800 reported_at=2026-08-30T03:40:00+0800 files=rtl/lcvex_l2_cluster.sv,rtl/lcvex_cluster_top.sv,rtl/lcvex_c3_sysctrl.sv,rtl/lcvex_core_wrap.sv,tb/sv/lcvex_c3_fourcore_tb.sv,tb/sv/lcvex_c3_cluster4_tb.sv,tb/sv/lcvex_c3_cluster4_multi_tb.sv,tb/sv/lcvex_c3_sysctrl_tb.sv,tb/sv/lcvex_c3_timer_tb.sv,docs/handoffs/T-20260829-095-c3-fourcore-implementation.md,docs/tasks/evidence/T-20260829-095.json tests=sysctrl-PASS,cluster4-PASS,C2-cluster-PASS,CORE_COUNT-1-lint-PASS,CORE_COUNT-4-lint-PASS,timer-PASS,full-fourcore-build-PASS,full-fourcore-runtime-PASS,multi-sharer-upgrade-PASS,multi-sharer-readunique-PASS blockers=none next=merge-evaluation
```

## 1. 重要说明

- 本任务**尚未 merge**；但当前列出的 C3 定向和完整四核测试已经全部通过。
- 已实现：
  - `lcvex_l2_cluster` 从隐式 2 核扩展为参数化 `CORE_COUNT=4`，加入多 sharer
    probe pending 位图和逐目标循环逻辑；
  - `lcvex_cluster_top` 接入 C3 system-control 模块、共享 PoC 路由和 per-core
    IRQ/event/lifecycle 合并；
  - `lcvex_c3_sysctrl`：PSCI-like CPU_ON/CPU_OFF/reset、SGI/IPI、SEV/event、
    status 读。
- **当前状态**：
  - 完整四核 `lcvex_c3_fourcore_tb` 在 `A64_FP_SIMD=0` 下构建并通过；四核均
    观察到 `flag=0x5a`。
  - 0-commit 根因已修复：`core_wrap` 在 RESET/STOPPED 期间把 `core_clk` 门控为 0，
    导致 core 异步复位未可靠初始化 `if_pc`；改为 RESET 状态保持时钟并给每核显式
    `core_reset_pulse` 后，`if_pc` 正确初始化为 `RESET_PC`。
  - 共享 flag 不可见根因已定位：`L1_SETS` 太小导致 4 个核代码和共享数据全部落入
    同一 direct-mapped set，频繁回填/失效；将 `L1_SETS` 提到 64 后完整 TB PASS。
  - 多 sharer `Upgrade` 和 `ReadUnique` 定向均已通过（3 个旧 sharer 全失效）。
  - `ReadUnique` 多 sharer 挂起根因已定位并修复：`lcvex_l2_cluster` 的
    round-robin liveness fallback 在 `for` 循环内使用局部变量 `int aj` 计算目标核，
    Verilator 5.050 生成代码未正确为 `aj` 赋值，导致当 `rr_ptr` 不是请求核时无法
    选中非零核。最小复现为四个 ReadShared 后 `rr_ptr=0`、core3 发起 ReadUnique，
    请求无法被仲裁接受。修复方法是直接内联计算索引并取首个有效请求；修复后
    `lcvex_c3_cluster4_multi_tb` 完整通过。
  - Generic Timer 定向 TB 已修复并通过。
  - 完整 GICD/GICC、TLB shootdown、checkpoint v4 未实现。

## 2. 实现内容

### 2.1 `rtl/lcvex_l2_cluster.sv`
- 移除 `dir_owner[0] ? 0 : 1`、`1-arb_sel` 两处二核硬编码。
- 增加 `probe_pending_mask` 和 `first_core()` 选择函数。
- `ReadUnique/Upgrade` 在 S 状态下按位图逐个 invalidate 所有非请求者；
  `S_PROBE_COMMIT` 处理剩余 mask，全部完成后才进入 fill/commit。
- 保持 round-robin + liveness fallback，CORE_COUNT=1/2/4 均可 elaboration。
- **ReadUnique 多 sharer 修复**：将 fallback 中依赖循环内局部变量 `int aj` 的
  写法改为直接使用 `(rr_ptr + ai) % CORE_COUNT` 表达式，并加 `!arb_sel_valid`
  守卫取首个有效请求，避免 Verilator 对局部变量的生成错误导致非当前指针核请求
  永远无法被选中。

### 2.2 `rtl/lcvex_c3_sysctrl.sv`（新增）
M1-B 系统控制从端，地址 `0x0903_0000`：

| 偏移 | 功能 |
| --- | --- |
| 0x00 | CPU_ON：按 target bitmask 产生 start_pulse |
| 0x04 | CPU_OFF：按 target bitmask 产生 stop_pulse |
| 0x08 | CPU_RESET：按 target bitmask 产生 reset_pulse |
| 0x10 | SGI/IPI：置 per-core irq pending |
| 0x14 | SEV/event：按 target bitmask 产生 event pulse |
| 0x18 | STATUS：返回 running/stopped/fault |
| 0x20 | EOI：清除 per-core irq pending |

### 2.3 `rtl/lcvex_cluster_top.sv`
- coherent 模式下共享 `lcvex_l2_cluster` + `lcvex_mem_ram` +
  `lcvex_c3_sysctrl`。
- 新增 PoC/system 路由：bypass 到 sysctrl 地址发给 sysctrl，其余送 RAM；
  用 `sys_target_r` 保持响应路由。
- 每核有效 `irq/event/start/stop/reset` 合并外部输入和 sysctrl 输出。
- 非 coherent 模式保持 C1 私有 RAM 路径。

### 2.4 测试文件
- `tb/sv/lcvex_c3_sysctrl_tb.sv`：PSCI-like CPU_ON/OFF/reset、SGI/EOI、
  SEV、status read。
- `tb/sv/lcvex_c3_cluster4_tb.sv`：CORE_COUNT=4 synthetic L1 目录 smoke。
- `tb/sv/lcvex_c3_timer_tb.sv`：单核 Generic Timer 定向（PASS）。
- `tb/sv/lcvex_c3_cluster4_multi_tb.sv`：四核多 sharer Upgrade/ReadUnique 合成 L1 定向。
- `tb/sv/lcvex_c3_fourcore_tb.sv`：完整四核 shared-memory message passing
  TB（A64_FP_SIMD=0 构建通过，运行 PASS）。

## 3. 验证表

| 测试 | 结果 | 说明 |
| --- | --- | --- |
| `lcvex_c3_sysctrl_tb` | PASS | CPU_ON/OFF/reset/SGI/SEV/status 均通过 |
| `lcvex_c3_cluster4_tb` | PASS | 四核 ReadShared 建立 4-sharer、WriteBack 清目录 |
| `lcvex_c2_cluster_tb` | PASS | C2 模块级目录 MSI 全序列通过 |
| `lcvex_l2_cluster` CORE_COUNT=1 lint | PASS | 参数化单核可编译 |
| `lcvex_l2_cluster` CORE_COUNT=4 lint | PASS | 4 核目录参数化可 elaboration |
| `lcvex_c3_timer_tb` | PASS | 修复单核程序加载后观察到 timer_phys_irq |
| `lcvex_c3_cluster4_multi_tb` | **PASS** | 多 sharer Upgrade 与 ReadUnique 均通过；旧 sharer 全失效 |
| `lcvex_c3_fourcore_tb` full build | PASS（A64_FP_SIMD=0） | cgroup 16GiB、-j1 下约 73s |
| `lcvex_c3_fourcore_tb` full runtime | **PASS** | 四核均观察到 flag=0x5a |

所有 Verilator 重型操作均在：
```text
systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- ...
```
下执行，`-j1`，未并发行重型 Verilator。

## 4. Cgroup 记录

- `systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0` 可用。
- 最终 full-fourcore build：`Verilator: Built ... 27.838 MB in 1382 C++ files`，
  walltime ~73s，cgroup 16GiB 下通过。
- 最终 `lcvex_c3_timer_tb` build：walltime ~200s，`-j1` 通过。
- 迷你目录 TB、C2、sysctrl、lint 均在 cgroup 下通过。

## 5. 已知限制

1. **完整四核系统级已通过**：`lcvex_c3_fourcore_tb` PASS；0-commit 和共享 flag 不可见
   均已定位并修复（core_clk 复位、L1_SETS 64）。
2. **多 sharer Upgrade/ReadUnique 均已通过**：`lcvex_c3_cluster4_multi_tb` PASS；
   ReadUnique 根因是仲裁 fallback 的 Verilator 局部变量生成问题，已修复。
3. **PSCI 软件路径未闭环**：完整 TB 仍为 testbench 直接 start。
4. **Timer IRQ 已修复**：`lcvex_c3_timer_tb` PASS；根因是单核程序加载位索引写错。
5. **非完整 GIC**：`lcvex_c3_sysctrl` 是 GIC/PSCI-lite，不是完整 GICv2
   GICD/GICC 寄存器模型，也没有完整异常/优先级/active 语义。
6. **未实现 TLB shootdown、checkpoint v4、Linux SMP**。
7. **未引入 ACE/CHI/SVE，未启动 Quartus，未触碰 T-067/QEMU/checkpoint**
   共享热点。

## 6. 下一步

1. 当前 C3 已列测试全部 PASS；可进入 merge review，但**尚未 merge**。
2. 若需要实现完整 GICv2/PSCI 或 Linux SMP，另立串行任务。
3. 完成后再进入 C4 8/16/32 规模测量。
