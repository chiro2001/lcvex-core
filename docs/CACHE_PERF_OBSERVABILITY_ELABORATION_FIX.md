# 可选 Cache 性能观测端口与 cache-off elaboration 修复

## 背景

F1F 的默认 `lcvex_soc_tb` 使用 `I_L1_ENABLE=0`、`D_L1_ENABLE=0`、
`L2_ENABLE=0`。此前 testbench 的性能观测表达式仍通过层次名读取条件
generate 内的 `il1`、`dl1`、`l2` 实例；实例被裁剪后，Verilator 5.050
在 elaboration 阶段报告 dotted-reference/missing-module 错误。

## 观测接口

`rtl/lcvex_l1_d.sv`、`rtl/lcvex_l1_i.sv` 和 `rtl/lcvex_l2.sv` 各新增两个
只读输出：

- `perf_hit`：当前上游请求地址的组合命中视图，直接反映已有的 valid/tag
  比较。上层只在既有 `u_req_valid && u_req_ready`、读请求、非 bypass、
  `MAINT_NONE` 条件下使用它来形成 read-hit/read-miss 计数。
- `perf_refill_beat`：已有 `S_REFILL` 状态下的下游 `d_req_valid &&
  d_req_ready` 握手脉冲。

两者均为纯组合输出，不新增寄存器、缓存状态或 reset 状态；因此没有新的
reset 值、读写权限或提交时机，也不进入架构提交包。cache 功能、请求/响应
协议、断言和原有 counter 定义保持不变。

`tb/sv/lcvex_soc_tb.sv` 通过显式端口连接上述视图；cache downstream 计数
使用已有的 SoC 顶层连接握手（`arb_*` 或 `l2_req_*`），不再窥探 cache
实例内部的 `state`、`hit` 或 `d_req_*`。关闭某个 cache 时，对应端口线和
所有该级性能输出均显式为零。单元 TB 与 Catapult SoC wrapper 对不使用的
观测端口显式留空，避免把性能观测引入功能或综合依赖。

## 干净入口

以下 Makefile 目标分别传入完整参数，使用 Verilator 的独立 lint/elaboration
流程：

```sh
make cache-perf-elab-off   # 0/0/0
make cache-perf-elab-on    # 1/1/1
make cache-perf-elab        # 依次执行两者
```

`make cache-perf-smoke` 进一步以缩小的 `mem_ldst` workload 构建独立 off/on
runner，检查 off 的全部 cache 观测计数为零，以及 on 的 I-L1、D-L1、L2
均出现 hit、refill beat 和 downstream 事件。入口已登记到
`scripts/test_registry.json`。

## 边界

本修复只处理可选 Cache 性能观测的接口稳定性和 elaboration；不改变 cache
策略或默认参数，不解决 F1a `nocache_d2` 性能回退，也不替代完整 Gate D、
Linux 或 Quartus 验证。
