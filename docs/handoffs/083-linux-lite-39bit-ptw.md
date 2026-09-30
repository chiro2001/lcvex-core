# LCVEX 交接文档 083：Linux lite 39 位页表遍历修复

日期：2026-08-25（Asia/Shanghai）  
前置：`082-buildtmp-defaults.md`  
当前分支：`feature/p6-system-reg-shim`

## 问题与根因

Linux lite 初次开启 `SCTLR_EL1.M` 后，在 `seq=1573` 的
`MSR SCTLR_EL1,x0` 分歧：QEMU 正常进入 `0x40514360`，RTL 上报同级
IABT（FSC=0x04）。现场状态为：

```text
TCR_EL1   = 0x00000035b5593519  (T0SZ=T1SZ=25)
TTBR0_EL1 = 0x40560000
TTBR1_EL1 = 0x40517000
```

`TnSZ=25` 表示 39 位输入 VA；4 KiB granule 的根表应从 L1 开始，首项
是 `TTBR0 + VA[38:30]*8`。原 RTL 无条件从 L0 读取
`TTBR0 + VA[47:39]*8`，对 `0x40514360` 读到了无效的 `L0[0]`，所以正确地
形成了错误的 level-0 translation fault。

## 实现

- `rtl/lcvex_mmu.sv` 根据当前请求所在 TTBR 区域的 T0SZ/T1SZ 计算输入
  VA 宽度，选择 L0（40–48 位）、L1（31–39 位）或 L2（25–30 位）作为
  PTW 起始级别；直接从 TTBR 基址读取该级表项；
- `tb/sv/lcvex_mmu_tb.sv` 新增 39 位 TTBR0 的指令取指翻译用例；
- `sim/difftest/test_program.py` 的 `hard_ttbr1` 改为 39 位 TTBR0/TTBR1
  根表与高 VA `0xffffff8040000000` 映射，覆盖真实的 TTBR1 分支；
- `lockstep_coordinator` 的失败转储补充 SCTLR/TCR/TTBR/MAIR、MMU 请求与
  PTW 状态，并在 COMMIT 不一致路径写入流水线状态，后续 fault 可直接复现。

## 验证（均通过）

```text
make sim-sv-mmu
  PASS（含 39 位 L1 起始页表单元测试）

bash sim/difftest/run_m2_4b.sh --only hard_ttbr1
  PASS（base + I/D L1 + L2，分别 30 条 QEMU step lockstep）

make p5a
  PASS（p5a_mmu 24、p5a_mmu_el0 26、p5a2_fetch 40 条）

Linux lite KERNEL=1 QEMU step lockstep
  PASS：10,000 条；PASS：50,000 条；PASS：100,000 条（含压缩 checkpoint）

主线 checkpoint 恢复（`diff-999999`）
  PASS：额外 1,000,000 条；每 100k 生成压缩 diff checkpoint
```

所有 lite 日志与生成物位于 `build/tmp/linux-lite-6.6/`；未创建新的 `/tmp`
大文件。主线新链位于 `build/tmp/linux-main-1m-20260825/chain/`，共约 14 MiB；
恢复脚本的未压缩 RAM/device sidecar 默认临时写入 `build/tmp` 并在退出时清理。
本次修改后的完整 `taskset -c 1-5 make gate-d` 也已通过。

## 下一步

1. 用 `build/tmp` 中独立日志/链把 Linux lite 从 reset 继续扩至 100k 以上，
   再确认 QEMU 串口出现静态 `/init` 的输出；
2. 主线可从 `build/tmp/linux-main-1m-20260825/chain/diff-999999` 继续
   checkpoint 续跑，和 lite 使用不同物理核、socket 与 checkpoint 目录；
3. Gate E、用户空间和完整 Linux 验收仍未完成，不能据此宣称 P6 完成。
