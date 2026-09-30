# 2026-09-07 LCVEX 25 MHz bring-up 主 Agent 交接

本文供上下文压缩后的主 Agent 直接恢复执行。先阅读本文件，再阅读
[`BRINGUP_25MHZ_PLAN.md`](BRINGUP_25MHZ_PLAN.md) 和
[`MULTI_AGENT_WORKFLOW.md`](MULTI_AGENT_WORKFLOW.md)。不要重新做已经完成的
R19/R20/R21发现或参考工程全量审计。

## 1. 用户指令和协作协议

- 始终用简体中文回复。
- 子代理派发省略 `model` 参数；用户确认平台默认是 `gpt-5.6-luna[max]`。
- 禁止使用Sol子代理。
- physical/长任务采用子代理事件驱动和单次最长1小时 `wait_agent`，不要频繁轮询。
- 所有本机heavy先取得`/home/chiro/projects/.resource-locks/resource-lock local`；
  GamePC heavy/JTAG硬件访问取得`gamepc`；返回75即等待，禁止裸跑。
- 用户已接受25 MHz作为首个板级频率，并要求规划到简单程序+串口交互。
- 当前没有assembler授权，也没有JTAG/program/reset/power/board授权；T-043和T-044
  必须分别取得明确授权，任何一项不能推导另一项。
- 首轮禁止JIC/EPCQ/Flash写入；Linux、IRQ和通用payload loader均后置。

## 2. Git和工作区

R21功能候选：

```text
candidate=80b1f813de47a1223dd135117650419a0b6c05fc
batch_branch=batch/T-20260906-032-r21
batch_worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-032
planning_registration=8038835afd4db44c928c29d568d43b798cc95244
planning_branch=docs/T-20260907-036-bringup-plan
planning_worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260907-036
```

主工作区仍是`feature/p7-final`，并有两个属于用户的未跟踪文件，必须保留：

```text
docs/HANDOFF_20260902_TO_DSH.md
docs/HANDOFF_20260904_TO_CODEX.md
```

不要在主工作区运行生成器或测试；每个写/生成任务使用规划JSON指定的direct sibling
worktree。T-036只写计划、任务和本交接，不改RTL/QSF/SDC。

## 3. R19/R20/R21状态

```text
R19 Fmax=44.24 MHz setup WNS=-2.602 ns
R20 Fmax=45.15 MHz setup WNS=-2.147 ns
R20 setup TNS=-8417.158 ns endpoints=10353
R21 local focused=6/6 affected-L1=8/8 strict commits=1155
```

R21实现：

- `round_pack_iter_p1`删除DIV/SQRT重复256-bit leading-one fallback；周期不变。
- 新`IT_FMA`把FMA alignment与wide compare/add/sub分开；FMA每slot增加1拍。
- R21 local evidence：`docs/tasks/evidence/T-20260906-032.json`。

T-20260906-035：

```text
agent=r21_physical
branch=verify/T-20260906-035-r21-quartus-physical
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260906-035
source=80b1f813de47a1223dd135117650419a0b6c05fc
remote_probe=D:/Projects/fpga-altra/lcvex/build/T-20260906-035-r21-timing-probe
```

2026-09-07T00:21+08:00快照：synthesis已约4小时15分，heartbeat/PID/gamepc锁正常；
private约5.3 GiB、working set约1.1 GiB、远端free约34 GiB，无safety-stop。
历史R20 synthesis为4小时25分，因此该快照正常。不要重启、重复或中断；先等事件。

T-035完成后要核对：Fmax/WNS/TNS/endpoints、global top-50、DIV round-pack、FMA
两段新边界、pack边界、资源、source manifest、无assembler/forbidden artifact。
只把结果作为R21 50 MHz基线；用户决策是随后暂停追频，转入B25。

## 4. 已登记bring-up任务

```text
T-20260907-036 plan/reference freeze        done by current planning commit
T-20260907-037 B25 batch parent             waits T-035
T-20260907-038 25 MHz clock/Qsys/SDC lane   planned
T-20260907-039 BRAM/MIF/resident monitor     planned
T-20260907-040 JTAG-UART bridge/model lane   planned
T-20260907-041 read-only JTAG preflight      waits T-035/gamepc
T-20260907-042 25 MHz physical, no assembler waits T-037
T-20260907-043 assembler/SOF                 explicit permission required
T-20260907-044 volatile board interaction   explicit permission required
```

