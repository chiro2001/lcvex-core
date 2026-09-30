# LCVEX Checkpoint / Restore / Drain 权威协议

版本：CKPT-PROTO，基线 `0f4b4a18970219e719674edd6cb3ff91d4c7ac38`
适用：ARMv8.2-A AArch64、单发射顺序核、`CORE_COUNT=1` 的 P6/P7 验证路径和
B4 D-L1/L2 endpoint。
状态：当前实现审计 + F1/F3 必需扩展门；本文不把设计意图写成已经实现。

本文是后续 F3a transaction queue、MSHR、store buffer 和 F1 fetch FIFO 使用的
checkpoint 启动门。与实现冲突之处以本文的 `[gap]` 记录为准，不能通过解释放宽。

## 0. 标记、范围和不变量

规则旁的标记含义：

- `[implemented]`：当前源码存在该行为，并有指定的静态/定向证据；不表示本任务
  在当前 SHA 新跑过该测试。
- `[required extension]`：后续实现必须满足的冻结接口或门；当前不可声称支持。
- `[gap]`：实现缺失、范围不一致或尚未有足够证据；进入该路径必须停止或降级。

本协议只覆盖以下 envelope：

| 范围 | 当前口径 |
| --- | --- |
| CPU | 单核、AArch64、单发射、顺序提交；每周期最多一条 commit。 |
| 硬件 drain | B4 standalone `lcvex_l1_coherence` / `lcvex_catapult_soc_coh` 的 D-L1→L2→PoC 顺序；不等同于所有 SoC/cluster 已接通。 |
| 软件 checkpoint | `CKPT_REQ/CKPT_READY`、RAM diff、arch/sys/timer/GIC/MMIO/FP sidecar、`manifest.json`/`manifest.tsv`。 |
| restore | QEMU `-incoming` 与 Verilator 恢复 sideband 的联合路径；cache/MSHR/store-buffer 内容不从 sidecar 恢复。 |
| 多核 | C2/C3 的目录和 per-core drain 仅是未来 envelope；当前 `lcvex_cluster_top` 未提供完整 checkpoint 控制。 |

下列不变量在任何 feature 开关下都不能削弱：

1. 架构 GPR、SP、NZCV、PC、系统寄存器和 monitor 的普通更新只发生在
   `commit_fire`/系统指令提交；restore 是复位后的专用边界，不是逐条回灌 QEMU。
2. checkpoint 的最终成功条件是所有较老的核心/内存事务已终结、脏数据已到 PoC、
   且 sidecar/manifest 已通过完整校验；任一 fault、reset、timeout 或 hash 失败
   都不能产生最终发布成功。硬件 `checkpoint_ack_valid` 只表示 drain 边界稳定，
   不得把它单独当成已发布 artifact。
3. 所有 ready-valid 通道在 `valid && ready` 的时钟沿完成一次消费；`valid=1 &&
   ready=0` 时 payload、身份和 fault 字段保持，不能重发或换路由。
4. checkpoint 选择的是 inclusive committed sequence；恢复的第一条指令是该
   sequence 的 `next_pc`，不是再次执行保存点指令。
5. MSHR、store buffer、fetch FIFO 当前不存在，未来也不得写入 sidecar；保存前
   必须 drain，恢复后必须 invalidate/epoch quarantine。

## 1. 术语和状态所有权

| 术语 | 定义/所有者 | 保存或恢复边界 |
| --- | --- | --- |
| `quiesce` | checkpoint 控制器向 core/PTW/cache 发出的 level；表示停止新请求，允许已接受事务排空。 | 当前 B4 为 `checkpoint_quiesce`；不存在显式 request payload。 |
| 请求接受 | 现有 B4 中 `checkpoint_quiesce` 被保持为高且 endpoint 在可接受边界采样；未来应是 `checkpoint_req_valid && checkpoint_req_ready`。 | 接受后不得再开始第二次 checkpoint。 |
| `drain` | 为达到稳定边界而完成较老事务、写回脏行、消费 response。 | 不保存事务上下文；只保存完成后的架构/设备状态。 |
| `PoC` | L2 下游可见的共享内存点；当前实现是 M1-B/延迟/RAM 或相应 BFM。 | 成功前所有 dirty line 必须到此。 |
| `checkpoint_ack` | 硬件报告 drain 成功；与 QEMU 的 `CKPT_READY` 不同。 | 成功 ack 只能在 L2 drain ack 后产生。 |
| `fault` | drain、sidecar、协议或校验失败的终止状态。 | 失败状态必须可诊断、不可伪装为成功。 |
| `epoch` | reset/checkpoint restore 的事务世代；普通 branch/exception kill 不递增。 | F3a 固定 8 bit；wrap 前进入 quarantine。 |
| `age` | 指令/事务提交年龄。 | F3a 固定 16 bit；F3b oldest-first，窗口距离小于 `2^15`。 |
| 事务 UID | `(core_id, source_id, epoch, transaction_id)`；line refill 另带 `beat_idx`。 | F3a 固定 `source=4`、`transaction=8`、`epoch=8`、`age=16`、`beat=3`。 |
| 架构状态 | commit 后 QEMU/DUT 可观察的 GPR、PC、SP、NZCV、PSTATE/系统寄存器、Timer/GIC 等。 | 由对应 sidecar 或 QEMU VMState 恢复。 |
| 可重建微架构状态 | pipeline、fetch/data pending、MMU walk、cache metadata、MSHR、store buffer、FIFO 等。 | 不作为当前 sidecar 输入；保存前 drain，恢复后清除/重建。 |
| sidecar 所有者 | QEMU fork/plugin 生成 QEMU 状态，协调器生成 arch、压缩/manifest 并注入 DUT。 | 每个 owner 只能提交自己的已校验 artifact。 |

当前 B4 endpoint 的状态所有权如下：D-L1 自己拥有 valid/tag/dirty/data 和
`l1_drain_done/fault`；L2 拥有 valid/tag/dirty/data、PoC beat 和
`drain_ack_valid/fault`；wrapper 拥有 `CP_IDLE/CP_L2_REQ/CP_L2_WAIT/CP_ACK/
CP_FAILED/CP_DONE`。源码见
`rtl/lcvex_l1_coherence.sv:313-372`、`rtl/lcvex_l1_d_wb.sv:87-114` 和
`rtl/lcvex_l2_wb.sv:127-201`。

