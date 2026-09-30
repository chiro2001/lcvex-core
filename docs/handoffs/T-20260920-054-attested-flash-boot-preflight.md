# T-20260920-054：T-053 user-attested Flash boot preflight

```text
task=T-20260920-054 state=done
base=0765594782d14a106769b4325376bb45cc408f50
branch=infra/T-20260920-054-attested-flash-boot-preflight
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-054
```

## 决策与实现

烧录 SOP 的真机路径是 task-owned 15 MHz MBFTDI server + `quartus_pgm -m JTAG -o
p;<SOF>`，把 SOF 临时配置进 FPGA SRAM，不写 EPCQ/Flash；终端使用独立 MPSSE
JTAG-UART。参考项目另有上电从 EPCQL1024 Flash 加载 VexRiscv/Linux 的成功记录。

T-053 只读预检看到了当前 FTDI cable、JTAG ID `02E060DD`、UART/PHY 节点和 design
hash `BD13E12CD20E8B71E260`，而保存的 reference SOF design hash 为
`193DE4BC8A30F3ED5F1F`。T-032 审计明确指出 standard-server design hash 可能是缓存
诊断值，不能单独作为 live FPGA 身份证明。用户随后确认板卡上电后已从 Flash 加载并
启动 VexRiscv/Linux，因此修正为显式的人为基线 attestation；不把不匹配的 hash 偷换成
golden 身份，也不把它作为拒绝本次 volatile 测试的唯一条件。

runner 默认行为保持不变：没有特殊字段时仍要求 initial golden design hash。唯一例外
`user_attested_flash_boot` 只接受 T-053、固定 contract ID、固定 attestation token，以及
完全冻结的 T-053 candidate/golden 文件路径、长度、SHA、checksum 和 design hash。其余
电缆、JTAG ID、UART/PHY、EDA/端口/standard-server 检查不放宽。初始 hash 仍写日志，但
明确标为 diagnostic-only；最终 exact golden 仍要求成功的独立 programmer transaction
和 postflight chain proof。

## 验证和安全边界

`make b25-board-runner-check` 通过，25/25 全绿；覆盖原有 fixture/default 路径，以及
special mode 的正确 identity、其他 task ID、错误或缺失 attestation、candidate/golden
改动等拒绝路径。`bash -n`、Python compile 和 `git diff --check` 均通过。

本任务没有访问 GamePC、运行 PowerShell、Quartus/JTAG/terminal 或改动板卡。当前容器没有
本地 PowerShell runtime；T-053 的远端 AST/seal 是硬件动作前的下一门，任何 AST/seal/
contract/preflight 失败都会在 candidate programmer 前退出。candidate、terminal、golden
一次性预算均保持 `1/1/1`，没有增添初始 golden-only programmer 操作。

详细证据见 [`docs/tasks/evidence/T-20260920-054.json`](../tasks/evidence/T-20260920-054.json)。
