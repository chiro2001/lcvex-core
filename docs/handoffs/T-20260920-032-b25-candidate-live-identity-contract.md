# T-20260920-032：B25 candidate live identity 合同审计

```text
task=T-20260920-032
state=review
base=32303ba2340d32ec8b953294434cc9e41a704972
branch=verify/T-20260920-032-b25-candidate-live-identity-contract
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-032
```

## 决策

采用“复合 live identity”合同，不把 candidate design hash 的先验可读性当作新板测
的硬前置。这里不是 waiver：candidate hash 仍被冻结并记录，缺少 live hash 仍是风险；
只是用以下不可替代的复合证据闭环身份，并 fail-closed：

1. 冻结 candidate SOF：

   ```text
   path=D:/Projects/fpga-altra/lcvex/build/T-20260920-030-b25-logic-imm-repair-volatile-sof/fpga/catapult_a10/quartus/output_files/catapult_a10.sof
   bytes=36842105
   sha256=bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264
   quartus_checksum=0x315AC2B3
   design_hash=0CC907F3DD48A9C78864E3C5BD66B9AF
   jtag_usercode=0xFFFFFFFF
   ```

   Golden 同样冻结为 `D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/vex_soc_ddr.sof`、
   `36844906` bytes、SHA-256
   `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`、checksum
   `0x31510BB6`、design hash `193DE4BC8A30F3ED5F1F`。

2. 只允许一个 task-owned 15 MHz/channel-0 server 和一次 candidate `quartus_pgm`。
   使用精确
   `D:\Software\intelFPGA_pro\21.4\quartus\bin64\quartus_pgm.exe` 与
   `MBFTDI-Blaster v2.1b (64) on 127.0.0.1:1310`，必须同时有 exit=0、candidate
   checksum、JTAG-ID `0x02E060DD`、configuration succeeded、operation succeeded、
   `Quartus Prime Programmer was successful. 0 errors, 0 warnings`。programmer PASS
   只证明配置事务，不证明 live candidate 或功能通过。

3. 停止的只能是该次 candidate 的 task-owned server；标准 `jtagserver.exe` 必须保留。
   owned 或 preserved-standard `jtagconfig` 的 hash 只作诊断。尤其 preserved standard
   仍报 golden hash 时，不能将其冒充 candidate live identity。

4. 关闭 owned server 后启动第一条、也是唯一的 candidate live terminal；在发送任何
   字节前，必须按顺序看到候选唯一启动链：

   ```text
   LCVEX25 BOOT
   CAL-(OK|WAIT|FAIL)
   DDR-(OK|FAIL)
   READY
   startup/autonomous RXDBG
   ```

   还必须看到 `RXDBG 00000000 00000000` 以及后续非零 read/零 event 的 TX-drain
   页面；否则立即失败，发送字节集合保持为空，停止 task-owned 进程并执行唯一一次
   golden restore。

5. 启动门通过后保留原始 paced 序列及所有门：逐字节 `? -> CLOCK25 CAL-* DDR-*`、
   `p -> PONG`、`d -> RXDBG`、`Z -> Z`；保留 RXDBG 最终 count/byte、RXPATH
   bridge=PoC=dmem、最终低 16 位 `0xA45A`、每层四个 valid event/零 fault，以及
   RXCPU 四个 getc/dispatch、最终 `0xA45A`、dispatch class=5/byte=`0x5A` 和
   putc/TX progress。前一响应未出现时停止，不发送下一字节。

6. 成功和失败都执行一次 exact golden restore，并以 golden bytes/SHA/checksum/JTAG-ID、
   最终 golden design hash、UART/PHY 节点、标准 server 保留、无残留进程/port 1310
   释放为收口。下一次任务禁止内部 debug retries：candidate program=1、golden
   restore=1；不把 wrapper 重试隐藏在脚本中。

## T-021 历史合同审计

T-021 的原始候选身份链确实是：候选 SOF path/bytes/SHA → `quartus_pgm` checksum
`0x3159F8A0`、JTAG-ID `0x02E060DD`、configuration/operation/0 errors → 随后同一
候选终端先出现 `LCVEX25 BOOT`、`CAL-WAIT`、`DDR-FAIL`、`READY`、startup RXDBG，
再发送一次 `?`。候选原始 `program-result.json` 的第 9–30、87–110 行与
`candidate-final.log` 第 20–36 行支持前半链；原始 transcript 第 4–10 行支持后半链。

但它没有证明“candidate post-program design hash 是实际 acceptance prerequisite”：

- T-021 ignored 本地 `program_sof.ps1`（SHA-256
  `ecfbcbe37388dd76479b6ec1f42424409bbde95bdb072ec9a41e400ff542a639`）第 248–258
  行看起来含有 final hash gate，第 260–270 行看起来会写 final chain；
- 可是远端抓回的 candidate log（SHA-256
  `d0c0c2ed43865db6ed9f0206a04af8ea877a0ef8115c88741f6fd1de44124ac8`）没有
  `FINAL_STANDARD_JTAG` 或 `FINAL_DESIGN_HASH_OK`；candidate result（SHA-256
  `8331659715fa526c85590bc95180ff25a555e5a9f7284e379436a432293a0a15`）也没有
  `final_chain`/`final_design_hash_ok` 字段；