## 2. 控制面和 ready-valid 握手

### 2.1 当前信号

| 信号/帧 | 当前语义 | 标记 |
| --- | --- | --- |
| `checkpoint_quiesce` | level 请求。高电平时 B4 wrapper 禁止 core/PTW 新接受；必须保持到成功 ack 被消费或 fault 被记录。低电平开启下一次尝试。 | `[implemented]`，仅 B4 endpoint |
| `checkpoint_ack_valid` | wrapper 处于 `CP_ACK` 时为 1；只有与 `checkpoint_ack_ready` 握手才离开 ack 状态。当前没有 seq/epoch/status payload。 | `[implemented]` |
| `checkpoint_ack_ready` | 控制器对成功 ack 的 ready；ready=0 时 ack 必须保持。 | `[implemented]` |
| `checkpoint_fault` | `CP_FAILED` 或 L1/L2 drain fault 的 level OR；没有独立 ready，也没有 fault code/epoch。 | `[implemented]`（有限）/ `[gap]`（完整 ABI） |
| `l1_drain_done/fault` | D-L1 完成逐 set dirty writeback 或失败；fault 时保留未完成 dirty metadata。 | `[implemented]` |
| `l2_drain_req_valid/ready` | L1 done 后发起一次 L2→PoC 全阵列 drain；request 携带固定 `source=0, transaction=0xc1`。 | `[implemented]`（B4） |
| `l2_drain_ack_valid/ready/fault` | L2 完成全部 dirty line 后保持 ack；PoC fault 不产生 success ack。 | `[implemented]` |
| `CKPT_REQ` | host→QEMU，四个 512-byte 路径字段（dev/sys/timer/gic），只能匹配当前 COMMIT seq。 | `[implemented]`（P2 diff path） |
| `CKPT_READY` | QEMU 已写 device/sys/timer/GIC（以及 P7 FP）原始状态；`status<0` 表示保存失败。 | `[implemented]` |
| host `ACK` | 协调器比较成功后给 QEMU 的继续执行许可；checkpoint 保存失败时发送 `ACK_FAIL` + `STOP`。 | `[implemented]` |

B4 wrapper 的 core/PTW ready 在 quiesce 高时为 0，但响应仍可被消费：
`rtl/lcvex_l1_coherence.sv:146-163`。D-L1 在 idle 时优先完成已经到达的
probe，再进入 drain scan；请求 ready 在 quiesce 高时为 0，probe ready 目前仍
可能为 1：`rtl/lcvex_l1_d_wb.sv:217-235,303-328`。因此外部控制器不得在
drain 开始后再注入新的 probe；该限制尚未由信号强制，记为 `[gap]`。

### 2.2 冻结的握手规则

下列是未来统一 bridge 的规范。旧 B4 没有的字段不得被默认为已存在：

1. `[required extension]` 增加 `checkpoint_req_valid/ready` 和请求上下文
   `seq/epoch`。只有 `valid && ready` 才接受新请求；`ready=0` 时请求者保持
   `valid`、seq、epoch 和 payload。一个请求未进入终态前，`ready` 必须为 0。
2. `[implemented]` 兼容 B4 将 `checkpoint_quiesce` 视为已接受请求的 level：
   控制器在拉高后不得撤回或脉冲化；保持到 ack/fault。拉低是 release/reset
   本次控制状态的边沿，不是“暂时暂停”。
3. 请求接受后，core、PTW、I-L1、D-L1、L2、PoC、MMU/PTW 和所有未来 queue
   必须停止新的可见请求；已经在下游接受的 read/write/atomic/probe 只能完成、
   fault 或按明确 kill 规则终结。已开始的 Device/MMIO/store/atomic/maintenance
   不得以普通 branch kill 回滚。
4. `[required extension]` 成功 ack 携带 `seq`、restore epoch 和 status。它只能
   在 pipeline/事务为空、L1 done、L2/PoC drain ack 已握手之后拉高。`valid=1 &&
   ready=0` 时这些字段全部保持；不能先产生 ack 再继续写回或启动新请求。
5. 当前 `checkpoint_fault` 是 level status，不接受 ready。冻结语义为：fault
   sticky 到控制器记录现场并释放 quiesce；同一 attempt 内 fault=1 时绝不允许
   `ack_valid=1`。若未来改为 `checkpoint_fault_valid/ready`，同样必须保持
   fault code、seq、epoch 和失败现场索引直到握手，且 fault 消费不能隐含成功。
6. `[required extension]` 每个 endpoint 必须报告可判定的终结条件：
   `core_idle && no_commit_pending && no_mem_pending && no_mmu_walk &&
   no_fetch_pending`，D-L1/L2 没有 active writeback/refill/probe，PoC/arb/router/
   delay/RAM 没有 in-flight/held response。仅观察 `ready=0` 或 cache idle 不足以
   宣称排空。
7. `[gap]` 现有设计没有 checkpoint deadline/watchdog。未来 timeout 必须从
   request accept（或 quiesce 被采样为高）开始，以固定 cycle budget 计数；到期
   进入 FAILED、禁止 success ack、保存 UID/状态窗口，并先 bump epoch/quarantine
   再 release。协调器 `timeout_ms` 只是 socket receive timeout，不是 drain timeout。

## 3. 严格时序和状态机

### 3.1 规范时序

```text
控制器             core/arb/MMU       D-L1              L2/PoC       sidecar/manifest
   | req v/r             |               |                 |                |
   |----accept---------->|               |                 |                |
   | quiesce=1           | stop new      | stop new         | block new      |
   |                     | drain core/PTW/transport       |                |
   |                     |-------------->| drain dirty      |                |
   |                     |               |--l1_drain_done-->|                |
   |                     |               |                  | drain dirty    |
   |                     |               |                  |--drain_ack---->|
   |<---------------- success checkpoint_ack (held until ready)              |
   |--------------------------------------------------------------------------|
   |                                            pending manifest + artifacts   |
   |                                            validate + atomic finalize     |
   |                                            host/QEMU ACK/GO               |
```

规范顺序不可交换：

```text
STOP_NEW
  → CORE_PIPELINE_COMMIT_DRAIN
  → CORE_PTW_TRANSPORT_INFLIGHT_DRAIN
  → D_L1_DIRTY_DRAIN
  → L2_POC_DRAIN
  → SUCCESS_ACK
  → MANIFEST_PENDING + SIDECAR_STAGING
  → HASH/PROVENANCE_VALIDATE
  → ATOMIC_FINALIZE
  → RELEASE/next execution
```

