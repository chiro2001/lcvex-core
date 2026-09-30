# LCVEX 交接文档 087：C++ MMIO fabric 迁移决策

日期：2026-08-25（Asia/Shanghai）
前置：`085-linux-daif-irq-commit.md`
分支：`feature/p6-system-reg-shim`
本记录的实现已拆分为独立提交：

- `d949d0b isa: add LDPSW pair load`
- `6b7c41f difftest: report translated data address on failure`
- `soc: add PL061 GPIO for QEMU virt`（本记录所在提交）

## 当前状态

- 上述提交完成后工作树应保持干净；
- 当前没有 QEMU、Verilator coordinator 或 runner 后台进程；
- 根盘 `build/tmp` 可用约 80 GiB，`/tmp` 可用约 6.5 GiB；
- 不要重编译 Linux lite Image。`.config` 不包含
  `CONFIG_GPIO_PL061`、`CONFIG_RTC_DRV_PL031` 或 fw_cfg/virtio driver；
  继续使用 `build/difftest/linux-lite/Image` 与现有 initramfs。

## 已闭环的最近 P6 缺口

已提交的 `f8cd28e`、`449dd8f`、`e98e186` 分别完成：39 位 PTW 起始级别、
checkpoint FDT/恢复目录一致性、debug-monitor 关闭 shim、以及 MSR DAIF
写后立即接受 pending IRQ。

### LDPSW

Lite 在本地 `seq=1952525` 首次执行：

```text
694d0c04  ldpsw x4, x3, [x0, #104]
```

工作区已支持其 `size=01` pair-load 编码、两段 32 位读和两侧符号扩展到
X 寄存器。最初定向测试把 LDPSW 放在故意 DABT 之后而未覆盖，已改放到
DABT 前。验证：

```text
bash sim/difftest/run_m2_4b.sh --only hard_pair_ldst
  PASS：base 35 条、I+D+L2 35 条
```

新的 lite 恢复已跨过该编码，下一缺口是 PL031 MMIO。

## 实际 DTB 设备清单

主线 `build/difftest/qemu-fdt-raw.bin` 与 lite 实际加载 DTB 的设备集合
一致。实际窗口：

| PA 窗口 | QEMU virt 节点 | 当前状态 |
| --- | --- | --- |
| `0x08000000..0x08020fff` | GICv2 + v2m | 原生 RTL |
| `0x09000000..0x09000fff` | PL011 | 原生 RTL |
| `0x09010000..0x09010fff` | PL031 RTC | 未实现，下一个实际缺口 |
| `0x09020000..0x09020017` | fw_cfg | 未实现 |
| `0x09030000..0x09030fff` | PL061 GPIO | 原生 RTL（已接入） |
| `0x0a000000..0x0a003fff` | 32 个 virtio-mmio slot | 未实现 |
| `0x10000000...` | PCIe ECAM | 未实现 |
| `0x00000000..0x07ffffff` | CFI flash banks | 未实现 |

DTB 还有 PSCI、Generic Timer、PMUv3 等非普通 MMIO 节点。

## 已确认的架构决策：C++ MMIO fabric

用户确认不应为全部 QEMU virt 设备逐个写 SystemVerilog，采用：

```text
RTL core/MMU/cache
        ↓ M1-B MMIO bridge
Verilator 链接的 C++ MMIO fabric
  ├── 原生 RTL：GIC、Generic Timer、PL011、PL061 GPIO
  ├── C model：PL031、fw_cfg、日后按需 virtio
  └── 未建模地址：可复现 fault（记录 PC/PA/宽度/读写）
```

不能让正在锁步的同一 QEMU 直接充当同步 MMIO 从端：协议是 DUT 先执行、
QEMU 后执行，DUT load 在 QEMU 产生读值前必须完成。

- QEMU trace/replay 只作开发期 oracle，校验 C model 的访问语义；
- standalone Verilator、Cocotb、microbench 必须直接链接 C++ model，不依赖
  runtime QEMU；
- replay fixture 可用于定向测试，但不得作为 Gate E 的唯一设备实现；
- FPGA/P10 时 C bridge 由 RTL/板级外设替换，核心提交协议不变。

