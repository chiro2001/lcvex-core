# C4 CORE_COUNT=2 Baseline Measurement

> 任务：T-20260829-103（C4 dual-core baseline）
> 分支：`feature/T-20260829-103-c4-dualcore-baseline`
> 基线 SHA：`2a697bb922e6e7af353d399b2f0e6f6bb26d150c`
> 状态：**baseline only，不代表 4/8/16/32 核功能完成**

## 配置

| 项目 | 值 |
| --- | --- |
| CORE_COUNT | 2 |
| COHERENCE_ENABLE | 1 |
| CORE_ID_W | 4 |
| SOURCE_ID_W | 4 |
| TRANSACTION_ID_W | 8 |
| LINE_BYTES | 64 |
| L1_SETS | 64 |
| L2_SETS | 256 |
| L2_WAYS | 2 |
| MEM_DEPTH | 1 << 16 |
| CLUSTER_MEM_LINES | 1024 |
| SHARER_W | 2（位图） |
| OWNER_W | 2（one-hot 位图） |
| ARB_MODE | FLAT_RR（全局 round-robin + liveness fallback） |
| REQ_QUEUE_DEPTH | 1（每核单 outstanding） |
| PER_BANK | false |
| POC_BEATS | 8（64B line / 8B beat） |
| POC width | M1-B 64-bit data per beat |

## 环境与资源限制

- 工具：Verilator `5.050`
- 构建并发：`-j 1`，一次只跑一个重型构建
- 内存限制：
  ```bash
  systemd-run --user --scope --quiet \
    -p MemoryMax=16G -p MemorySwapMax=0 -- <command>
  ```
- 测量方法：Python `resource.getrusage(RUSAGE_CHILDREN)` 记录 maxrss，`time.time()` 记录 wall time；Verilator 报告中的 `Walltime`/`allocated` 同时记录。
- **隔离说明**：测量期间另一个会话存在无关的 C3 four-core Verilator 构建（非本任务启动）。本任务自身仍遵守一次一个重型构建、`-j 1` 和 cgroup 限制；如需严格无干扰基线，建议在无其它重型构建的安静窗口重跑。

## 测量结果

### 编译 / elaboration

| TB | wall | max RSS | Verilator Walltime | Verilator allocated | 结果 |
| --- | --- | --- | --- | --- | --- |
| `lcvex_c2_l1_msi_tb` | 24.046 s | 434.5 MB | 22.928 s | 48.188 MB | pass |
| `lcvex_c2_dualcore_tb` | 371.038 s | 3364 MB | 369.680 s | 814.473 MB | pass |

- L1MSI 为 lightweight synthetic client 路径。
- DUALCORE 为完整 `lcvex_core` 路径，是当前 CORE_COUNT=2 的主要 Verilator 成本。
- 两次构建均在 `MemoryMax=16G` cgroup scope 下完成，未触顶。

### 有限事务 smoke

| TB | wall | RSS | 通过 | 说明 |
| --- | --- | --- | --- | --- |
| `LCVEX_C2_L1_MSI_TB` | 0.018 s | 15.6 MB | 28 PASS checks | 覆盖 read/write/upgrade/writeback/clean-invalidate/bypass/atomic-like |
| `LCVEX_C2_DUALCORE_TB` | 0.020 s | 15.7 MB | 51 commit events | 双核 message-passing，两核均读到 0x5A |

### 目录 / 仲裁 / PoC proxy

| Proxy | CORE_COUNT=2 值 |
| --- | --- |
| dir_sharers 位宽 | 2 bit |
| dir_owner 位宽 | 2 bit（one-hot） |
| dir_pending | 1 bit/line |
| 仲裁拓扑 | FLAT_RR |
| 每核 outstanding | 1 |
| 全局事务 | 单事务 |
| PoC beat 宽度 | 64 bit |
| 每 line PoC beats | 8 |
| refill/writeback beats | 8 |
| probe target | 单目标逐事务（C2 仅有 1 个其它核） |
| 最大 sharer 数 | 2 |

## 结论

- CORE_COUNT=2 baseline 可编译、可运行，默认 Verilator 优化且带 assert。
- 完整双核 Verilator 构建约 371 s、峰值 RSS 约 3.3 GB（cgroup 限制内）。
- 目录位宽/仲裁/PoC proxy 均与 C2 当前单事务模型一致。
- 本报告是规模测量起点，不代表 4/8/16/32 核已功能完成。
- 未修改 RTL/TB 功能，未启动 Quartus，未触碰 T-067。