`CORE_PTW_TRANSPORT_INFLIGHT_DRAIN` 只表示停止新请求并排空已经接受的 core/PTW
事务，以及 arb/router/delay/RAM 的 held response；它不表示 cache dirty line 已
到 PoC，也不允许把 D-L1/L2 的 dirty writeback 提前到该阶段。真正的 dirty PoC
顺序固定为 `D_L1_DIRTY_DRAIN → L2_POC_DRAIN`。

`D_L1_DIRTY_DRAIN` 与 `L2_POC_DRAIN` 的顺序是硬约束：D-L1 的每条 dirty line
先按 8 个 8B beat 写入 L2；L2 再扫描并把自己的 dirty line 写至 PoC。
`rtl/lcvex_l1_coherence.sv:350-369` 和
`rtl/lcvex_l2_wb.sv:969-1000` 体现该 FSM；联合 TB 在
`tb/sv/lcvex_l2_l1_probe_tb.sv:230-244` 检查 L1 done 先于 L2 request。

### 3.2 当前 B4 FSM 对照

```text
CP_IDLE --l1_drain_done--> CP_L2_REQ --req_fire--> CP_L2_WAIT
CP_L2_WAIT --drain_ack_fire--> CP_ACK --ack_fire--> CP_DONE
   \--l1/l2 fault----------------------------------> CP_FAILED
```

这是 `[implemented]` 的 endpoint 顺序，不是全 SoC 的 checkpoint 完成证明：
它没有 core pipeline drain input，也没有 timeout、epoch 或 sidecar callback。
`CP_DONE/CP_FAILED` 在 quiesce 释放后回到 `CP_IDLE`，因此下一次尝试必须显式
拉低再拉高 quiesce。

### 3.3 P2 软件路径对照

当前 `lockstep_coordinator` 在一条 COMMIT 已比较、尚未发 host ACK 时，才发送
`CKPT_REQ`；QEMU 插件收到后保存状态、发送 `CKPT_READY` 并等待 ACK，协调器
读取 RAM、生成 sidecar 后才发送 ACK。源码见
`qemu/plugins/lcvex_difftest.c:830-970`、
`sim/difftest/lockstep_coordinator.cc:4063-4088`。

```text
QEMU COMMIT(seq) → CKPT_REQ(seq)
                    → QEMU device/sys/timer/GIC[/FP] write
                    → CKPT_READY(seq)
                    → coordinator RAM/arch/compression/provenance work
                    → ACK_OK(seq) → QEMU continues
```

该路径 `[implemented]` 保证一个 COMMIT 窗口内不执行下一条 guest 指令，但
`lcvex_soc_tb` 没有 `checkpoint_quiesce` 输入，实际 lockstep capture 不会调用
B4 L1/L2 drain；所以 P2 现状不能作为“缓存已排空”的证据，列为 `[gap]`。
此外，当前 `run_lockstep_step.sh` 只在协调器整个运行成功退出后调用
`finalize-manifest`（`sim/difftest/run_lockstep_step.sh:346-354`），而不是在每个
checkpoint 的 `ACK_OK` 前发布 final marker；QEMU 因此可能在 pending manifest
仍未 finalize 时继续执行。这不影响 pending reader 的安全拒绝，但不满足每个
checkpoint 的原子完成语义，列为 `[gap]`。后续 bridge 必须把 3.1 的硬件 ack
插入 `CKPT_REQ/READY` 前后，并在允许 QEMU GO/ACK 前完成该 checkpoint 的
manifest finalize；不能用 `CKPT_READY` 代替 hardware drain ack。

## 4. 正常 checkpoint 保存

### 4.1 硬件部分

1. 控制器接受请求并拉高 quiesce。core/PTW 新 request ready 变为 0；已经接受
   的响应仍按原 payload/身份消费。`commit_ready` 不得绕过旧 WB 条目。
2. `[required extension]` 等待 core 的 commit/pipeline、取指、数据翻译、PTW、
   arb/router/delay/RAM 的 in-flight 全部清零；当前 core 只有 reset/restore
   能清 `fetch_pending`、IF/ID、ID/EX、EX/MEM、MEM/WB 等字段，见
   `rtl/lcvex_core.sv:3382-3402`，没有 quiesce drain output。
3. D-L1 在 `ST_DRAIN_SCAN` 逐 set 检查 dirty line；每个 dirty victim 的 8 个
   beat 都成功后才清 dirty。成功进入 `ST_DRAIN_DONE`，fault 进入
   `ST_DRAIN_FAILED` 并保留 metadata：`rtl/lcvex_l1_d_wb.sv:406-424,520-542`。
4. L2 只在 idle、无 core/probe 请求时接受 `drain_to_poc`，逐 set/way 下刷
   dirty line；最后一个 beat 成功才进入 `ST_DRAIN_ACK`。任何 PoC fault 都置
   `drain_fault`，不进入 ack：`rtl/lcvex_l2_wb.sv:360-375,693-748`。
5. L2 drain ack 被 wrapper 消费后，wrapper 才把 `checkpoint_ack_valid` 拉高。
   ack ready=0 时保持；成功 ack 后才允许软件阶段开始。

### 4.2 sidecar/manifest 部分

当前 sidecar 文件和 owner 如下（所有 payload 均是 gzip 外的固定格式）：

