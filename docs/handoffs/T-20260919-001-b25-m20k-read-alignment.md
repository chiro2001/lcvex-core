# T-20260919-001：B25 M20K 同步读响应对齐交接

```text
task=T-20260919-001 state=done partial=false
acceptance_status=stale-read-reproduced-and-fixed-local-l0-l2-pass
base=81b2b897fdbec81e5f1a57729204ecf36569059b
dispatch_head=c0bb03f7cac9c2524bcc45d359f04d157e1c760c
implementation=7a0c6705fb06df7785a95bfc3707e8cbd17749d1
branch=fix/T-20260919-001-b25-m20k-read-alignment
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260919-001
evidence=docs/tasks/evidence/T-20260919-001.json
```

## 结论

T-044 后提出的 M20K 同步读错拍假设已由同一测试的修复前后对照证明。测试专用
`altera_syncram` stub 在时钟沿采样地址，并在沿后更新 `q_a/q_b`。旧 RTL 稳定返回：

```text
PC=0 read   actual=8877665544332216 (word 7) expected=8877665544332211 (word 0)
next word   actual=8877665544332211 (word 0) expected=8877665544332210 (word 1)
debug word  actual=8877665544332211 (word 0) expected=8877665544332215 (word 4)
```

也就是说，旧 wrapper 在 M20K 接受新地址的同一沿把此前的 `q` 捕获进响应。复位期间若
地址碰巧停在 0，首个 PC=0 读取可能被预充掩盖，但下一次地址变化仍返回前一 word；
这与真板“配置成功、JTAG-UART instance 可连接、CPU 没有输出一个字符”一致。

## 修复

综合专用 `lcvex_bram_boot_altsyncram` 现在：

- 显式把 port-A address/data/byte-enable/read-control 注册到 `CLOCK0`；
- `req_accept` 时锁存 word address、byte offset 和响应类型；接受沿送入当前地址，此后到
  `rsp_ready` 前保持该地址；
- read response 直接使用沿后更新的 `q_a` 与已锁存 offset，不再在接受沿捕获旧 `q_a`；
- debug port 同沿锁存 offset，并与沿后 `q_b` 组合，不再额外寄存旧 word。

新增寄存状态复位值全部为 0；写副作用仍在接受沿提交；公开的一 outstanding、一拍响应和
backpressure 稳定合同不变。行为级 RAM、QSF/SDC、vendor IP、core/cache/AXI/EMIF/
JTAG-UART 均未修改。

## 验证

- vendor-faithful timing TB：旧 RTL exit 1、3 个 stale mismatch；新 RTL
  `BRAM_M20K_TIMING_TB PASS`。覆盖首读、连续换地址、未对齐 offset、3-cycle
  backpressure、byte write/readback、fault 与 debug 对齐。
- 既有行为级 BRAM TB：`BRAM_BOOT_TB PASS`。
- ELF-derived BRAM oracle：emit/check PASS、13/13 负例、`BRAM_INIT25_TB PASS`；
  boot BIN/MIF hash 保持 `aa4a8bbe...f0c6` / `614d4505...cd7`。
- B25 SoC smoke：CAL-OK、CAL-WAIT、CAL-FAIL 三场景全绿，`SOC_B25_ALL_PASS`。
- `make compile`、SoC lint、platform 50、skeleton 6、SHA256SUMS 50/50、synthesis
  selector、registry 85 项一致性均通过。

重型 Verilator/SoC/compile/lint 均取得共享 `local` 锁。第一次 oracle heavy 阶段在
其他项目占锁时正确返回 75，稍后取得锁后通过；本任务未使用 GamePC 或 Quartus。

`scripts/test_registry_test.py` 的硬编码 L0 ID 列表在未修改集成分支上同样失败，属于既有
脆弱测试；权威的 `make test-registry-check` 全绿，本任务没有越界修改它。

## 下一步

集成者在 B25 分支合入后复跑 focused timing test 和受影响 union，再运行同一合并 SHA 的
Gate D。只有另立 fresh Quartus synthesis/fitter/STA/assembler 任务并生成新 SOF 后，
才能重复易失板测；旧 SOF `032c82dd...2920b` 不再使用。精确命令、hash 和日志索引见
[`T-20260919-001.json`](../tasks/evidence/T-20260919-001.json)。

## 集成复核

实现与证据已分别 cherry-pick 为 `c4c75ca6` / `bd59d4fc`。合并 SHA 上重新运行的
vendor-faithful timing test、synthesis selector、registry consistency、platform/
skeleton/SHA closure，以及 BRAM oracle emit/check 与 13/13 负例均通过。重复的
oracle heavy 阶段因 PyPTO-X 正持有共享 `local` 而按协议返回 75；没有绕锁运行。
实现 worktree 的相同 RTL tree 已有带锁的行为级 BRAM、oracle heavy 和三场景 SoC
smoke 全绿证据，因此集成者接受本任务，并把完整 Gate D 与 physical 拆成后续独立门。
