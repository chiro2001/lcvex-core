# B4-L1-Coherence 模块级实现

T-20260827-056 提供一个独立可验证的 D-L1 write-back/write-allocate 与
包容式 L2 candidate。入口是 `rtl/lcvex_l1_coherence.sv`，它不修改 core、
package、filelist、SoC 或现有 write-through `lcvex_l2_tb`。

## 结构和状态边界

```text
core ─┐
      ├─ PTW 优先仲裁 ─ D-L1 WB ─ L2 WB ─ PoC BFM
PTW ──┘                    ↑       │
                           probe ←─┘
```

`lcvex_l1_d_wb` 是 64B line、8 个 8B beat、单阻塞直接映射 D-L1：

- 读 miss 和写 miss 都完整 refill；写 miss 在 refill 完成后按 `strb` merge；
- 写 hit 只改 D-L1 并置 dirty，不产生 write-through；
- dirty victim 的 8 个写 beat 全部成功前保留旧 valid/tag/dirty；
- refill fault 不发布新 tag/valid，writeback fault 可重试；
- bypass 请求直通下游，不分配/污染 cache。

L2 的 `L1_PROBE_ENABLE=1` 模式在有效 victim 或 line maintenance 前主动查询
D-L1，详细 ready/hold/abort 语义见
[`L1_L2_PROBE_CONTRACT.md`](L1_L2_PROBE_CONTRACT.md)。旧 B3 standalone
testbench 默认 `L1_PROBE_ENABLE=0`，因此保留原有 L2-only 回归；B4 wrapper
显式打开该端口。

## PTW、维护和 checkpoint

PTW 与 core 共享 D-L1 时 PTW 固定优先，故对同一 PA 的页表读可以看到 D-L1
脏行中的最新 bytes，而不是绕过到 PoC 的旧副本。DC line maintenance 在
D-L1 完成本地 dirty writeback 后由 wrapper 再发送到 L2；L2 进一步 probe
D-L1 并完成 clean/invalidate。IC IVAU/IALLU 不修改 D-L1 data，wrapper 保证
它们在此前的 DC 流程完成后才到达 L2。

checkpoint 是 level protocol：`checkpoint_quiesce` 阻止新 core/PTW request；
D-L1 扫描并下刷 dirty line，`l1_drain_done` 成功后 wrapper 发
`drain_to_poc`，L2 全阵列下刷成功才产生 `checkpoint_ack_valid`。ack 在
ready 前保持。fault/reset 只产生 fault 状态，不产生成功 ack，并保留未完成
line 的 metadata。

## Reset / 权限 / 提交点

本模块没有新增架构系统寄存器。Cache metadata 的 reset 值为：`valid=0`、
`dirty=0`、`tag=0`；状态为 idle；响应 valid/事务身份为 0。D-L1 probe 的
lookup 不改状态，clean/invalidate 仅在 response handshake 且未 abort 时提交。
正常 store 在 D-L1 hit 的请求接受周期锁存请求并置 dirty，masked data
write 在随后的写状态采样；victim writeback、refill 和维护操作仅在完整响应
成功的状态边界更新 metadata。

## Cache data RAM 实现

D-L1 data array 以 set 为地址、每条 64B line 为 packed 512-bit RAM word，
逐字节写使能覆盖 partial store 和整行 refill。`rtl/lcvex_cache_data_ram.sv`
在 Verilator 下提供同步读的 packed-line 行为模型，在 `SYNTHESIS` 下显式使用
`altera_syncram`（`SINGLE_PORT`、512-bit、64 byte-enable、A10 `M20K`）。
`ST_DATA_RD_REQ/ST_DATA_RD_WAIT` 保证命中读、dirty victim 写回和 probe payload
都等待 RAM 数据有效；`ST_DATA_WR`/提交状态才采样 masked line write。data RAM
不复位，reset 只清 metadata 和事务状态；同址读写为 RAM primitive 的
`DONT_CARE` 碰撞，cache FSM 不并发发起这两类操作。

## 独立验证入口

SV 联合 testbench：

```sh
mkdir -p build/agents/T-20260827-056/obj_dir_joint_final
conda run --no-capture-output -n lcvex verilator --binary --timing --assert \
  -Wall -Wno-fatal -j 2 --top-module lcvex_l2_l1_probe_tb \
  -Mdir build/agents/T-20260827-056/obj_dir_joint_final \
  -o lcvex_l2_l1_probe_tb rtl/lcvex_pkg.sv rtl/lcvex_l2_wb.sv \
  rtl/lcvex_l1_d_wb.sv rtl/lcvex_l1_coherence.sv \
  tb/sv/lcvex_l1_d_wb_bfm.sv tb/sv/lcvex_l2_l1_probe_tb.sv
build/agents/T-20260827-056/obj_dir_joint_final/lcvex_l2_l1_probe_tb
```

L1 单元和 Cocotb 入口分别由 `tb/sv/lcvex_l1_d_wb_tb.sv` 与
`sim/cocotb/Makefile.l1_d_wb` 提供。大日志和构建产物仅保存在
`build/agents/T-20260827-056/`，不进入 Git。

## 已知限制

这是模块级 `CORE_COUNT=1` candidate：不接入 `core/pkg/decoder`、I-L1/SoC、
QEMU、AXI4/EMIF、真实 SRAM 或 Gate D/F；不实现多核 MESI/ACE/CHI、coherent
DMA、完整 TLBI shootdown。进入系统一致性验收前仍需集成者在合并 SHA 重新接线
并运行全 Cache/QEMU/Gate F-MEM 套件。
