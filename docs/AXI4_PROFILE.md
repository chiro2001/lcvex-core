# LCVEX B1 AXI4 Full profile

状态：B1 owner review candidate（独立模块级 L0/L1 已通过，尚未接入 L2、CPU 或平台）。

本文件定义 `rtl/lcvex_axi4_master.sv` 的平台无关命令边界，以及
`tb/sv/lcvex_axi4_bfm.sv` 的独立验证模型。接口使用标准 AXI4 Full 的
AW/W/B/AR/R 五个通道；本任务不包含缓存层次、处理器接线、时钟域切换或板级适配。

## 参数与 canonical 配置

| 参数 | 默认值 | 约束/含义 |
| --- | ---: | --- |
| `ADDR_WIDTH` | 64 | 12–64；地址低 12 位用于 4 KiB 检查 |
| `DATA_WIDTH` | 128 | 8–1024 bit；字节数必须是 2 的幂 |
| `ID_WIDTH` | 4 | AW/AR ID 与 B/R ID 的宽度 |
| `MAX_BURST_LEN` | 16 | 上游支持的最大 beat 数，范围 1–256 |

LCVEX canonical 为 `DATA_WIDTH=128`、16 byte/beat。64B cache line 由
`LEN=3`、`SIZE=4`、`BURST=INCR` 表示，即四个连续 beat；一次 burst 的总字节数
不能跨越 4 KiB 边界。首版只接受一个 command、一个 ID、一个 outstanding，
但不会从通道中删除 `ID/LEN/SIZE/BURST/RESP/LAST`。

## 上游 command/response 边界

一次 `req_valid && req_ready` 接受一个读或写 burst：

- `req_write=1` 产生 AW/W/B；`req_write=0` 产生 AR/R。
- `req_addr` 是首 beat 地址；`req_len` 是 AXI `LEN`（beat 数减一）；
  `req_size` 是每 beat 字节数的 log2；首版 master 只产生 `INCR`。
- `req_wdata[n*DATA_WIDTH +: DATA_WIDTH]` 和
  `req_wstrb[n*DATA_WIDTH/8 +: DATA_WIDTH/8]` 是第 n 个 W beat，低 beat
  优先。窄写时，payload 和 strobe 放在对应 data-bus byte lane。
- 读响应按 R beat 输出 `rsp_valid/rsp_rdata/rsp_resp/rsp_last`；写响应输出
  一个 B 结果，`rsp_write=1` 且 `rsp_last=1`。响应 ID 原样返回。
- `rsp_ready=0` 时 master 不消费 B/R；下游的 VALID/payload 保持责任由通道
  协议和 SVA 共同检查。

非法 `BURST`、超出 master 容量的 `LEN`、超过 data bus 的 `SIZE` 或跨 4 KiB
的请求，在 command 被接受后产生一个本地 `DECERR`：写请求是单个 B-like
响应，读请求是一个 `R-like` 响应并置 `rsp_last=1`，不会发出非法 AW/AR。

## 五通道语义

AW 和 W 的 VALID 独立产生，master 可以先完成任一通道；每个通道在 READY
为低时保持 VALID 及全部 payload。W beat 只在 `WVALID && WREADY` 时推进，
最后一个 beat 置 `WLAST`。收到完整 AW/W 后等待唯一 B 响应；收到 AR 后逐 beat
消费 R，只有 `RLAST` 握手后才释放 outstanding。

标准 sideband `LOCK/CACHE/PROT/QOS` 在首版由 master 置零并完整暴露于端口，
以便后续平台接线不需要改变五通道字段。

复位为低有效 `rst_n`。复位期间所有 master VALID/READY 和上游 response
VALID 均为 0；未完成的 AW/W/AR、B/R 和本地响应状态被丢弃，复位释放后只能
接受新 command。BFM 的存储内容是仿真初始化的字节数组，事务状态随 reset
清除。

## 独立 BFM 与断言

`lcvex_axi4_bfm` 是单独的随机 slave：

- `cfg_random_stall` 使 AW/W/AR READY 和 B/R 延迟由固定 LFSR seed 驱动；
- `cfg_block_aw/cfg_block_w/cfg_block_ar` 可定向制造通道背压；
- `cfg_write_error/cfg_read_error` 分别强制 SLVERR；字段、4 KiB、存储窗口
  错误返回 DECERR；
- W 可以在 AW 之前接收，WSTRB 按当前 beat 的地址 lane 应用到字节存储；
- B/R VALID 与 payload 在响应端 READY 为低时保持。

`lcvex_axi4_sva` 被动检查 VALID/payload hold、INCR/SIZE/4 KiB、ID 回显、
单 outstanding、B/R 前置地址握手和 RLAST beat 计数。SV 与 Cocotb 都实例化
同一个 endpoint，因此两套回归观察相同 master/BFM/SVA 闭环。

## 重放入口

SV 定向回归：

```sh
conda run --no-capture-output -n lcvex verilator --binary --timing --assert -Wall \
  --top-module lcvex_axi4_tb \
  -Mdir build/agents/T-20260827-053/sv/obj_dir -o lcvex_axi4_tb \
  rtl/lcvex_axi4_pkg.sv rtl/lcvex_axi4_master.sv rtl/lcvex_axi4_sva.sv \
  tb/sv/lcvex_axi4_bfm.sv tb/sv/lcvex_axi4_tb.sv
build/agents/T-20260827-053/sv/obj_dir/lcvex_axi4_tb
```

Cocotb 回归：

```sh
conda run --no-capture-output -n lcvex make -C sim/cocotb -f Makefile.axi4 \
  SIM_BUILD=/home/chiro/projects/mycpu/lcvex-wt-T-20260827-053/build/agents/T-20260827-053/cocotb \
  SEED=0x01b1a4f7
```

精确 source SHA、seed、版本、退出码和 artifact 保留策略见
`docs/tasks/evidence/T-20260827-053.json`。
