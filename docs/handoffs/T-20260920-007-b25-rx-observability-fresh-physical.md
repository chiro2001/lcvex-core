# T-20260920-007：RX 可观测性 no-FP fresh physical 交接

```text
task=T-20260920-007 state=done partial=false
acceptance_status=fresh-synthesis-fitter-sta-and-custom-physical-pass
candidate=05ea248845f0b94b226ffe554e082980d89e452c
tree=23e4c5158732e90439a0d426c5eca8371d296f1a
remote=D:/Projects/fpga-altra/lcvex/build/T-20260920-007-b25-rx-observability-fresh-physical
```

## 结论

在从未使用过的 GamePC root 上，以精确 RXDBG no-FP profile 完成 fresh synthesis、
fitter、signoff STA。三阶段均为 Successful、0 errors；最终占用 74,583 ALM、80,544
registers、121 RAM blocks、21 DSP、3 PLL。boot RAM 明确为 8192×64 True Dual Port、
32 M20K，并绑定 1204-byte monitor 对应的 `boot.mif`。

`sys_clk_25` setup/hold/recovery/removal 为
`+9.147/+0.018/+13.603/+0.183 ns`，Fmax `32.98 MHz`；全局最差
setup/hold/recovery/removal/min-pulse 为 `+0.207/+0.001/+0.734/+0.154/+0.120 ns`，
0 violation。DDR 五项为 `+0.014/+0.031/+0.184/+0.588/+0.110 ns`；metastability
四角 Pass、27 chains、最短 2 registers、0 timing-violation chains。

## 自定义 physical gate

fresh fitted clone 上的 overall/FIFO/data-delay/UCP 查询全部完成。FIFO 六 family ×
fast/slow × setup/hold 共 24 份报告全部无路径；data-delay 四角×五 route 共 20 组
0 violation，最差 `+0.781 ns`。T-009 的 normalized invariant 验证得到 UCP
TDI/TMS/TDO `25/35/4`、reset 624、family `606/4/13/1`，0 violation，最差
recovery/removal `+0.903/+0.202 ns`；2/2 正例、27/27 负例与三组历史 replay 全绿。

source pre/post manifest 完全相同；最终再次验证 174/174 输入。全程未运行 assembler，
未生成 SOF/JIC/RBF/POF/JBC/SVF/JAM，未访问 JTAG/板卡，也未 reset/power 或停止未知
进程。下载的 task-owned clone 与两份被拒绝的 UCP 中间副本已在封存最终证据后清理，
释放约 534 MiB；远端 fitted DB 保留。

下一步必须单独登记一次性 assembler，只从该精确 accepted fitted DB clone 生成易失
`catapult_a10.sof`；随后按已有用户授权执行 volatile 配置和 `RXDBG/status/PONG/echo`
板测。精确 hash、工具异常分类与 artifact manifest 见
[`T-20260920-007.json`](../tasks/evidence/T-20260920-007.json)。
