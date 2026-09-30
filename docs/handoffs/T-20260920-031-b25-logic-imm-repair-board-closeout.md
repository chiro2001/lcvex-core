# T-20260920-031：B25 logic-imm repair 板级 closeout

结论：功能验收失败，golden 易失回滚成功。候选 SOF 的 Quartus 编程事务完整成功，但候选 design hash 无法由 owned 或 preserved-standard `jtagconfig` 证明，因此按 failure policy 没有启动 terminal，也没有发送 `? / p / d / Z`。最终板卡已恢复并独立验证为 golden。artifact 于 18:02:35 封存，本 correction 报告时间为 18:06:22；本次修订不执行任何硬件动作。

## 实现与边界

- 候选：T-030 精确 SOF，36842105 bytes，SHA-256 `bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264`，checksum `0x315AC2B3`。
- golden：`vex_soc_ddr.sof`，36844906 bytes，SHA-256 `290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`，checksum `0x31510BB6`，design hash `193DE4BC8A30F3ED5F1F`。
- 初始持锁 preflight 证明 root 不存在、候选/golden hash 正确、冲突进程=0、port 1310 空闲、恰好一个标准 jtagserver PID 5640，并枚举 golden JTAG UART/PHY。
- 候选 programmer PID 25360、owned server PID 7060；exit=0、tool/configuration/operation/checksum/JTAG-ID 全部 PASS。owned 和标准 server 重扫均没有候选 design hash `0CC907F3DD48A9C78864E3C5BD66B9AF`，标准 server 继续显示 golden hash，故候选验收在终端前失败。
- golden rollback 使用全新 owned server PID 28580、programmer PID 21364；exit=0、tool/configuration/operation/checksum/JTAG-ID 全部 PASS。owned server 已停止，标准 PID 5640 保留；最终 jtagconfig 与 postflight 均显示 golden hash、JTAG UART #0、JTAG PHY #0，冲突进程=0、port 1310=0。
- 全部尝试已逐轮计数：initial 未启动 programmer；retry-v2 未启动 programmer；retry-v3、retry-v4、retry-v5 各自调用一次 candidate `quartus_pgm`，三次 transaction 均 exit=0/tool/configuration/operation/checksum/JTAG-ID PASS，但 wrapper 均因 candidate identity gate exit1；对应三次 golden `quartus_pgm` transaction 也均 PASS，wrapper 分别 exit0、exit1、exit0（v4 的 exit1 是 owned-chain design-hash gate，最终 standard golden chain 与 postflight 仍 PASS）。因此 `candidate_program_invocation_count=3`、`golden_program_invocation_count=3`，而不是一次。
- 超过任务要求的 single candidate configuration 是调试性流程偏差：所有五个窗口都使用已授权的 volatile 配置、各自持有 gamepc lock、只停止 task-owned server，且最终恢复 golden；这不改变候选功能 FAIL，也不构成把重试当作通过。
- 全流程均在 `resource-lock run gamepc lcvex T-20260920-031 board_t031 -- ...` 内；没有 JIC/EPCQ/Flash、reset、power cycle、synthesis/fitter/STA/assembler，也没有停止未知或标准进程。

## 证据与限制

主证据见 [`T-20260920-031.json`](../tasks/evidence/T-20260920-031.json)。候选 programmer stdout、server manifest、golden rollback result、完整 pre/postflight 日志均已抓取到 `build/agents/T-20260920-031/retry-v5/`（build 产物按规范不入 Git）。

历史 golden 双向控制仅作参考，链接 [`T-20260920-003.json`](../tasks/evidence/T-20260920-003.json)；本轮没有把历史交互冒充候选交互。由于候选 design-hash gate 首先失败，terminal transcript、输入 offset/time、RXDBG/RXPATH/RXCPU 行均按空集记录，不能声称 `? / p / d / Z` 或 CPU/内存闭环通过。

后续若要重试，应先解决 candidate live design-hash 暴露/standard-server cache 问题，或由评审明确批准可审计的替代身份证明；板卡保持 golden。本 follow-up 明确 no hardware rerun，最终 board 仍为 golden。
