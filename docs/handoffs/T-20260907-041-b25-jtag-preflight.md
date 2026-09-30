# T-20260907-041：B25 JTAG 只读预检交接

```text
task=T-20260907-041 state=done
base=689959472faf59844fb486834fad27f8fedb2ca6
branch=verify/T-20260907-041-b25-jtag-preflight
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-041
sent_at=2026-09-07T03:09:38+08:00
received_at=2026-09-07T03:09:38+08:00
reported_at=2026-09-07T03:14:43+08:00
evidence=docs/tasks/evidence/T-20260907-041.json
```

## 结论

在共享 `gamepc` 锁内完成只读枚举。GamePC 当前通过两条可见 cable 都读到同一
`0x02E060DD / 10AT115S(1|2)`，与 LCVEX QSF 的 Arria 10
`10AX115N4F40E3SG` 目标一致：

1. `JTAG-MPSSE-Blaster [00 Single RS232-HS (0403:6014)]`，后续 console 固定
   `--device=1 --instance=0`；用户已明确确认该连接可用于测试。
2. `Microsoft Catapult (64) [USB-0]`，同样能枚举目标 ID。

成功参考的编程路径仍为
`MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310`、15 MHz。此自建 server 本轮没有
启动，因此它不会出现在当前 `jtagconfig` 枚举中；T-044 若获易失配置授权，只能启动
并停止自己记录的 server PID。

可回退的参考 SOF 已只读复核：

```text
D:\Projects\fpga-altra\a10-linux-riscv\dist\golden\vex_soc_ddr.sof
bytes=36844906
sha256=290AB3CFB18CFD6EE47E5A2BC9324E63882DE51D0AE5AC6C2688D7D6A2385F92
```

参考工程仍为 clean `b2ffcc9bf132fdcf5eced40139c768ff619c29e0`。六份成功日志的
hash、JTAG链输出和失败尝试均在 evidence 中。历史 fresh-clone SOF 路径当前已不存在，
但 frozen `dist/golden` 副本存在并完成 hash，不影响易失回退路径。

## 边界与后续门

本轮只观察了既有 `jtagserver` PID 5476，没有启动/停止任何进程，没有运行
`nios2-terminal`、assembler、`quartus_pgm`，也没有配置、复位、断电或写入 Flash。
用户当前授权覆盖 console 连接与串口交互；不自动扩张为 assembler 或 FPGA 配置授权。

下一步先完成 T-037、T-042。T-043 仍需明确的 SOF 生成授权，实际易失配置也需明确
授权；JIC/EPCQ/Flash、擦除和电源循环继续禁止。
