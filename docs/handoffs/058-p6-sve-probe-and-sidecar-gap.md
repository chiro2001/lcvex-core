# LCVEX 交接文档 058：P6 SVE/SME 探测兼容与 sidecar 缺口

日期：2026-08-24（Asia/Shanghai）
前置：handoff 057（P6 系统寄存器批量对齐）。

## 1. 当前结论

固定 QEMU 的 Linux 尾段在总 seq 约 10.1M 进入 SVE/SME CPU feature 探测。
这不代表 P8 已开始；当前只加入让标量 Linux 探测继续所需的最小兼容语义：

- ZCR_EL1：保存/读取 LEN 低 4 位；
- SMCR_EL1/SMPRI_EL1：保存/读取 LEN 或 RAZ/WI 探测；
- RDVL/RDSVL：按当前 ZCR/SMCR LEN 计算标量 VL 字节数，不实现 Z/P/ZA
  向量寄存器或任何向量 ALU；
- CSSELR_EL1：Cache level selector 低位读写；
- ERET 到未对齐目标：EC=0x22、ESR=0x8a000000（QEMU PC alignment
  fault），不再误报 EC=0x21 IABT。

当前这些改动仍在 feature 分支工作区，尚未合入 main；固定 QEMU 的 44 个
ID/CLIDR 批量闭合和 hard_id_sysreg 通过已在提交 930b413 中完成。

## 2. 已发现的恢复限制

seq=9999999 的旧 sys sidecar 在新增这些控制寄存器之前生成，QEMU 保存点的
SMCR_EL1 已为 0xf，而旧 DUT 注入默认为 0。为定位尾段，协调器临时提供：

~~~text
--restore-smcr 0xf
~~~

该选项只允许受控快进使用，不能作为 Gate E 或正式 checkpoint 恢复证据。
正式格式下一版必须在 QEMU/DUT sys sidecar 中加入至少：

- ZCR_EL1；
- SMCR_EL1；
- CSSELR_EL1；
- 后续实际出现的 ZCR/SMCR/PMU/Timer/GIC 控制字段。

应同步更新 magic/version/size、QEMU patch、checkpoint.py reader 和恢复
smoke；旧 sidecar 继续只读兼容但不得标记为完整恢复。

## 3. 资源与保留资产

- 所有 QEMU/Verilator 长命进程已停止；
- 只保留 build/difftest/linux-resume-14m-fixed.A056Gm 的约 14 MiB 压缩
  链和失败日志，原始 128 MiB RAM 已删除；
- 该链可从 seq=9999999 继续，但因 sidecar 缺 SMCR 只能用于诊断性 override；
- 已用 fresh Verilator re-elaboration + --restore-smcr 0xf 运行 900,000 条
  ERET/SME 探测窗口并通过；更长尾段尚未重新验收；
- 不生成无上限 trace，仍遵守单物理核和主机 50% 资源预算。

## 4. 下一步

1. 将 ZCR/SMCR/CSSELR 加入 sys sidecar v2，修复旧链只能 override 的限制；
2. 重新跑从 seq=9999999 到约 14.8M 的尾段，确认 SMCR 写回和 ERET
   PC alignment 在 clean build 下全绿；
3. 新分歧若是实际 SVE/SME 向量指令，停止 P6 快进并转入 P8 设计评审，
   不继续堆叠伪标量实现；
4. 评估 QEMU/Verilator 单核运行的 jemalloc/tcmalloc 和 PGO，必须以固定
   1M workload、manifest、提交序列和结果 hash 做 A/B，优化不进入功能提交。
