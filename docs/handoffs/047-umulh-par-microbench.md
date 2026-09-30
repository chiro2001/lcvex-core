# LCVEX 交接文档 047：UMULH 与系统 microbench 锁步补强

日期：2026-08-24（Asia/Shanghai）

## 本轮变更

- 补齐 `UMULH Xd, Xn, Xm`（Data-processing 3-source）解码和提交：
  `bit22:21=10`、`[15:10]=011111`；不更新 NZCV。
- `lcvex_muldiv` 增加 128 位移位累加寄存器，64 个计算周期后返回
  无符号 64×64 乘积的高 64 位；已有 MUL/MADD/除法路径保持 64 位结果。
- `baremetal/tests/t_sys.c` 增加两组 UMULH 边界值：
  `0xffffffffffffffff×2=0x1_ffff...fffe` 的高半部为 1，
  `0x100000000×0x100000000` 的高半部为 1。
- `a64.py`、随机生成器和编码器自检加入 `UMULH`；`qemu_trace.py` 兼容
  gzip trace（QEMU 超时无 footer 时保留已解出的完整记录，由提交数检查
  判断是否真正截断）。
- 修正 MMU 关闭时 Normal RAM 的 `PAR_EL1` 成功属性：与 QEMU virt
  对齐为页号 | `0xb00`（原实现漏掉 Inner-shareable 属性 `0x300`）。

## 验证结果

```text
make compile                         PASS
make test                            PASS
make microbench                      PASS: mb_all (2666 cycles)
MB_ONLY=sys ...                      PASS: sys (379 cycles)
MAX_INSNS=12000 裸机 QEMU/RTL 锁步   PASS（含两条 UMULH）
make difftest-random SEED=7 LENGTH=2000 PASS（2002 条）
```

锁步命令使用 `taskset -c 0`，协调器和 QEMU 均限制在同一物理核；随机和
Linux 长任务期间协调器约 138MB、QEMU 约 139–150MB RSS，`/tmp` 约 43%。
`build/difftest/step_fail.txt` 曾保存 UMULH 前的 PAR 属性分歧，修复后由
后续通过结果覆盖。

## 当前状态与后续

Linux 14M 窗口已全绿（`seq=0..13,999,999`），首个 `UMULH` 缺口及随后
发现的 `RBIT` 缺口均已关闭（详见 handoff 048）。P6 仍未达到 Gate E：
PSCI、用户空间入口和长时间稳定运行尚未完成。差分 checkpoint 仍是全量
gzip 基线，增量 RAM 格式按 handoff 044 规划但未实现。
