# T-20260920-037：B25 sealed runner final board closeout

```text
task=T-20260920-037
state=blocked
base=cee019bf5a976a33b6475fb23531312b8cec7126
head=<commit SHA reported after commit>
branch=verify/T-20260920-037-b25-sealed-runner-final-board-closeout
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-037
sent_at=2026-09-20T19:49:26+08:00
received_at=2026-09-20T19:49:26+08:00
reported_at=2026-09-20T20:07:29+08:00
evidence_parent_sha=2e62a1d93fd29690373bb467f00804ef4c49db0c
```

## 结果

T-036 的 9 个工具已逐文件 byte-for-byte 复制到
`build/agents/T-20260920-037/tools/`。内容 SHA-256 与合同完全一致；T-037
manifest 使用原 `seal_manifest.py` 生成，SHA-256 为
`30dc36ccff5d987bc9c9dcc7c8fa82830e0794bcaf182acf65877e294041fc9c`，远端
AST 为 6/6 PASS，seal 为 9/9 PASS。

按合同唯一执行了一次整体持锁命令，fresh root/bootstrap、preflight、candidate
program、一个 terminal session、golden restore 和 postflight 均由同一 sealed
runner 完成。没有 runner/candidate/golden/terminal 重试，也没有 runner 结束后
访问 GamePC。

candidate 满足完整身份与 programmer 条件：

- SOF 36842105 bytes，SHA-256
  `bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264`，
  checksum `0x315AC2B3`，JTAG ID `0x02E060DD`。
- programmer exit 0，configuration/operation/checksum/JTAG-ID 全部 PASS，
  invocation count=1。
- terminal session count=1；BOOT/CAL/DDR/READY、zero RXDBG/TX drain、`?`
  /CLOCK25、`p`/PONG、`d`/event3/0x64、`Z`/echo、final RXDBG event4/0x5A、
  RXPATH 和 RXCPU parser 全部 PASS。完整 transcript、inputs、parser 和 result
  留在本地 artifact。

## 阻塞点

唯一 golden restore 已创建 durable marker 并尝试一次，但 programmer acceptance
失败：

- `Error (213019): Can't scan JTAG chain. Error code 86.`
- `Error (213002): Programming option p;... is illegal.`
- golden `program-result.json` 为 FAIL，不能宣称 golden programmer success。

postflight 随后报告 exact golden SOF（36844906 bytes，SHA-256
`290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92`）、design
`193DE4BC8A30F3ED5F1F`、UART/PHY、standard jtagserver 保留、busy=0、
port1310=0。但 T-032 已证明 preserved standard jtagserver 在 candidate 运行时
仍可能显示 cached golden hash/nodes；本轮 golden `quartus_pgm` 明确 FAIL，且没有
成功配置 marker。因此这些 postflight hash/nodes 只能记为
`cached-standard observation`，不能证明 live FPGA 为 golden；postflight 脚本
exit 0 也不能当作 golden recovery。当前 live final state unproven，最近一次有
功能证明的 live identity 是 candidate functional session。

时序证据：terminal 于 `2026-09-20T19:54:13.198585+08:00` 完成，golden
program 于 `2026-09-20T19:54:15.1161058+08:00` 启动，间隔约 1.918 秒。golden
shim 首次 MPSSE sync read 为 `FT_Read want=1 got=1; RX len=1 FF`；这里只记录时序
和字节观测，不强行推断根因。

## Evidence

完整结构化证据见
`docs/tasks/evidence/T-20260920-037.json`；本地运行目录为
`build/agents/T-20260920-037/run/final/`。其中包含 summary、AST/seal、
preflight、candidate/golden logs、两个 programmer result、marker、完整
terminal transcript/parsed-lines/result、postflight 和逐文件 SHA-256 inventory。

安全边界计数：JIC/EPCQ/Flash=0，reset/power=0，standard server 未停止，
unknown process 未停止；所有硬件动作都在 gamepc resource lock 内完成。禁止硬件
重跑或远端重连；必须单独授权 golden recovery 后，才可重新建立 live golden
identity。