- T-021 evidence 把候选 configuration acceptance 写成 programmer exit/tool/config/
  operation/checksum/JTAG-ID（第 64–88 行），而 BOOT/READY/terminal 单独记录在第
  90–162 行；没有 candidate post-program hash predicate。

因此，脚本意图与执行 artifact 不一致时，只能说历史成功合同实际依赖 exact SOF、
programmer 事务和候选专属 live startup/terminal 链，不能把 hash 元数据或未输出的
final gate 补成历史事实。未来任务必须在硬件动作前 hash/封存实际远端脚本。

## T-031 attempt 清单

`T-031` evidence SHA-256 为
`d2afccef22dc0ededd3412b3536114ebf5ff64f6f2d327d4b628f316a51161d1`；原始证据第
48–59、251–375 行给出相同总账：candidate programmer=3、golden programmer=3，
六次实际 `quartus_pgm` transaction 全部 PASS；candidate wrapper 三次 exit=1，
golden wrapper 为 v3/v5 exit=0、v4 exit=1。

| attempt | candidate programmer / wrapper | golden programmer / wrapper | 真实原因 |
|---|---|---|---|
| initial | 0 / 1 | 0 / 1 | 两个 wrapper 在 pre-program PowerShell output-object capture 失败；日志无 PROGRAMMER_PID。 |
| retry-v2 | 0 / 1 | 0 / 1 | 两个 wrapper 在 pre-program PowerShell inline-if syntax 失败；仍无 `quartus_pgm` transaction。 |
| retry-v3 | 1 / transaction PASS / 1 | 1 / transaction PASS / 0 | candidate 的 final standard design-hash gate 失败；golden final chain 通过。 |
| retry-v4 | 1 / transaction PASS / 1 | 1 / transaction PASS / 1 | candidate owned/standard-rescan gate 失败；golden wrapper 的 owned-chain gate 失败，但 final standard golden chain 通过。 |
| retry-v5 | 1 / transaction PASS / 1 | 1 / transaction PASS / 0 | candidate owned/standard-while-owned/final-rescan gate 全失败；golden final chain/postflight 通过。 |

每个 v3/v4/v5 的 raw `candidate-quartus_pgm.stdout.log` 第 20–29 行均有
candidate path/checksum `0x315AC2B3`、JTAG-ID、configuration、operation 和
0 errors；对应 golden stdout 第 20–29 行均有 golden checksum `0x31510BB6` 与同样
的 programmer PASS。wrapper exit=1 仅表示其 post-program identity gate/cleanup
结果，不会抹掉单独已经 PASS 的 `quartus_pgm` transaction。T-031 明确记录这是
违反 single-candidate policy 的调试重试偏差，不能隐藏，也不能当作 candidate acceptance。

## T-031 raw JTAG 边界

- preflight `preflight.log`（SHA-256
  `38f6ea893470e9344e96e98f959e66e425bc4872b140811a436354769b458ae3`）第 14–21
  行：配置前 standard `jtagconfig` 报 golden hash `193DE4BC8A30F3ED5F1F` 和
  Virtual JTAG/Signal Tap/JTAG UART/JTAG PHY 四节点。
- v5 candidate log（SHA-256
  `87200725c7e1340a3d8435f30da3ace2db1079fa3d7ced8a350c0f69bb54dca8`）第 32–37
  行：owned server 只见 cable/JTAG-ID，design-hash line 缺失；第 38–47 行：
  preserved standard 仍报 golden hash、但只见 UART/PHY；第 48–70 行：owned 停止后
  final/rescan standard 仍是同一 golden hash+UART/PHY，candidate hash 不存在。
- v5 golden restore log（SHA-256
  `6d4261078f7f0fa1e012f9cf5ed5e7564e649f5ceeca94621c737d4167d667d4`）第 30–52
  行：owned 仍无 hash，最终 standard 报 golden hash 和完整四节点；postflight 第
  10–23 行独立确认 golden、UART/PHY、无 busy process、port 1310 释放。

这些记录能证明编程事务和 golden 收口，不能证明 candidate live design hash；标准
server 的 golden 值只能作为 cache/诊断上下文。

## 已有方法搜索与限制

现有 SOP（SHA-256
`a80e71fb88ea0ad8f31d4407ac290ab251d372b5c836477045c2e17e6855b841`）第 64–90、
125–138 行只定义普通 `jtagconfig`、owned-server 环境变量和未执行/未验证的
`quartus_pgm -l` 电缆列举；第 251–268 行定义停止 owned server 后连接终端。T-003
仅证明保留 PID 5640 的只读 rescan 可恢复 golden JTAG-UART，T-004 两次延迟 rescan
仍只得到 golden hash+UART。因此没有找到受支持、无需停止标准 server/reset/power
即可读 candidate live hash 的办法，也不把未验证命令脑补成办法。

完整 JSON、artifact SHA-256、行号、验证命令和风险见
[`T-20260920-032.json`](../tasks/evidence/T-20260920-032.json)。本任务没有访问
GamePC/网络、没有执行 Quartus/JTAG/terminal、没有硬件动作，也没有修改 tracked
源码、expected 或 policy。