下一实现建议：先做 `sim/mmio/` 的 DPI/C++ fabric 骨架和 Verilator/Cocotb
统一链接入口；以 PL031 ID/基础寄存器作第一个 C model。不要继续创建 PL031
SystemVerilog 模块。

**确认决策**：PL061 保留为原生 RTL，不迁移到 C fabric。它是小型、可综合
且与 FPGA pin 有直接对应关系的外设；P10 时扩展其 8 个 GPIO 输入/输出并把
`gpio_irq` 接入 GIC SPI7。当前 P6 无板级输入，故保持无 pending IRQ 的模型。

## 最近 checkpoint 与失败现场

### Lite

- 已正式通过累计基线：从 reset 至少 12.5M 条（handoff 085）；
- LDPSW 后有效 checkpoint：
  `build/tmp/linux-lite-6.6/long-ldpsw-v2-20260825/chain/diff-3199999`；
- PL061 试跑在 PL031 PID0 访问失败：

```text
PC=0xffffffc0801f06f8
insn=b9400082  ldr w2, [x4]
VA=0xffffffc080008fe0 -> PA=0x09010fe0
QEMU=0x31 (PL031 PID0)
RTL=external DABT FSC=0x10
```

- 最近失败前链：
  `build/tmp/linux-lite-6.6/long-pl061-20260825/chain/diff-199999`。

### 主线

- IRQ 修复后已通过完整 5M 窗口：
  `build/tmp/linux-main-postirq-20260825/chain/diff-4999999`；
- PL061 试跑同样停在 PL031，失败前可用：
  `build/tmp/linux-main-pl061-20260825/chain/diff-499999`；
- 主线失败也是 `ldr w2,[x4]` 到 `PA=0x09010fe0`，QEMU PID0=0x31、RTL
  external DABT。

## 本次提交内容

```text
Makefile
rtl/filelist.f
rtl/lcvex_core.sv
rtl/lcvex_decode.sv
rtl/lcvex_mem_router.sv
rtl/lcvex_mmu.sv
rtl/lcvex_pl061.sv                 # 原生 GPIO RTL
sim/difftest/a64.py
sim/difftest/lockstep_coordinator.cc  # data PA 失败诊断
sim/difftest/run_gate_d.sh
sim/difftest/run_m2_4b.sh
sim/difftest/test_program.py
tb/sv/lcvex_pl061_tb.sv             # GPIO 独立 SV testbench
tb/sv/lcvex_soc_tb.sv
```

提交前后的已验证结果：

```text
make sim-sv-pl061                         PASS
bash sim/difftest/run_m2_4b.sh --only hard_pl061  PASS（base/cache，各20）
bash sim/difftest/run_m2_4b.sh --only hard_pair_ldst PASS（base/cache，各35）
make compile                              PASS
make lockstep-build-kernel                PASS
```

2026-08-25 复验补充：上述 PL061 单元测试、`hard_pl061` 和
`hard_pair_ldst`（base、I+D+L2）均再次通过，`make compile` lint 通过。
PL061 的 P10 接口边界已记入 `ISA_SCOPE.md` 与 `FPGA_PLAN.md`：P6 顶层保持
固定下拉输入以保障 QEMU 锁步确定性；具体板卡顶层再映射 8 个 GPIO pin，且将
`gpio_irq` 连接至 GIC SPI7（INTID 39）。

PL061 已确认保留为原生 RTL。仍需从 PL061 probe 前 checkpoint 做 lite 实跑，
形成平台路径证据；此路径会继续在 PL031 PID0 读取处停下，直到 C++ MMIO
fabric 的 PL031 模型接入。PL031 不继续写 SystemVerilog。

## 压缩后的首条命令

```sh
git status --short --branch
sed -n '1,260p' docs/handoffs/087-cmodel-mmio-pivot-20260825.md
ps -eo pid,psr,pcpu,pmem,rss,stat,args | rg -i 'qemu|verilat|lockstep' || true
df -h build/tmp /tmp
```
