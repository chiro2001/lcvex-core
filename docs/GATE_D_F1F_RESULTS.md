# F1F 冻结候选标准 Gate D 结果

> 任务：`T-20260901-005`  
> 冻结 SHA：`aa60cfec24ca880841257ccc80e96f8138caf023`  
> 结论：**未通过**；一个 testbench cache-off elaboration 首因造成三个红项。

## 结果

串行正式尝试使用：

```sh
systemd-run --user --scope \
  --unit=lcvex-t20260901-005-gate-d-serial \
  -p MemoryMax=15G -p MemorySwapMax=0 -p CPUQuota=50% -- \
  env MAKEFLAGS=-j1 VERILATOR_JOBS=1 \
  bash -lc 'bash sim/difftest/run_gate_d.sh'
```

Gate D 最终报告三个失败 step：

1. `make test（单元 + SVA）`：默认 cache-off `lcvex_soc_tb` elaboration 失败；
2. `随机回归（seed 1~3 × 100k）`：同一顶层 elaboration 再次失败；
3. `指令覆盖记账`：`random_2.trace`/`random_3.trace` 未生成后的级联失败。

首因是 [`tb/sv/lcvex_soc_tb.sv`](../tb/sv/lcvex_soc_tb.sv) 在参数化
I-L1、D-L1、L2 关闭时，性能 counter 仍直接层次引用被裁剪的 `il1`、`dl1`、`l2`
实例内部信号。Verilator 5.050 报 42 个 missing-module/dotted-reference errors。
不得通过跳过 `make test`、随机回归或覆盖记账关闭该红项。

其余已执行路径均为绿色：coverage、M2/R1 base+全缓存、delay2、P5a hardening、
Gate C、P5a MMU、P4b 和 baremetal-C 200 条；日志中共有 148 个 `OK(green)`。
这些绿色结果不等于 Gate D 通过。

## 资源与 artifact

- 正式串行 scope：`lcvex-t20260901-005-gate-d-serial.scope`
- wall：1241.087 秒；CPU：620.510 秒；memory peak：4.7GB；swap 上限：0
- 正式日志：`/home/chiro/projects/mycpu/lcvex-artifacts/T-20260901-005/gate_d_serial.log`
- 正式日志 SHA256：`dd531ff64ebc8ac2657385e31e922abab6bb343ab097ae56d5a8a6a959adc526`
- 先前 parallel 尝试因 planner 无槽位终止，日志 SHA256：
  `2526093d11a25f118699c8f358ca6212181540c9cb023305b5a19df113eca5f0`

两个 scope 均已退出；未停止其他进程，未运行 Linux、Quartus 或板测。

下一步是修复性能 counter 的 cache-off/on 可 elaboration 接口并加入两种参数定向测试，
然后在新的冻结 SHA 从头运行完整串行 Gate D。