| artifact | 内容/大小 | owner/读取 |
| --- | --- | --- |
| `*.ram.gz` | `LCVXCKP1` v1，56B header，4 KiB 页记录；base 全量、diff 只含变化页。 | 协调器写，`restore_ram()` 按 parent 顺序应用。 |
| `*.dev.gz` | QEMU `qemu_savevm_state_header + qemu_save_device_state` 的 VMState。 | QEMU fork 写原始文件，QEMU `-incoming exec:cat` 读取。 |
| `*.arch.gz` | `LCVXARC1` header + `lcvex_state`（PC/next_pc/insn/GPR/SP/NZCV）。 | 协调器写，Verilator arch restore 使用。 |
| `*.dev.sys.gz` | `LCVXSYS1` 476B、v2 500B、v3 540B、v4 548B；v4 追加 `CONTEXTIDR_EL1`。 | QEMU fork 写，Python/C++ 校验并注入。 |
| `*.dev.timer.gz` | `LCVXTMR1` v1、80B；CNT、CVAL、CTL、offset 字段。 | QEMU fork 写；固定 1 GHz、offset=0 路径恢复。 |
| `*.dev.gic.gz` | `LCVXGIC1` v1、732B；单核控制和前 96 IRQ。 | QEMU fork 写；超出 96 的 live 状态拒绝保存。 |
| `*.dev.mmio.gz` | `LCVXMMIO` v1、52B；C++ PL031/fabric 状态和 `now_ns`。 | 协调器写/恢复；不在 QEMU VMState。 |
| `*.dev.fp.gz` | `LCVXFP01` v1、552B；P7 canonical 16B V[31:0]、FPCR/FPSR、seq。 | QEMU plugin 写；仅 `FP_NEON=required` 且 V profile。 |

`manifest.tsv` 至少 7 列（kind/seq/parent/ram_bytes/pages/ram/dev），随后依次
增加 arch、sys、timer、GIC、C++ MMIO、FP 到 13 列。当前 Python 解析和 sidecar
布局见 `sim/difftest/checkpoint.py:450-516,706-930`。

严格保存步骤：

1. `[implemented]` 运行开始先 `init-manifest`。strict context 写入
   `status=pending`、`state=pending`、`lifecycle=staging`、`finalized=false`、
   `complete=false`，并绑定 Image/DTB/plugin/QEMU/VERSION 的 size/SHA256。
2. `[implemented]` 在硬件 drain ack 后（当前 P2 暂以 COMMIT 窗口代替，见
   3.3 gap）把 RAM、device、arch、sys、timer、GIC、MMIO、FP 先写入 task 私有
   staging 文件。任何单项失败都终止最终发布，不得再报告完整 checkpoint 成功。
3. `[implemented]` 逐 artifact 计算 size/SHA256，核对 `manifest.tsv` SHA、chain
   entries/first/last seq、parent/provenance 和所有输入；`finalize_manifest()`
   先验证 candidate，再通过 `_write_json_atomic()` 发布 complete/finalized。
4. `[implemented]` `read_manifest()` 先拒绝 pending/incomplete manifest，再校验
   artifact、TSV、chain、输入、QEMU 和 parent SHA；因此未 finalize 的目录永远
   不能成为恢复输入。
5. `[gap]` artifact 文件分别 rename，legacy P6 `manifest.tsv` 仍通过普通 append；
   没有覆盖“所有 artifact + TSV + final marker”的单次掉电原子提交，也没有目录
   fsync。final JSON 的 reader gate 已实现，但完整 bundle atomicity 仍是后续门。

### 4.3 事务与序号

- checkpoint 记录是已比较的 COMMIT `seq`，`next_pc` 是恢复入口；普通 commit
  packet 仍保持 `docs/COMMIT_PACKET.md` 的一条指令一包 ABI。
- RAM diff 的 `parent` 必须是前一记录 seq；base parent 是 `UINT64_MAX`。`pages`
  以 manifest 为准，RAM header 当前保留字段为 0，不能以 header 的 0 绕过页数
  校验。
- resume child 的 `global_seq_offset`、`parent_seq`、`parent_local_seq` 和
  artifact inclusive range 必须与 parent manifest 绑定；不能从无 provenance
  的旧链推导 global seq。
- 一个 checkpoint attempt 内只允许一个 seq；不能把 QEMU 状态、DUT sidecar、
  manifest 或测试结果从不同 source SHA/QEMU binary 拼接为绿色证据。

## 5. fault、abort、reset 和 timeout

### 5.1 硬件 fault

| 场景 | 必须行为 |
| --- | --- |
| D-L1 writeback/refill fault | response 带 fault；未完成 dirty victim 的 valid/tag/dirty/data 不复用；`l1_drain_done=0`、`l1_drain_fault=1`。 |
| L2/PoC drain fault | 当前 line 保持 dirty；`drain_fault=1`、`drain_ack_valid=0`；wrapper `checkpoint_fault=1`。 |
| L2→D-L1 dirty probe 的 PoC fault | L2 使用 `l1_probe_rsp_abort=1` 消费 held response；D-L1 保留原 metadata，后续可重试。见 `docs/L1_L2_PROBE_CONTRACT.md`。 |
| response backpressure | 所有 response payload、地址、fault、source/transaction 在 ready=0 保持；不可清 metadata。 |
| checkpoint ack backpressure | `checkpoint_ack_valid` 保持为 1，直到 `ack_ready` 握手；不能重复产生第二 ack。 |
| 任何 sidecar/hash/provenance fault | 若在 drain ack 前发生，不发 `checkpoint_ack_valid`；若在 drain ack 后发生，撤销/终止最终发布，协调器发 `ACK_FAIL`/`STOP`，保留 pending/failure 现场，不能把先前 drain ack 宣称为完整 checkpoint 成功。 |

`tb/sv/lcvex_l2_l1_probe_tb.sv:246-255` 和
`sim/cocotb/test_l1_d_wb.py:207-227` 是当前 fault/no-stale-response 证据；
它们不覆盖 core-integrated quiesce 或 timeout。

### 5.2 reset

- `[implemented]` `rst_n=0` 时 B4 endpoint 的 request/response valid 为 0；L1/L2
  清 state、valid/dirty/tag 和事务寄存器，data array 仅通过 valid=0 不可见。见
  `rtl/lcvex_l1_d_wb.sv:260-293`、`rtl/lcvex_l2_wb.sv:441-501`。
- `[implemented]` core async reset 清 IF/ID、ID/EX、EX/MEM、MEM/WB、pending、
  commit valid、MMU/translation pending、monitor 和系统状态；reset 值包括
  `RESET_PC`、GPR/SP=0、NZCV=0100、EL1h、DAIF=1111、`SCTLR_EL1=0x00c50838`、
  `epoch` 当前不存在。见 `rtl/lcvex_core.sv:1772-1910`。
- `[required extension]` reset/checkpoint restore 必须是所有共享 endpoint 的
  同一事务边界；不能只复位 core 而让 arb/router/delay/RAM/cluster 持有旧 response。
  旧 response 要么被同步 reset 消费丢弃，要么带旧 epoch 进入 quarantine。
