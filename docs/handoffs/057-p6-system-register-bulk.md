# LCVEX 交接文档 057：P6 系统寄存器批量对齐

日期：2026-08-24（Asia/Shanghai）
前置：handoff 056（Linux MMU checkpoint 联合恢复）。

## 1. 为什么改成批量清单

Linux 深启动会按 CPU feature 表读取一组 ID/兼容寄存器。逐条等到差分失败
再补会反复停在 REVIDR、ISAR2、SMFR0、AArch32 ID；这些寄存器本身都是
固定 QEMU profile 的只读值。因此 P6 现在先批量闭合标量只读 ID/CLIDR
集合，再继续运行时缺口。

这不等于把 QEMU -cpu max 的所有功能伪造到 RTL：

- MMU、异常、DAIF、Timer、GIC 等有副作用寄存器仍由显式状态逻辑处理；
- FP/NEON/SVE、PMU/JTAG、EL2/EL3 虚拟化状态按 P7–P9 路线实现；
- 未实现功能的 ID 值必须与 profile 一致，不能让 Linux 错误启用尚未存在
  的执行单元。

## 2. 批量取证与实现

- scripts/qemu_sysreg_inventory.py 解析固定 QEMU
  target/arm/cpu-sysregs.h.inc 的 44 个 DEF，生成 MRS probe，以
  -cpu max,has_el3=false,has_el2=false、-icount shift=0 取证；
- 输出格式为 LCVX-qemu-sysreg-inventory-v1，包括寄存器名、五元组编码、
  指令、返回值、异常和 EC；产物在 build/difftest/，不提交 git；
- rtl/lcvex_pkg.sv/lcvex_decode.sv 增加 7 位 sysreg selector，覆盖：
  AA64 PFR/DFR/AFR/ISAR/MMFR/ZFR/SMFR/FPFR、REVIDR，以及 AArch32
  PFR/DFR/AFR/ISAR/MMFR/MVFR 和 CLIDR_EL1；
- sim/difftest/test_program.py 新增 hard_id_sysreg，逐条读取全部
  44 个寄存器；run_m2_4b.sh 将其纳入 base/cache 两配置。

入口：

~~~sh
make qemu-sysreg-inventory
bash sim/difftest/run_m2_4b.sh --only hard_id_sysreg
~~~

## 3. 验证结果

- QEMU inventory：44/44 条均取得返回或异常结果；
- hard_id_sysreg：47 条（44 个读取 + 循环边界）base/cache 全部与 QEMU 一致；
- hard_p6_isa：包含新增 Linux 早期 ID 读取，base/cache 仍全绿；
- Verilator -Wall --assert 构建通过；sysreg enum 扩为 7 位并抑制旧
  6 位字面量的宽度告警；
- 没有留下 QEMU、Verilator 或 coordinator 长命进程。

## 4. 当前 Linux 尾段

修复 live-SP、checkpoint DAIF 注入后，受控 continuation 从 seq=9999999
运行到 seq=10980694，已关闭并批量覆盖：

- MRS DAIF sidecar 位移；
- REVIDR_EL1；
- ID_AA64ISAR2_EL1；
- ID_AA64SMFR0_EL1；
- ID_DFR0_EL1/ID_DFR1_EL1。

失败链和压缩 sidecar 仍在 build/difftest/linux-resume-14m-fixed.*，
可从 seq=9999999 继续；没有保留无上限 trace。

## 5. 下一步与边界

1. 用批量 ID 实现从 seq=9999999 继续剩余约 4.8M，目标总 seq 约 14.8M；
2. handoff 058 已识别 ZCR/SMCR/CSSELR 和 RDVL/RDSVL 的 P6 兼容边界；新的
   差分若落在非 ID 的有状态寄存器，按访问权限/副作用实现并更新
   checkpoint sidecar，而不是继续扩展常量表；
3. 进入用户空间前再验证 Timer IRQ/WFI、LSE/LDXP、GIC pending 和
   Device memory；P7 FP/NEON、P8 SVE256、P9 PMU/JTAG 仍未提前实现。