权威详细范围、写集和验收均在对应`docs/tasks/active/T-20260907-*.json`。不要在派单
时临时扩大范围。

## 5. 压缩后立即执行

1. `list_agents`查看`r21_physical`事件；若仍运行，继续一次最长1小时wait，不轮询。
2. 若T-035完成：只读审计其commit/evidence/runtime hash，串行cherry-pick派发/证据
   到R21 batch，更新T-035为done；若失败则保留现场并先解释，不自动重试。
3. 以集成者验收后的精确R21提交为base，创建T-037 parent direct sibling worktree。
4. 依次创建T-038/T-039/T-040独立branch/worktree并并行派发；三次spawn都省略model。
5. member只跑轻量focused；主Agent按038→039→040合入candidate，串行修改共享
   manifests/checkers/Makefile/SoC TB。
6. 取得local跑L0-L2；冻结candidate。Gate D可在detached local worktree进行，但
   必须在真实板测前全绿。
7. T-035释放GamePC后，可在不与physical重叠的短窗口执行T-041只读预检。
8. T-037通过后派T-042；仍禁止assembler。只在T-042全绿且用户明确授权后派T-043。
9. T-044需第二次明确JTAG授权；不得把T-043授权当作T-044授权。

## 6. 固定B25契约

```text
clock: clk_u59=100 MHz -> real logic_clk_25=25 MHz; clk_y3 unchanged
BRAM:  [0x00000000,0x00010000), stack [0xF000,0x10000)
DDR:   [0x40000000,0x48000000)
UART:  DATA=0x09000000, CONTROL=0x09000004
STATUS:0x09003000
```

MIF为`WIDTH=64, DEPTH=8192` little-endian，并与同一ELF生成的byte HEX逐字节相等。
综合M20K必须确定初始化。resident monitor输出`LCVEX25 BOOT`、CAL/DDR状态、`READY`；
`p`返回`PONG`，`?`返回状态，`m`重跑DDR，其他可打印字符回显。即使DDR失败，UART
仍必须可交互。

T-038必须先证明Qsys`clk_100`真实消费者，再决定100/25接法；不得把clk_y3或EMIF
reference改低。T-040先测试当前addr[2] classic mapping，不移植RISC-V `[13]`绕法。

## 7. 参考工程

```text
local=/home/chiro/projects/mycpu/a10-linux-riscv @ clean b2ffcc9
remote=D:/Projects/fpga-altra/a10-linux-riscv @ clean b2ffcc9
lcvex source.lock reference=3db828e74651fda377a33d84f2a2ca0e69901d72
```

权威远端证据：

- `build/burn_golden_accept.log`、`burn_freshclone.log`：SOF/JTAG 0 errors；
- `build/accept_term.txt`、`accept_freshclone.txt`：到`Run /init`；
- `build/console_probe.txt`：DATA/CONTROL分离并进BusyBox shell；
- `build/console_tx.txt`：命令回显，双向交互。

失败证据也要保留：旧`tty_*`的data==ctrl、`burn_jic_sync.log`的server配置错误、
stale Quartus database。不能复制参考`burn_board.ps1`的全局jtagserver kill和license
设置。编程用MBFTDI端口1310/成功参数15 MHz，console用JTAG-MPSSE device1 instance0。

## 8. 资源与安全

```text
/home/chiro/projects/.resource-locks/resource-lock status
/home/chiro/projects/.resource-locks/resource-lock run local  ...
/home/chiro/projects/.resource-locks/resource-lock run gamepc ...
```

持有local后不强制16 GiB上限；B25本地默认准入8192 MiB、`VERILATOR_JOBS=1`、记录
实际峰值。GamePC仍按任务保持>=16 GiB准入和free<14 GiB safety-stop。JTAG硬件访问
也使用gamepc并确认cable单占。任何任务只停止自己启动且记录PID的进程。

初次配置只允许volatile SOF。未经单独许可：不生成/写JIC，不擦EPCQ/Flash，不电源
循环，不停止未知server，不使用`quartus_pgm`，不启动terminal输入。