- `[gap]` 当前 C1 `lcvex_core_wrap` 将 drain 输出 tie 0
  (`rtl/lcvex_core_wrap.sv:441-446`)，C2 `cluster_top` 没有 checkpoint_quiesce
  输入；不能据此声称多核 reset/checkpoint 原子。

### 5.3 timeout 和重试

当前没有硬件 checkpoint timer；协调器的 `timeout_ms` 只包住 Unix socket 收发，
`max_cycles_per_insn` 只包住 DUT 单条提交。未来 timeout 的冻结动作：

1. 停止接受新的 request/sidecar write，记录 `seq/epoch/UID`、状态机和最近
   commit window；
2. 置 terminal fault，绝不拉高 success ack；
3. 向已经接受的物理请求等待 response，或发 reset/quarantine；禁止猜测“已完成”；
4. bump epoch 后清理 stale response/queue，再由控制器释放 quiesce；
5. 新 attempt 必须使用新 request seq/epoch，旧 pending manifest 不得复用。

## 6. Restore 协议

### 6.1 进入 restore 前置条件

1. 只接受 `manifest.json` 为 published：strict 链必须同时满足
   `status=complete`、`state=complete`、`lifecycle=finalized`、`finalized=true`、
   `complete=true`。pending/incomplete 永不作为输入。
2. 校验 `manifest.tsv`、所有 artifact size/SHA、Image/DTB/initrd/plugin/QEMU/
   VERSION、parent manifest SHA 和 global/local seq range。不能混用不同 source SHA。
3. 选定 seq 必须是 chain 中实际记录，restore RAM 按 base 到该 seq inclusive 应用；
   `arch/sys/timer/GIC/MMIO/FP` 都必须来自同一 row。当前工具能独立验证各格式，
   但 `[gap]` 尚未检查 arch 和 sys payload 内 PC/GPR/SP/NZCV 逐字段相等。

### 6.2 规范恢复顺序

```text
VALIDATE_FINAL_MANIFEST
  → STOP_NEW_REQUESTS
  → ASSERT_RESET + ENTER_QUARANTINE
  → BUMP_EPOCH（不得 wrap；旧 response 只消费丢弃）
  → FLUSH_PIPELINE/ARB/MMU/FETCH/D-L1/L2/MSHR/SB（后四项按实现情况）
  → LOAD_RAM(base + inclusive diffs)
  → INJECT_ARCH + SYS（GPR/SP/PSTATE/MMU regs/monitor）
  → INJECT_TIMER + FP（同一 restore boundary）
  → INJECT_GIC + C++ MMIO（仍禁止 guest 执行）
  → INVALIDATE_REBUILD_CACHE/TLB（不读取 sidecar 中不存在的 cache state）
  → RELEASE_RESET，等待旧 epoch 无可见 response
  → QEMU -incoming + timer offset，DUT INIT probe
  → INIT/FP_INIT 与保存点 next_pc/状态一致
  → 开始 PRE → DUT commit → QEMU COMMIT → ACK
```

规范要求和当前实现的差异：

- `[required extension]` reset/quarantine/epoch 必须先于任何新请求，且所有下游
  endpoint 共享 epoch。F3a 固定 `epoch_r` 冷 reset=0，warm reset/restore 每次
  加 1；wrap 前停止在 quarantine。
- `[implemented]` core restore strobe 在 reset 后清 `fetch_pending`、IF/ID、ID/EX、
  EX/MEM、MEM/WB、commit、PAR pending，并从 sidecar `next_pc` 重新取指；见
  `rtl/lcvex_core.sv:3382-3460`。
- `[implemented]` `lockstep_coordinator` 当前顺序是：`reset_and_load` → 写 image，
  restore 时加载 RAM → `restore_sys_state`（reset 两拍，GPR 在 reset 保持期间
  写入，sys/timer/FP 同拍 strobe）→ GIC 直接恢复 → C++ MMIO 恢复 → 启动 QEMU
  `-incoming`；见 `sim/difftest/lockstep_coordinator.cc:3241-3350,1498-1660`。
- `[implemented]` `sys` sidecar v3 的 `exclusive_addr/val/high` 与 v4
  `CONTEXTIDR_EL1` 进入 core restore；无 monitor 用 `exclusive_addr=~0`。普通
  monitor 仍只有 commit 时更新，见 `rtl/lcvex_core.sv:3427-3446` 和
  `docs/handoffs/T-20260829-097-checkpoint-sidecar-v4.md`。
- `[implemented]` Timer sidecar 的 `cntpct` 是恢复后下一条可见值；DUT 注入
  `cntpct_r=cntpct-1`，QEMU 插件在第一条指令前设置 difftest counter offset；
  `CNTFRQ=1 GHz`、`CNTVOFF/CNTPOFF=0` 是当前唯一接受配置。
- `[implemented]` GIC 恢复写入控制、priority、前 96 IRQ 的 pending/enabled/
  active/level/edge/group；running/current pending 由 DUT 组合重建。`num_irq`
  不足 96 或范围外有 live 状态时不允许发布。
- `[implemented]` P7 canonical V profile 的 FPCR/FPSR/V raw bits 与 sys restore
  同一 DUT strobe；`FP_INIT` 必须在 INIT 后、PRE 前匹配 QEMU/DUT。SVE/SME Z
  vector state 不在当前 sidecar；只有 ZCR/SMCR 控制值存在，故 SVE vector restore
  为 `[gap]`/excluded。
- `[implemented]` C++ MMIO restore 同时恢复 fabric state 和 bridge `virt_ns_r`；
  否则下一次 PL031 retire 会回到 reset 时间。
- `[gap]` 当前没有 explicit epoch bump、stale response quarantine、cache/TLB
  restore barrier；依赖 top-level reset 的 valid 清除不能替代 F3a 端到端证明。

### 6.3 restore 后检查

- Coordinator 必须收到 `INIT(seq=0)`，并检查 `pc=checkpoint.next_pc`、GPR、SP、
  NZCV；当前实现检查的是 `arch` 摘要，即使 `sys` 也参与实际注入
  (`sim/difftest/lockstep_coordinator.cc:3465-3510`)。
- `[required extension]` INIT 检查必须同时证明 arch/sys 同 row、同 seq、同 epoch；
  不能让 arch 作为期望值而 sys 注入另一份状态。
