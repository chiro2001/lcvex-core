# T-20260907-037：25 MHz B25 bring-up batch交接

```text
task=T-20260907-037 state=done-local-l0-l2
base=689959472faf59844fb486834fad27f8fedb2ca6
source=259188ac33322a74a8911c9c37edc6302f6d6169
branch=batch/T-20260907-037-b25-bringup
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-037
finalized_at=2026-09-07T09:22:41+08:00
evidence=docs/tasks/evidence/T-20260907-037.json
```

## 结论

B25本地实现与L0-L2已闭合。板载100 MHz真实四分频为25 MHz，CPU从确定初始化的
64 KiB M20K镜像PC=0启动，栈固定在`[0xF000,0x10000)`。BRAM常驻monitor输出
`LCVEX25 BOOT`、独立CAL/DDR行与`READY`，并通过标准JTAG-UART DATA/CONTROL
映射完成`p/PONG`、`?`、`m`和可打印字符回显。

集成期间修复了三个会阻断bring-up的问题：post-index SP load返回地址错误、AXI
64B行读首/首响应取成最后beat、offset7被提前丢弃。MMU-off DDR现在走uncached
bypass，SoC smoke同时要求CPU readback、AXI/Avalon真实握手和外部模型magic一致。

T-045进一步把EMIF故障从丢事务/永久等待收敛为有界DECERR：在途calibration
failure、EMIF-only reset、永久waitrequest和缺失readdatavalid均有定向SV/Cocotb；
late response被drain/poison，B/R反压保持，AW/W部分事务跨reset不混合。生产timeout
默认4096个EMIF周期（约15.36 us），focused测试使用32周期。

## 验证与边界

父线在`259188ac`内容上通过AXI line bridge、EMIF SV、Cocotb 7/7、timeout参数
lint、B25 SoC三场景smoke、platform/skeleton/MIF/SHA/registry闭包和平台/SoC lint。
精确命令、日志hash、源文件hash及镜像hash见evidence。

本任务没有访问GamePC/JTAG，没有运行Quartus assembler，没有生成SOF，也没有
配置或复位板卡。用户提供的`nios2-terminal --device=1 --instance=0`授权只保留给
依赖完成后的console收发；它不授权`quartus_pgm`或任何JIC/EPCQ/Flash操作。

## 下一步

T-042必须从该source SHA建立fresh远端probe，显式重建/复制ignored `boot.mif`，
把它以generated/untracked项加入physical manifest并验证远端hash；然后只运行
synthesis、fitter、STA和非破坏性报告，禁止assembler。Gate D可在独立detached
本地worktree并行，但两者都必须在任何FPGA配置前通过。

## 2026-09-08 候选更新

T-002 与 T-004 已在同一候选上完成受影响 directed union；随后 T-005 在候选
`90627b58721b463242d6276a1db9d5e72c68ad66` 完成完整 Gate D：random seed 1/2/3
各 100k（300006 commits）、coverage 62/62、baremetal-C 200，以及全部 M2/R1、
delay2、P5a、Gate C、P5a MMU、P4b 组均通过。详细证据见
[`T-20260908-005`](../tasks/evidence/T-20260908-005.json)。

因此下一步可从该精确候选启动 T-042 的 fresh 25 MHz synthesis/fitter/signoff
STA；仍不得把 Gate D 结果当作时序闭合，也不得在没有单独 assembler/SOF/配置授权
前执行 `quartus_pgm` 或板卡操作。用户已提供并授权在有效镜像之后观察串口的
`nios2-terminal --device=1 --instance=0` 命令，但串口观察不替代 physical 门。
