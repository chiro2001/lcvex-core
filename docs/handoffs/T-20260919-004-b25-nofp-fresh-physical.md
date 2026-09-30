# T-20260919-004：corrected no-FP fresh physical 交接

```text
task=T-20260919-004 state=done partial=false
acceptance_status=fresh-synthesis-fitter-sta-and-custom-physical-pass
candidate=d00d566da86e034d6cf1651cdfb8ec50074ead13
tree=d5baa6b05f5f8824236c816980ab6e6d48578594
remote=D:/Projects/fpga-altra/lcvex/build/T-20260919-004-b25-nofp-fresh-physical
evidence=docs/tasks/evidence/T-20260919-004.json
```

## 结论

在从未使用过的 GamePC probe 上，以精确 no-FP profile 和修复后的 M20K RTL 完成
fresh synthesis、fitter、signoff STA。三阶段均为 Successful、0 errors；最终占用
74,652 ALM、80,449 registers、121 RAM blocks、21 DSP、3 PLL。boot RAM 在 fitted
inventory 中为 8192×64 True Dual Port、32 个 M20K，并绑定同一份 `boot.mif`。

25 MHz `sys_clk_25` setup/hold/recovery/removal 为
`+7.336/+0.019/+13.589/+0.166 ns`；全局最差 setup/hold/recovery/removal/min-pulse
为 `+0.263/+0.000/+0.657/+0.154/+0.120 ns`，0 violation。DDR 五项为
`+0.014/+0.031/+0.184/+0.588/+0.110 ns`；metastability 四角均 Pass，27 chains、
最短 2 registers、0 timing-violation chains、MTBF `1e+09 years`。

## 自定义 physical gate

所有 TimeQuest 查询都在 task-owned fresh fitted clone 中完成，source pre/post manifest
相同，query diff 0。FIFO payload 的 6 个精确 family × fast/slow × setup/hold 共 24 份
报告全部 `Nothing to report`，每个 model 恰有 6 个 Complete、0 ignored 的目标 exception。
data-delay 四角×五 route 共 20 组全部 0 violation、含 2.000 ns Datapath Only marker，
最差 `+1.307 ns`；每角 5 个 paired full false-path 均 Complete、0 ignored。

T-005 对原始 UCP/reset 报告做了 v2 content-addressed 绑定：normalized UCP input 60、
reset endpoint 624，0 violation，最差 recovery/removal `+1.086/+0.179 ns`。原合同、
T-011/T-013 profile 和 27/27 负向矩阵均保持通过。

## 边界与下一步

该结果只证明 `A64_FP_SIMD=0` 的首板标量 profile，不替代 full-FP/P7 release。全程未运行
assembler、未生成 SOF/JIC/EPCQ 等配置格式、未访问 JTAG/板卡、未 reset/power，也未停止
未知进程。T-002 完整 Gate D 同样已通过，因此下一步可建立独立的一次性 assembler
任务，从本 remote project clone 只生成 volatile `catapult_a10.sof`，再进入用户已授权的
易失配置与 `LCVEX25 BOOT / READY / PONG / echo` 板测。精确 hash 和 harness 恢复说明见
[`T-20260919-004.json`](../tasks/evidence/T-20260919-004.json)。