- P7 `FP_INIT(seq=0)` 必须匹配保存的 `LCVXFP01` 与 DUT raw state；FP required
  不提供第 13 列时必须拒绝。
- 第一条 PRE 必须从 restore 的 next_pc 开始；不允许 `--skip` 替代 QEMU VMState
  或 sidecar restore。任何 stale response、旧 commit、提前 memory effect 都是
  restore failure。

## 7. 状态矩阵

| 状态 | 冷 reset/权限 | checkpoint 保存 | restore 动作 | 状态 |
| --- | --- | --- | --- | --- |
| GPR x0..x30 | 0；普通写仅 commit | arch/sys | reset 保持期灌入；INIT 校验 | `[implemented]`（验证入口为层级写，生产端口 `[gap]`） |
| PC/next PC/insn/SP/NZCV | PC=`RESET_PC`、SP=0、NZCV=0100；commit packet | arch + sys | next_pc 作为首条 fetch；系统状态同拍 | `[implemented]` |
| EL/SPsel/DAIF/PAN/DIT/SSBS/UAO/TCO/ALLINT | reset EL1h/DAIF=1111，其余 0；系统 commit | sys v1+ | restore strobe；PSTATE mask 与 RTL 支持集 | `[implemented]`（目标 profile） |
| ELR/SPSR/VBAR/SCTLR/TCR/TTBR/MAIR/ESR/FAR/PAR/CPACR/MDSCR | reset 0，系统指令权限/commit | sys | restore strobe；SCTLR 使用实现 mask | `[implemented]`（PAuth 位 excluded） |
| TPIDR/PIR/PIRE0/PMUSERENR/TCR2/CONTEXTIDR/ZCR/SMCR/CSSELR | reset 0；系统寄存器按当前 shim 权限 | sys v3/v4 | restore strobe；v1/v2 缺失字段回 reset 0 | `[implemented]`（v4 当前 joint full smoke `[gap]`） |
| exclusive monitor | reset invalid；LDXR commit 记录，STXR/CLREX/ERET commit 清 | sys v3，`addr=~0` invalid | restore valid/address/value；普通 fault 不更新 | `[implemented]`（单核） |
| Generic Timer | CNT 内部按提交计数；CTL/CVAL reset 0 | timer + QEMU VMState | timer sideband、QEMU offset；仅 1GHz/zero offset | `[implemented]`（非零 EL2 offset `[gap]`） |
| GICv2 前 96 IRQ | reset disabled/pending/active 清 | GIC sidecar + QEMU VMState | 控制/priority/位图注入；派生 priority 状态重建 | `[implemented]`（单核/96 envelope） |
| C++ MMIO fabric | reset 由 fabric 定义 | MMIO sidecar | fabric + `virt_ns_r` 同步恢复 | `[implemented]`（仅当前 fabric） |
| QEMU device VMState | 不属于 RTL reset | `*.dev.gz` | `-incoming exec:cat`，匹配 machine/CPU | `[implemented]`（已知 vmdescription warning） |
| RAM | reset data 不代表可见状态 | base/diff 4 KiB chain | inclusive apply 到临时 RAM，再灌入 DUT/QEMU | `[implemented]` |
| D-L1 dirty line | cache metadata reset invalid；不属于架构 | 不进入 sidecar | 保存前 8 beat drain 到 L2；restore invalidate/rebuild | `[implemented]` B4 endpoint；core-integrated `[gap]` |
| L2 dirty line/directory | metadata reset invalid；目录不进 sidecar | 不进入 sidecar | 保存前 drain 到 PoC；restore invalidate/rebuild | `[implemented]` 单核 WB；C2 `[gap]` |
| I-L1/fetch pending | 当前 fetch pending reset 清 | 不进入 sidecar | flush + new fetch epoch | `[required extension]`; catapult quiesce 未 gate I-L1 `[gap]` |
| TLB/MMU walk/PAR pending | 当前 core reset 清 walk/pending | 不进入 sidecar | invalidate/rebuild，不恢复在途 walk | `[required extension]`（epoch barrier `[gap]`） |
| MSHR/fill buffer | 当前未实现 | 禁止 sidecar | 保存前必须 0；restore 后 invalidate/stale quarantine | `[required extension]`，F3b gate |
| store buffer | 当前未实现 | 禁止 sidecar | 保存前 drain/PoC 可见；restore 后 empty | `[required extension]`，F3c gate |
| F1 fetch FIFO | 当前未实现 | 禁止 sidecar | 保存前 empty；restore 后 empty、新 fetch epoch | `[required extension]`，F1 gate |
| FP/NEON V/FPCR/FPSR | scalar path 默认 0；P7 V profile 才启用 | `LCVXFP01` 可选 | raw 128 bit 同 strobe；FP required 缺失拒绝 | `[implemented]` P7 boundary；core execution 非本任务 |
| SVE/SME Z state | 不支持 | 禁止伪造 sidecar | 必须 profile exclude 或另有批准格式 | `[gap]` / excluded |

## 8. Provenance、manifest 和 artifact atomicity

### 8.1 published marker

strict root 的初始 JSON 至少含：

```json
{
  "format": "LCVX-checkpoint-manifest-v2",
  "hash": "sha256",
  "page_size": 4096,
  "inputs": [{"role": "image", "path": "...", "size": 0, "sha256": "..."}],
  "qemu": {"path": "...", "size": 0, "sha256": "...",
           "version_file": {"path": "...", "size": 0, "sha256": "..."}},
  "artifacts": [],
  "status": "pending", "state": "pending", "lifecycle": "staging",
  "finalized": false, "complete": false
}
```

finalize 时追加/核对：`manifest_tsv_sha256`、`chain.entries/first_seq/last_seq`、
所有 artifact 的 path/size/sha256、strict context 的 artifact local/global
inclusive range，并把 status 变为 complete/finalized。`checkpoint.py:521-640`
实现了 pending reader gate、candidate 全量校验和 parent 递归绑定。

### 8.2 root/resume 绑定

- root：`provenance.kind=root` 且 `global_seq_offset=0`。
- resume child：必须包含 `parent_chain`、`parent_manifest_sha256`、`parent_seq`、
  `parent_local_seq`；parent manifest 必须 published，parent JSON SHA、输入角色
  size/SHA、非窗口 context 必须匹配。
- child global seq = `parent_global_seq + 1 + local_seq`；artifact range 是闭区间。
  `local_window_end` 可以是 exclusive context，但不能改变 row 的 inclusive 语义。
