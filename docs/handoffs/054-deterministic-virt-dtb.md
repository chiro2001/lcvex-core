# LCVEX 交接文档 054：确定性 virt Device Tree

日期：2026-08-24（Asia/Shanghai）
前置：handoff 053（GIC checkpoint sidecar）。

## 1. 当前结论

Device Tree 生成从散落的手工命令收敛为可重复入口：
`scripts/validate_virt_dtb.py` 固定 QEMU 11.1.0 的
`virt,gic-version=2,dtb-randomness=off`，生成 compact DTB、校验当前 RTL
平台所需节点，并输出 SHA256 摘要。`make dtb-smoke` 已通过。

## 2. 校验范围

脚本验证：

- `memory@40000000`：`0x40000000..0x48000000`，128 MiB；
- `pl011@9000000`：PL011，`0x09000000/0x1000`；
- `intc@8000000`：GICv2，GICD `0x08000000/0x10000`、GICC
  `0x08010000/0x10000`；
- `timer`：`arm,armv8-timer`；
- `psci`：`method = "hvc"`；
- 单核 `cpus/cpu@0` 和 virt compatible。

实测输出：compact DTB 7701 字节，原始 dump 1 MiB，SHA256：

```text
a4f17ed497c6af38e37eb73776a292c7ffedb6be6f38fc7e4810399992b8c8b9
```

## 3. KERNEL 锁步路径

KERNEL 模式的实际 FDT 仍由 QEMU `-kernel/-append` 生成并导出，因为
`chosen.bootargs` 是 QEMU 启动时写入的；这一路径不能直接替换为无 bootargs
的 dumpdtb。导出命令文件、1 MiB FDT 文件和默认路径现位于
`build/difftest/`，不再长期使用 `/tmp`。

协调器双镜像布局保持不变：

```text
0x40000000  bootloader / RESET_PC
0x40080000  Linux Image
0x44000000  协调器加载的实际 FDT
```

## 4. 验证命令

```bash
make dtb-smoke
python3 -m py_compile scripts/validate_virt_dtb.py
bash -n sim/difftest/run_lockstep_step.sh
```

本轮没有启动 Linux 长跑，也没有留下 QEMU/Verilator 长命进程；大文件仍只
保留在 `build/`，不提交 git。

## 5. 下一步

1. 使用 handoff 055 的输入/链完整性 manifest，重新从确定性 checkpoint 恢复到
   约 14.8M，继续 Linux step 锁步；
2. handoff 056 已完成 `SCTLR.M=1` checkpoint 的 5 条联合恢复；继续验证
   更深 TLB/Device memory 状态；
3. 重点处理 memblock/GIC init/timer IRQ 后续缺口，再评估 WFI、LSE 原子和
   用户空间入口；
