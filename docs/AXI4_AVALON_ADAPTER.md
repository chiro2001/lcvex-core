# B2-EMIF AXI4 到 Avalon-MM 适配层

状态：模块级 review candidate（T-20260827-054）。本实现只覆盖通用
AXI4 Full 128-bit 到 Catapult EMIF 512-bit Avalon-MM 的独立适配层，不接入
CPU、Cache、L2、SoC、filelist 或 Quartus 工程。

## 固定接口契约

| 项目 | 规则 |
| --- | --- |
| AXI 数据 | 128 bit，16 byte/beat；单 ID、单 outstanding |
| 合法请求 | `BURST=INCR`，`LEN<=3`，`SIZE<=4`；每个 beat 和整个 burst 均在一个 64B line 内 |
| AXI 窗口 | `0x40000000 <= addr < 0x48000000`，窗口大小 128 MiB |
| Avalon 数据 | 512 bit，64 byte/word，`addressUnits=WORDS` |
| 地址换算 | `avalon_address=(axi_addr-0x40000000)>>6`；最大合法 word address 为 `0x1fffff` |
| Avalon burst | `burstcount=1`，一次请求对应一个 64B word |
| Avalon error | Qsys端没有error/response；在有界时间内完成的正常读写映射AXI `OKAY` |
| 本地错误 | 地址/窗口、burst/line、校准失败、EMIF-only reset和backend timeout映射`DECERR` |
| 后端timeout | 生产默认4096个EMIF周期（266.666750 MHz下约15.36 us）；focused TB显式使用32周期 |

AXI AW 与 W 独立握手，W 可以早于 AW 到达；适配器收齐 AW 和 `WLAST` 后才
生成一个 Avalon 写请求。跨 64B line 的请求不会被拆分，而是在 AXI 侧返回
本地 `DECERR`。读请求只发一个 512-bit line read，等待独立的
`readdatavalid` 后在 CPU 域拆回原 AXI beat 数。

## 数据和 byteenable

对于 canonical 对齐 line，beat 0 映射到 `writedata[127:0]`、
`byteenable[15:0]`，beat 3 映射到 `[511:384]`、`[63:48]`。每个有效 AXI
byte 的目标位置是该 byte 在 64B line 中的 offset；因此四个 full beat 的
Avalon byteenable 为 `64'hffff_ffff_ffff_ffff`。

B1 profile 的窄访问把 WDATA/WSTRB 放在 AXI 128-bit bus 的地址 lane；适配器
按 `axi_addr[3:0]` 还原到 line offset。例如 `addr=line+2`、两字节
`WSTRB[3:2]` 会产生 `byteenable[3:2]`。为便于独立平台模型复用，也接受
WSTRB/data 位于 beat 低 lane 的规范化窄写，并将其按 line offset 平移。读回
则保留 AXI bus lane，和 B1 BFM 语义一致。

读 byteenable 使用全 1：EMIF 读取完整 64B line，再由 AXI 侧按请求地址、
SIZE 和 beat 序号选出 128-bit bus word。Avalon 的 `read`/`write`、address、
`writedata`、`byteenable` 在 `waitrequest_n=0` 期间保持不变，只在
`waitrequest_n=1` 的时钟边沿接受。

## CDC、reset 和 calibration

请求FIFO从CPU域到EMIF域，响应FIFO反向跨域，均使用注册Gray pointer和两级同步。
FSM reset与FIFO epoch reset分离：CPU FSM只由`cpu_rst_n`复位，因此EMIF-only
reset不会抹掉已经接受的AXI事务；EMIF FSM由本域reset控制。两个FIFO仍在remote
reset或calibration failure时开始新epoch，旧packet不能成为新事务响应。

- `emif_reset_cpu_meta_q -> emif_reset_cpu_sync_q`把EMIF reset同步到CPU域；已完整
  接受并进入SEND/WAIT的读写返回一次`DECERR`。已经呈现的`BVALID/RVALID`及
  ID/data/RESP/RLAST不受后续reset/cal_fail影响，保持到READY握手。
