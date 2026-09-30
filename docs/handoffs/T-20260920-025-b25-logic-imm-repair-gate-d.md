# T-20260920-025：logical-immediate 修复候选 Gate D 交接

```text
task=T-20260920-025 state=done
candidate=c31b3aea754769304ab7c9a24ef2f78c8120bc2a
tree=7ea2ea1c473a7c2c2b0eafe4dfd0fdfab9273c03
outer_exit=0 elapsed=737s
```

完整 release-mode Gate D 在 detached、前后 clean 的精确候选上通过。没有使用 skip、
没有缩短 random、没有关闭断言/比较，也没有修改 QEMU、reference 或 expected。

关键结果：

- `make test`、coverage `8760`：PASS；
- M2-4b/4c `40/40 + 40/40`、delay2 32 定向 + 3000 commits：PASS；
- P5a hardening `26/26`、Gate C `7/7`、P5a MMU `3/3`、P4b `5/5`；
- random seed 1/2/3 各 `100002` commits；
- ISA coverage `62/62`，observed families=63，总提交 `300006`；
- baremetal-C 1104 bytes，锁步 `200` commits；
- 最终标记：`PASS: Gate D 系统回归全部通过`。

完整日志 437278 bytes，SHA-256：
`adf657003d73a394162645e9a1dff3c000a04ae438d0d06f5ebc599a1658ac4f`。

本任务仅使用本机 `local` heavy 锁；未访问 GamePC、Quartus、JTAG 或板卡。下一步从
该 Gate-D-passed candidate 派生唯一一行 `A64_FP_SIMD=0` 的 scalar board profile，
随后新建 task-owned 远端 root 执行 fresh physical。精确工具与 artifact hash 见
[`T-20260920-025.json`](../tasks/evidence/T-20260920-025.json)。
