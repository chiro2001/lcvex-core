# T-20260829-096 B3 CONTEXTIDR / 系统寄存器 probe handoff

- 任务 ID：T-20260829-096（B3 remainder probe）
- 状态：review（owner 交付；等待集成者复核/合并）
- 分支：`feature/T-20260829-096-b3-contextidr-probe`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-088`
- base SHA：`409c6fa0ac893a647f2fd1053b1ac2e5bedb9360`
- sent_at：2026-08-29T13:00:00+0800（约）
- received_at：2026-08-29T13:05:00+0800（约）
- reported_at：2026-08-29T13:15:00+0800

## 实现：CONTEXTIDR_EL1

新增 AArch64 系统寄存器：

- 编码：`S3_0_C13_C0_1`
- 访问：EL1 读写；EL0 未列入豁免 -> UDEF
- reset：0
- 行为：MSR 写入保存在 core 内部 `contextidr_el1`；MRS 返回该值。
- 未实现 TLB/ASID 副作用；当前 TLB 以 VA 匹配，不依赖 CONTEXTIDR/ASID。

改动：
- `rtl/lcvex_pkg.sv`：`SREG_CONTEXTIDR_EL1`
- `rtl/lcvex_decode.sv`：解码 tuple、MRS 读值路径、MSR 方向
- `rtl/lcvex_core.sv`：状态信号、reset=0、decode 连接、MSR 写回
- 所有解码器级 TB 增加 `.contextidr_el1` 连接
- `tb/sv/lcvex_b3_sysreg_access_tb.sv` 增加 MRS/MSR 定向

## Checkpoint / sidecar 评估

当前 `LCVXSYS3` 单核系统 sidecar 未包含 `CONTEXTIDR_EL1`。完整 checkpoint
恢复该寄存器需要：

1. 扩展 DUT `DutSysState` / `SYS_STATE` 到 v4，增加 `contextidr_el1` 字段；
2. 修改 `sim/difftest/checkpoint.py` 和 `sim/difftest/lockstep_coordinator.cc`
   的读写/兼容逻辑；
3. 修改 QEMU fork 的 `lcvex_difftest` plugin，使其从 QEMU `CPUARMState`
   序列化该字段；
4. 升级 sidecar magic/version 或做 v4 兼容读取。

以上属于 QEMU fork / checkpoint 协议全局串行写集。本切片**未修改**
QEMU、checkpoint 格式或协调器；只实现 live core/decoder 状态。当前 checkpoint
恢复时 `CONTEXTIDR_EL1` 会回到 reset 0，这是已知限制，已在 handoff 明确列出。
若后续需要完整恢复，建议单独任务只做 sidecar v4 升级，并串行执行。

## 系统寄存器 probe 结论

在现有代码上完成了 V82-BASE + V82-SELECTED-EXT 的系统寄存器/维护/原子
矩阵补测；没有新增全量 QEMU inventory 脚本运行，因为基础 QEMU 已有稳定
参考，且改动不涉及新 QEMU oracle。审计结果：

| 类别 | 状态 |
| --- | --- |
| EL1 常用系统寄存器 | 已实现并定向（含 CONTEXTIDR 本次新增） |
| OSLAR/OSLSR/OSDLR debug shim | 已实现读写权限 |
| Generic Timer EL0 gate | 已实现 EC=0x18 |
| IC/DC/TLBI/AT | 已实现 V82 批准矩阵 |
| LSE scalar / CAS / exclusive / barrier | 已实现标量矩阵 |
| `DC CVADP`、TLBI OS/RV/range、EL2/EL3 | 后置/未实现 |

## 验证

```text
# decoder lint
timeout 120 conda run --no-capture-output -n lcvex \
  verilator --lint-only --timing -Wall -j 2 --top-module lcvex_decode \
  rtl/lcvex_pkg.sv rtl/lcvex_decode.sv
# RC=0

# full compile
timeout 120 make compile
# RC=0；Verilator Walltime 42.105s

# sysreg access TB
...Vlcvex_b3_sysreg_access_tb
# PASS：包含 CONTEXTIDR MRS/MSR，OSLAR/OSLSR/OSDLR

# atomic/barrier TB
...Vlcvex_b3_atomic_barrier_tb
# PASS

# maintenance TB
...Vlcvex_b3_maint_decode_tb
# PASS

# barrier TB
...Vlcvex_b3_sys_decode_tb
# PASS
```

全部使用默认 Verilator 优化，未使用 `-O0`。

## 剩余缺口

| 项目 | 状态 |
| --- | --- |
| CONTEXTIDR checkpoint/sidecar | 未实现；需要 QEMU plugin + sidecar v4 全局修改 |
| 全量 QEMU sysreg inventory 离线 JSON | 未在本切片生成；可后续用 `scripts/qemu_sysreg_inventory.py` 跑 |
| `DC CVADP` | POST-V82-DEFERRED |
| TLBI OS/RV/range、EL2/EL3 维护 | 后置 |
| RCpc `LDAPR/LDAPUR` | POST-V82-DEFERRED |
| 其它 LSE128 | C 线 / POST-V82 |
| PMU | P9 |

## 下一步

1. 集成者复核；若需要 checkpoint 完整恢复，请安排独立 QEMU/sidecar v4 任务。
2. 可在资源窗口跑 `scripts/qemu_sysreg_inventory.py`，但需额外处理输出分类。
