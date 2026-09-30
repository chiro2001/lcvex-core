# T-20260920-015：RX CPU-visible observability Gate D 交接

冻结候选 `17d8d6f2`（tree `49ae77b4`）的完整 release-mode Gate D 已通过。权威
第二轮外层 exit 0，完整日志 71,090 bytes，SHA-256：

```text
467f957bfd18616723a657eb7f5d6af632034ce7c8c8495ac5d1d9ec5b175321
```

`make test`、coverage 8760、M2 base/cache 40+40、delay2 32、hardening 26、
Gate C 7、MMU 3、P4b 5 全绿；random seeds 1/2/3 各 100,002 commits，指令
覆盖 62/62，baremetal 1104-byte image 锁步 200 commits。没有跳过断言、比较、
random、coverage 或 baremetal，无 orphan QEMU/coordinator/Verilator，冻结 worktree
保持 clean。

第一次运行的内部 Gate 也全绿，但因 `tee` 目标目录未预建导致外层 exit 1 且缺完整
聚合日志，因此没有被接受；预建 ignored task 目录后完整重跑形成上述权威证据。

下一步只允许从 `17d8d6f2` 派生一行 `A64_FP_SIMD=1→0` 的标量板级 profile，并在
该 profile 的独立 SHA 上完成受影响 L0–L2。fresh Quartus physical 不得复用旧
T-007 fitted DB、T-009 UCP 或 T-010 SOF。完整工具、trace 和 artifact hash 见
[`T-20260920-015.json`](../tasks/evidence/T-20260920-015.json)。
