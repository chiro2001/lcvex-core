# LCVEX 交接文档 072：CASP 后首个 WFI 停顿边界

日期：2026-08-25（Asia/Shanghai）  
前置：`071-p6-casp-lse128.md`  
当前分支：`feature/p6-system-reg-shim`  
最新提交：`c9c26f1 pipeline: separate fetch and data MMU issue stalls`

## 1. 当前精确进度

从 `tail-resume-ckpt17-20260825` 的 `RESUME_SEQ=999999` 重新运行后：

- CASP 修复后的 kernel 协调器已重建；
- `hard_lse_atomic` base/cache 各 100 条全绿；
- `make p5a` 三组 MMU 锁步全绿；
- 新建 `build/difftest/casp-debug-20260825`，每 100000 条保存一次差分
  checkpoint；从初始恢复点连续通过 500000 条；
- 再从该链 `RESUME_SEQ=499999` 续跑，至本地 `seq=5192`（即初始恢复点后
  累计 505193 条）仍无 PRE/COMMIT 差分错误；随后 QEMU 不再发下一条
  PRE，协调器等待 120 秒超时。

因此，CASP 后目前的阻塞边界是 QEMU 执行 WFI 后进入 halt/等待，而不是
CASP 四阶段事务分歧。最后已确认的指令为 `EOR x5,x5,x0`（动态地址
`0xffff800080315cac`），下一条路径进入 Linux 的等待逻辑。完整 Linux
从启动到该点的累计正确锁步量，按 handoff 067/068 的全局记录约为 **28M**，
再加本轮恢复点后的 505193 条；保守对外应写“约 28.5M 条”，不要把各个
checkpoint 的本地 seq 直接相加为精确全局编号。

## 2. 已提交修复

### CASP/LSE128

```text
b4b2ebb isa: add LSE128 CASP transaction
07fb860 difftest: handle CASP U128 memory effects
e5607fc test: cover CASP lockstep behavior
7d19a78 docs: record CASP deep-tail gap
```

CASP/CASPA/CASPL/CASPAL 支持 X 寄存器对，RTL 采用低读/高读/低写/高写
四阶段事务；QEMU 插件读取 U128 旧值并过滤比较失败的两段幻影 Store。

### 数据/取指 MMU issue 冻结

```text
c9c26f1 pipeline: separate fetch and data MMU issue stalls
```

`mmu_req_issue` 既可能表示取指翻译也可能表示数据翻译。旧逻辑把两者都
作为 ID/EX、EX/MEM、MEM/WB 的冻结条件，导致取指翻译接受后普通指令流可能
永久插泡；现在只用 `data_mmu_issue` 冻结数据侧流水线，取指翻译可独立推进。

## 3. 验证证据

```text
make compile                         PASS
make p5a                             PASS（24/26/40 条）
make p6-lse                          PASS（base/cache 各 100 条）
make m2-4b --only hard_tlbi          PASS（base/cache）
Linux CASP 后续窗口                 505193 条无差分错误，随后 WFI halt timeout
```

当前工作区干净；无后台 QEMU/Verilator/锁步任务。不要把“QEMU halt 后没有
继续 PRE”计为 DUT 差分失败，也不要把 WFI 直接降级为 NOP。

## 4. 下一步

1. 为 QEMU fork step hook 增加可观测的 WFI/WFE halt/唤醒事件协议，或在
   插件中明确将等待指令退休后暂停锁步而不伪造下一条 PRE；
2. DUT 增加 WFI/WFE idle 状态，并用 Generic Timer/GIC IRQ 唤醒；
3. 新增 `hard_wfi_timer_irq`，比较 WFI 提交、停顿、Timer IRQ、向量入口和
   ERET 全部状态；
4. 再从该边界继续 Linux，确认用户空间入口和 Gate E。