- parent 环、缺 row、缺 artifact、TSV/JSON/hash 任一不匹配都拒绝恢复或发布 child。

### 8.3 失败现场和保留

checkpoint/lockstep 失败至少保留：失败 seq、PRE/COMMIT、指令编码/反汇编、执行前
架构状态、DUT/QEMU 状态、最近提交窗口、checkpoint provenance（输入/CPU/profile/
restore paths）。`lockstep_coordinator.cc:301-326,2489-2512` 的 failure context
用于此目的。完整 RAM/trace/log 不进 Git，应留在 task artifact root。

当前 diff 链无 parent-safe 压缩/淘汰；总 artifact 超过 512 MiB 时拒绝发布而不删除
仍被引用的 parent。保留/压缩策略改变前必须新增任务和 regression evidence。

## 9. F1/F3/G5/C2 交叉接口门

### 9.1 F1 local fetch epoch

`F1` 的每个 fetch FIFO entry 必须保存 `{fetch_uid, fetch_age, reset_epoch, pc_va,
insn/fault}`。branch/exception/ISB 只 kill 年轻 age；reset/checkpoint restore
才 bump epoch。stale fetch response 可被消费丢弃，但不能写 FIFO、decode 或 IABT
commit。F1 必须共享 F3 的 reset epoch，而不是另起一条独立世代。

当前核心只有 `fetch_pending/fetch_translated/fetch_got_data/fetch_faulted` 一个
上下文，见 `docs/PERFORMANCE_F3_PREWORK.md:1.1`；因此 F1 FIFO/epoch 是
`[required extension]`，不是当前 restore 能力。

### 9.2 F3a transaction/epoch/age

F3a 必须把以下字段端到端放入 request/response/probe/line sideband：

```text
source_id[3:0]       0=PTW, 1=D, 2=I, 3=maintenance
transaction_id[7:0]  同 source/epoch 未终结前不得复用，0 和回绕必须测试
epoch[7:0]           冷 reset=0；warm reset/restore +1；wrap 进入 quarantine
age[15:0]            ID/EX 接收指令时分配；F3b oldest-first
beat_idx[2:0]        64B line 的 8 个 8B beat，普通事务为 0
```

`req_fire` 必须最终对应恰一个同 UID 的 `rsp_fire` 或 `cancel_fire`；旧 epoch
response 只消费丢弃，不改变 cache/pipeline/架构状态；同 epoch 错配是
`protocol_error`，停止新流量并保留诊断。F3a 深度仍为 1；未过 reset/checkpoint/
fault pairing gate 不得启动 F3b/F3c。

当前 `mem_req_t/mem_rsp_t` 和 arb/router/delay/RAM 没有此端到端字段；C2
`lcvex_cluster_top` 还将 `tie_cl_source/tie_cl_transaction` 全设 0
(`rtl/lcvex_cluster_top.sv:163-170,305-336`)。这是 F3a blocker。

### 9.3 F3b/F3c/G5

- F3b 只能在 F3a 通过后打开最多两个不同 line read MSHR；保存前 MSHR/fill/waiter
  全部归零，restore 后 invalidate。退休仍按 age oldest-first，不能把年轻 response
  直接提交。
- F3c 只有在所有 cache/PoC/Device BFM 都能证明 fault 前零外部字节副作用时才
  评估 1-entry store buffer；否则 store 只保留“未退休请求”槽，不进 sidecar，
  checkpoint 前 drain 到 PoC。
- G5 必须先公开同步 RAM read latency、single/simple-dual port、read-during-write
  和 byte-enable；没有这些不能把两个状态机称为真实双 miss。

### 9.4 CORE_COUNT=1 与多核 envelope

当前正式范围固定 `CORE_COUNT=1`。多核恢复的未来协议必须增加：

1. 每个 core 独立 req/ack/fault/epoch/commit window，所有 core 停止新请求并
   达到 pipeline/queue empty；
2. shared L2 directory 无 pending probe、唯一 M owner、S sharer 状态稳定，所有
   dirty owner 先返回/写至 PoC；
3. 全局 PoC drain 与一个 cluster-level success ack；任一 core fault 或目录 fault
   都取消整个 checkpoint；
4. restore 以同一 global epoch 同时 invalidate 所有 private/shared cache/TLB/
   monitor 的不可保存状态。

当前 C2 test 有 source/transaction 端口，但 cluster top tie-zero，且 C2 L1 wrapper
   没有 B4 checkpoint quiesce；因此多核不在本协议的可恢复声称内。

## 10. 现有测试映射（历史证据不等于本 SHA 新 PASS）

| 测试/文件 | 覆盖内容 | 能证明/不能证明 |
| --- | --- | --- |
| `tb/sv/lcvex_l1_d_wb_tb.sv:240-260` | local quiesce、dirty drain、quiesce 阻止 core request、fault 保留 metadata。 | `[implemented]` D-L1 endpoint；不证明 core pipeline/epoch。 |
| `sim/cocotb/test_l1_d_wb.py:185-227` | wrapper 成功 checkpoint、L1 done 先于 L2 request、PoC fault 无 success ack、释放后无 stale client rsp。 | `[implemented]` B4 定向；不证明实际 SoC 接线。 |
| `tb/sv/lcvex_l2_l1_probe_tb.sv:230-255` | L1→L2 顺序、ack backpressure hold、PoC fault negative、response accounting。 | `[implemented]` 联合 probe/drain；无 timeout/epoch。 |
| `docs/L1_L2_PROBE_CONTRACT.md` | dirty probe raw line hold、8 beat PoC 写完才释放、abort 保留 metadata。 | probe abort 契约；不覆盖 sidecar。 |
| `checkpoint_manifest_smoke.py` | input/artifact/TSV/chain SHA，artifact 篡改拒绝。 | manifest integrity；不覆盖真实 QEMU/DUT。 |
| `checkpoint_resume_manifest_smoke.py` | pending/final、parent hash、global/local seq、late provenance failure 原子拒绝。 | strict provenance fixture；不覆盖掉电级 bundle atomicity。 |
| `checkpoint_v4_struct_smoke.py` | v4 magic/version/size/contextidr，v3 540B compatibility。 | 结构兼容；明确没有完整 joint restore。 |
| `checkpoint_timer_smoke.sh`、`checkpoint_sys_smoke.sh`、`checkpoint_sys_v3_smoke.sh`、`checkpoint_gic_smoke.sh`、`checkpoint_mmio_smoke.sh` | 历史 QEMU/DUT sidecar 联合恢复样例。 | handoff 052/053/092/T-097 记录了历史通过；本任务未运行，不得写成本 SHA 新 PASS。 |
| `checkpoint_sctlr_mask_smoke.sh` | 脏 SCTLR 副本恢复、PAuth mask、原始 artifact/manifest 不变。 | 历史 restore mask/provenance；不覆盖 epoch/cache drain。 |
| `rtl/lcvex_core.sv` assertions、`lcvex_commit_backpressure_tb` | commit-only、WB hold、系统提交/异常提交边界。 | 核心提交不变量；不提供 checkpoint quiesce。 |
| `sim/difftest/run_lockstep_step.sh` / `run_lockstep_resume.sh` | CKPT_REQ/READY、strict manifest、resume 输入验证、QEMU incoming。 | P2 软件路径；当前没有 B4 hardware drain bridge。 |

