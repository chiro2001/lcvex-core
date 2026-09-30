# T-20260920-043：B25 microbench/CoreMark 冻结候选 Gate D

```text
task=T-20260920-043
state=done
candidate=f6633e70dd4d6b2f9a6aa932daee7c7e8252ac8d
tree=49fab30e4d8d49a5af24a81a49d8cf95f2cded8c
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260920-043-gate
detached=true
started_at=2026-09-20T23:36:28+08:00
finished_at=2026-09-20T23:48:02+08:00
elapsed_seconds=694
```

在 `local` resource-lock 内对 exact detached candidate 运行未修改的
`bash sim/difftest/run_gate_d.sh`，outer exit 0，最终标记为
`PASS: Gate D 系统回归全部通过`。候选 HEAD/tree 和 tracked-clean 状态在运行前后
完全不变；没有 `--only`、`--skip-baremetal`、断言关闭或参考结果修改。

主要结果：coverage 8,760 points；M2 base/cache 各 40/40；delay2-cache 32/32；
P5a hardening、Gate C 7/7、P5a MMU 3/3、P4b 全绿；random seed 1/2/3 各
100,002 commits，ISA expected coverage 62/62、总计 300,006 commits；baremetal-C
镜像 1,104 bytes，200 commits 锁步通过。日志共有 151 个 `OK(green)`、0 个 red。

同一 candidate 还复跑 T-042 affected union：双 clean build/provenance/parser L0、
L1D-WB 同拍仲裁定向和 behavioral full-SoC `t/v` 全绿；payload hash 与 T-042 一致，
`MBPASS 24 8679CF21`、CoreMark short CRC 和 `cycles=1479468 score=INVALID` 均匹配。

本任务未访问 GamePC、Quartus/JTAG/真板，也未产生 SOF 或有效 CoreMark 分数。完整
结构化证据见 [`T-20260920-043.json`](../tasks/evidence/T-20260920-043.json)。下一步
T-044 只消费该冻结 SHA，执行 fresh no-FP Quartus physical/UCP；不得复用旧 fitted DB。
