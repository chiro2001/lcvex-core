# T-20260829-103 C4 dual-core baseline

状态：**complete，CORE_COUNT=2 baseline 测量已提交。**

```text
task=T-20260829-103 state=review base=2a697bb head=208b6a4cfee37ad86df4268ac3ad2018b3723769 branch=feature/T-20260829-103-c4-dualcore-baseline worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-092 files=docs/C4_DUALCORE_BASELINE.md,docs/handoffs/T-20260829-103-c4-dualcore-baseline.md,docs/tasks/evidence/T-20260829-103.json tests=l1msi-build/run-pass,dualcore-build/run-pass blockers=none next=c3-then-c4-scaling
```

## 结果速览

| 测量 | 值 |
| --- | --- |
| source SHA | 2a697bb922e6e7af353d399b2f0e6f6bb26d150c |
| Verilator | 5.050 |
| CORE_COUNT | 2 |
| COHERENCE_ENABLE | 1 |
| L1_SETS / L2_SETS / L2_WAYS | 64 / 256 / 2 |
| L1MSI build | 24.046 s wall, 434.5 MB max RSS |
| DUALCORE build | 371.038 s wall, 3364 MB max RSS |
| L1MSI smoke | 0.018 s, 15.6 MB, 28 PASS |
| DUALCORE smoke | 0.020 s, 15.7 MB, 51 commits, PASS |
| dir_sharers / dir_owner | 2 bit / 2 bit |
| ARB_MODE | FLAT_RR |
| PoC | 64-bit beat, 8 beats/line |

## 边界

- 这是 C2/CORE_COUNT=2 只读 baseline，不代表 4/8/16/32 核功能完成。
- 未修改 RTL/TB，未启动 Quartus。
- 所有重型 Verilator 均使用 `systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0` 和 `-j 1`，一次一个。

## 下一步

- 等 C3 四核实现稳定后，再按 `docs/C4_SCALE_PREWORK.md` 做 8/16/32 规模测量。
