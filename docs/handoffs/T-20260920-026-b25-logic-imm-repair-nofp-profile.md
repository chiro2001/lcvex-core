# T-20260920-026：B25 逻辑立即数修复候选的 no-FP 板级 profile 交接

## 结论

任务已完成。相对 Gate-D 通过的 `c31b3aea754769304ab7c9a24ef2f78c8120bc2a`，本 profile
只把板级顶层 `A64_FP_SIMD` 默认值从 `1'b1` 改为 `1'b0`，提交为
`2a1cd5c59fc27f0a6d947c58f5b24b194d4dd13b`，tree 为
`e5e94ab175f6847d727901576a8f12958efc1100`。它是标量 bring-up profile，不是 full-FP
发布候选。

实现 diff 严格为一个 functional 文件的一行删除和一行增加：

```text
fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv
- parameter logic A64_FP_SIMD = 1'b1,
+ parameter logic A64_FP_SIMD = 1'b0,
```

`rtl/lcvex_decode.sv` 保持 byte-identical，SHA-256 为
`5e92ee65a817a55a7dc14f7cdb5066dc3f82510fc794a6aea129fb45b87da1df`；逻辑立即数修复未被
改变。没有修改 QSF、SDC、SoC/observer/firmware RTL、测试、registry 或 expected 结果。

## 验证证据

- tracked logical-immediate oracle：`16384` 项全部通过，精确覆盖 `A43F/3F`，结果为
  `legal=11328 reserved=5056`。
- boot image：2011 bytes；`boot.bin` SHA-256
  `96f1b8484b30c33adac0a1562b897647a1f937cd4ac64539bad687538d19ad79`；MIF 为
  `WIDTH=64 DEPTH=8192 records=8192`；image contract emit/check 均通过。
- board skeleton lint、explicit no-FP core/SoC lint、platform checker（50 files）和
  synthesis-selector 均通过。
- 修复后的 vendor-faithful M20K timing test 通过：`BRAM_M20K_TIMING_TB PASS`。
- vendor-focused bridge/status 的 Icarus 与 Verilator 测试通过；RX focused 页面和
  observer 测试通过。
- 本 profile 直接运行了显式 `-GJTAG_VENDOR_TIMING=1 -GA64_FP_SIMD=0` 的 vendor
  full-SoC smoke：

  ```text
  SOC_B25_VENDOR_EMPTY_POLLS reads=262144 commits=2359306 cycles=12058697
  SOC_B25_ALL_PASS
  JTAG_UART_VENDOR_SOC_PASS
  JTAG_UART_VENDOR_TIMING_TEST_PASS
  ```

完整 CPU-originated RX response trace 沿用 T-022 的 exact candidate 结果：该 trace
testbench 本身显式设置 `A64_FP_SIMD=0`，且其 `filelist_soc.f` 与
`filelist_rx_response_trace.f` 的去重输入集合共 33 个文件，均不包含
`fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv`。当前 profile 已保存完整路径/输入
hash 清单，分别为 `filelist.paths` SHA
`c9a1a3162ea8d390b26b6025be0acce9d043cd0f5d45d177936eeb0ea3538cda`、输入 hash 清单 SHA
`418c74a0115ad762fe1470f2a5b562f9f2058b467c32defca41bef33ccc483aa`。因此 board-top
默认值不会进入该 trace，T-022 的
`RX_RESPONSE_TRACE PASS checks=4 bridge=4 poc=4 dmem=4` 可严格复用。

精确命令、日志 hash、完整输入身份和资源安全声明见
[`T-20260920-026.json`](../tasks/evidence/T-20260920-026.json)。

## 资源与边界

所有本机 Verilator 重型步骤均通过
`/home/chiro/projects/.resource-locks/resource-lock run local`，`VERILATOR_JOBS=1`，
最低可用内存门槛 8192 MiB；结束时 `local` 和 `gamepc` 均为空闲。本任务未访问
GamePC/Quartus/JTAG/板卡，未生成 assembler/SOF，未执行 Flash/JIC/EPCQ、reset 或 power
动作。

## 下一步

集成者应 push 此分支，并以该 profile SHA/tree 作为 T-027 fresh physical flow 的唯一来源。
T-027 必须建立全新 task-owned Quartus staging/数据库；本 profile 不构成 full-FP 发布等价
声明。