本任务 docs-only，不运行上述 test。历史命令、SHA、版本和限制以
`docs/tasks/evidence/T-20260830-042.json` 为准。

## 11. 已知 gap、blocker 和停止条件

### 11.1 当前实现 gap

1. **P2 与 B4 未接通**：`tb/sv/lcvex_soc_tb.sv` 无 quiesce/drain 口；实际
   `DIFF_CKPT=1` 可在 D/I cache 或 shared memory 尚有事务时捕获。F3a checkpoint
   gate blocker。
2. **I-L1 未被完整 quiesce**：`lcvex_catapult_soc_coh` 的 checkpoint ready 只
   gate D/PTW (`rtl/lcvex_catapult_soc_coh.sv:180-200`)，I-L1 request path 未同等
   gate。新 fetch 可能越过 quiesce，必须修复并加负测。
3. **core pipeline drain 无公开接口**：当前 restore reset 可清 pipeline，但保存
   路径没有“无 commit/无 fetch/data/MMU pending”证明。
4. **epoch/UID/stale quarantine 未实现**：基础 memory ABI 无 ID/epoch；旧 response
   只能依赖 reset 清 pending，不能满足 F3a 端到端 pairing。
5. **timeout 未实现**：socket timeout、DUT per-insn timeout 不能替代 drain watchdog。
6. **artifact bundle 不是掉电级单事务**：逐文件 rename、legacy TSV append，且
   当前 final marker 由 run 结束时才写入；虽有 pending reader gate 和 candidate
   validate，仍需把每 checkpoint 的 bundle atomicity 与 QEMU ACK 顺序接通。
7. **arch/sys payload 未交叉校验**：当前 INIT 期望来自 arch、DUT 注入优先使用
   sys；同 row 不同内容尚无独立 reject。
8. **TLB/MMU/cache restore 只依赖 reset/invalidate 假设**：没有统一 epoch barrier
   或 cache/TLB empty ack；cache sidecar 未批准前不得保存脏 cache 声称可恢复。
9. **C1/C2/多核 envelope 缺失**：C1 tie-off drain，C2 source/transaction
   tie-zero；不能将多核 test 或 directory 状态纳入当前可恢复声明。
10. **FP/SVE 边界**：P7 只接受 canonical A76/V/16B/1GHz profile；SVE Z vector、
    非零 timer offset、P7 max adapter checkpoint 均拒绝或 excluded。
11. **v4 完整 joint restore 尚未形成本任务证据**：v4 struct smoke 仅结构 roundtrip，
    full QEMU/DUT smoke 由集成者资源窗口运行。

### 11.2 F3/F1 必须停止的条件

遇到任一条件，关闭对应 feature、保留失败现场，并重新登记 regression task：

- 一个 UID 出现零次/两次 response，response hold 时 payload/ID/epoch 改变，或
  stale epoch 改变 cache/pipeline/架构状态；
- 年轻 fault/commit 越过老 age，或 commit_ready=0 时架构/monitor/store retire
  pointer 改变；
- D-L1/L2 dirty metadata 在全部 PoC beat 成功前清除，probe abort 后 line 丢失，
  或 success ack 与任何 fault 同时可见；
- checkpoint quiesce 后仍接受新 fetch/data/PTW/Device request，或 restore 后
  旧 response 进入新 epoch；
- store fault 前出现外部字节副作用，STP/LSE partial effect，或未经 validated
  的 store forwarding；
- manifest pending 被恢复、parent/source/image/tool/hash 不匹配仍被接受、或不同
  SHA 的 sidecar/测试被拼接成证据；
- 任一未实现 MSHR/store buffer/fetch FIFO 被写入 sidecar，或以单状态机假装
  `two-real-miss`；
- C2 目录出现多 M owner、S 与 owner 冲突、probe/PoC fault 后状态不一致。

### 11.3 解门条件

F3a checkpoint gate 只有在以下条件全部有同一 merge SHA 的 L0-L2 证据后才能解除：

1. explicit request/quiesce/ack/fault/timeout 语义和保持断言落地；
2. core/F1 fetch、MMU/PTW、arb/router/delay/RAM、D-L1/L2/PoC 共享 epoch/UID，
   DEPTH=1 下一 UID 恰一次终结；
3. pipeline/transaction drain 在实际 SoC lockstep path 接通，I-L1 不再越过 quiesce；
4. L1 dirty drain→L2/PoC drain→success ack 顺序、probe abort、fault negative、
   ack backpressure 全部通过；
5. restore reset/flush、epoch bump、stale quarantine、cache/TLB invalidate、
   system/timer/GIC/monitor/FP sidecar 顺序和 INIT/FP_INIT 检查通过；
6. manifest pending/final、parent/source/image/tool/hash、seq window 和失败现场
   在同一 SHA 可重放，且 artifact bundle atomicity 的已知限制被显式接受；
7. F3b 之前公开 G5 synchronous RAM contract，F3c 之前完成 store fault all-or-nothing
   证明，F1 之前完成 local fetch epoch 交叉接线。

在上述门完成前，当前唯一安全声称是：B4 standalone drain/probe 契约和 P2
sidecar/manifest 工具各自按其历史 evidence 工作；不能声称“整个核心 checkpoint
已原子保存并可无 stale restore”。
