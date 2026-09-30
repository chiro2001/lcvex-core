# T-20260902-009 F1a 锁步三类修复 handoff

```text
task=T-20260902-009
state=done
base=20639c8defd66407af87292844fd902b6bf00f6a
head=692936c3dd21e20890f96bbd448f87c16bb82737
branch=fix/T-20260902-009-f1a-lockstep-fixes
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260902-009
sent_at=2026-09-02T18:12:00+08:00
received_at=2026-09-02T18:12:30+08:00
reported_at=2026-09-02T18:54:30+08:00
```

## 结论

F1a-on 完整 Gate D 暴露的 9 个锁步失败已定位为三类流水线前递/读值语义
问题，并在 `rtl/lcvex_core.sv` 做最小修复。修复后在 F1a-on 的
base/cache/delay2 三配置下复跑失败用例：hard_timer、hard_adc_sbc、
hard_sve_probe、hard_postpre 共 12 个 case 全部与 QEMU 完全一致；
F0-off 的同一组 4 个定向 case 也全部通过，未发现 F0 路径回归。

## 三类根因与修复

### 1. Timer/RNDR 计数 off-by-one

F1a 允许更老的指令停留在 EX/MEM 或 MEM/WB，而 `cntpct_r` 只在提交时
+1。原 `timer_read = cntpct_r + 1` 只计算了已提交计数，在紧邻的
MRS/RNDR 上会少算在途更老指令，导致 `CNTVCT`、`RNDR` 都比 QEMU 小 1。

修复在 EX 级增加“指令可见计数”：

```systemverilog
timer_ex_count = cntpct_r + 1
                 + (exmem_valid ? 1 : 0)
                 + ((memwb_valid && !memwb_committed_r) ? 1 : 0);
```

Timer/RNDR 的所有 MRS 读值（CNTPCT/CNTVCT/TVAL/CTL/RNDR 等）改用该
计数。这样既保证提交写回正确，也保证 EX 前递值正确。

### 2. ADC/SBC/NGC 进位标志前递

原 ALU 的 `.cin` 直接取已提交 `nzcv[1]`。F1a 下前一条 `set-flags`
指令可能仍在 EX/MEM 或 MEM/WB（尚未提交），因此 `NGC` 在 C=1 时
误用 C=0，得到 -1 而非 0。

修复新增 `nzcv_alu`，从 EX/MEM 与 MEM/WB 的前递 NZCV 中取进位输入，
并刻意排除当前 ID/EX 自身的 `set_flags`，避免 `ADCS/SBCS` 把自身输出
进位反灌回输入。

### 3. post-index load/store 基址前递

`gprv` 原来只前递 EX/MEM 与 MEM/WB 的 `wb3`（pre/post 基址写回），
缺少 ID/EX 的 `wb3`。F1a 下紧邻的 post-index 指令停留在 ID/EX 时，
后续指令在 IF/ID 译码读到旧基址：`ldrb w4,[x20],#-1` 实际用旧地址
读到 `0xbb`，写回也偏向 `0x44090010`，与 QEMU 的 `0/0x44090011` 不符。

修复在 `gprv` 前递链最前面增加：

```systemverilog
else if (idex_valid && idex_d.wb3_we && idex_d.wb3_rd == i[4:0])
  gprv[i] = idex_d.wb3_extra;
```

## 验证

- `make compile`：PASS
- F1a-on 定向锁步（12/12 PASS）：
  - base `build/verilator_lockstep_f1a`
  - cache `build/verilator_lockstep_f1a_cache`
  - delay2 `build/verilator_lockstep_f1a_delay2`
  - 每个配置下 hard_timer:40、hard_adc_sbc:30、hard_sve_probe:60、
    hard_postpre:70
- F0-off 定向锁步（4/4 PASS）：
  - `build/verilator_lockstep_f0`（显式 `-GFETCH_FIFO_ENABLE=0`）
  - 同上 4 个 case

## 边界

- 未修改 QEMU、测试期望、关闭断言、差分或公共 ABI。
- 未运行完整 Gate D；完整 Gate D 由集成者在合并 SHA 复跑。
- 日志/精确命令/资源见 `docs/tasks/evidence/T-20260902-009.json`。