- `cpu_rst_emif_meta_q -> cpu_rst_emif_sync_q`在EMIF域同步采样CPU reset，且不由
  EMIF-only reset清除；两级power-up值为0。CPU reset至少跨越两个EMIF采样沿后，
  才作为retained epoch的明确re-arm边界。
- `emif_poisoned_q -> emif_poisoned_cpu_meta_q -> emif_poisoned_cpu_q`阻止CPU在
  late-response drain完成前接受新事务。已接受读超时后进入`EMIF_DRAIN`；迟到
  `readdatavalid`只被丢弃，不生成第二个response。若后端永不返回，link保持
  poison直到明确CPU reset，优先保证不串epoch而不是冒险继续。
- AW和W独立握手。EMIF-only reset发生在只收集到其中一个channel时，收集状态暂停；
  因为完整事务尚未送入backend，reset释放后继续接收匹配channel并恰好完成一次。
- `cal_success=0 && cal_fail=0` 时 AXI 新请求全部反压。
- `cal_fail`在EMIF source domain粘滞并同步到CPU域；在途完整事务返回一次
  `DECERR`，故障后的新请求只走本地`DECERR`，不发Avalon，直到reset清除。
- Avalon命令等待接受、以及已接受read等待`readdatavalid`，均受
  `AVALON_TIMEOUT_CYCLES`约束。未接受write timeout没有外部副作用；已接受read
  timeout返回一次`DECERR`并进入上述drain/poison状态。
- 没有新增系统寄存器；校准状态是平台输入 pin，读写权限和 commit 时机不适用。

## 文件和验证入口

实现文件：

- `rtl/lcvex_axi4_avalon_pkg.sv`：窗口、line、地址单位和 canonical 常量；
- `rtl/lcvex_axi4_avalon_adapter.sv`：AXI collector、line 聚合、Avalon FSM、
  CDC packet 和内置独立 Avalon SVA checker；
- `rtl/lcvex_async_fifo.sv`：双时钟 FIFO；
- `rtl/lcvex_calibration_gate.sv`：校准状态同步和 sticky fail。

独立 BFM/TB 只模拟 Avalon user port，不引入 Qsys error port：

```sh
conda run --no-capture-output -n lcvex verilator --binary --timing --assert -Wall \
  --top-module lcvex_axi4_avalon_tb \
  -Mdir build/agents/T-20260827-054/sv/obj_dir \
  -o lcvex_axi4_avalon_tb \
  rtl/lcvex_axi4_pkg.sv rtl/lcvex_axi4_avalon_pkg.sv \
  rtl/lcvex_async_fifo.sv rtl/lcvex_calibration_gate.sv \
  rtl/lcvex_axi4_avalon_adapter.sv tb/sv/lcvex_axi4_avalon_bfm.sv \
  tb/sv/lcvex_axi4_avalon_tb.sv
build/agents/T-20260827-054/sv/obj_dir/lcvex_axi4_avalon_tb
```

```sh
conda run --no-capture-output -n lcvex make -C sim/cocotb \
  -f Makefile.axi4_avalon \
  SIM_BUILD=/home/chiro/projects/mycpu/lcvex-wt-T-20260827-054/build/agents/T-20260827-054/cocotb \
  SEED=0x00b2054
```

SV 与 Cocotb 都启用 Verilator `--assert`，覆盖地址/窗口、跨线DECERR、4-beat
聚合、byteenable、active-low waitrequest、独立readdatavalid、随机双时钟、
calibration failure held response、永久stall/missing response timeout、late drain、
EMIF-only reset、AW/W部分收集跨reset、不同ID/地址/数据的新epoch及无重复/丢失。
Quartus/Qsys regenerate、STA、EMIF 实物校准和板级 DDR 测试不在本任务范围。
