# LCVEX 交接文档 043：PCREL 别名 TB 复用（next_pc 误报）+ PACIASP 缺口

日期：2026-08-24（Asia/Shanghai）
前置：handoff 042（P1 trace 切片/分区追溯）；041 起工作区未提交挂账。

## 1. 状态总览

- 本地 `main` HEAD=`839408a`，工作区脏（041 清单未提交 + 本轮修改）。
- 内核锁步（P6，max 8M）：修复 CF_PCREL 别名复用后通过原分叉点
  seq=5652559，推进到 seq=5691354（新缺口 PACIASP UDEF）；RTL 修复后
  8M 重跑验证中（后台 setsid，`/tmp/ls_8m_fix2.log`）。
- QEMU fork（../qemu）工作树含 step hook 补丁（含本轮 CF_PCREL 修复，
  未提交）；`qemu/patches/0001-...patch` 已重生成并在干净 v11.1.0 上
  验证可重放。

## 2. 根因：CF_PCREL 下 TB 缓存按物理页复用，插件上报陈旧 vaddr

### 2.1 现象

- seq=5652559：BL `0x97d51e85` @ 0xffff800081b490ac。
- 架构目标 = 0xffff800081090ac0（imm26 符号扩展 -0xAB85EC）：
  DUT next_pc 正确；QEMU next_pc=0x41090ac0（目标物理地址/低别名），
  其余寄存器（含 x30=0xffff800081b490b0）、store、nzcv 全部一致。

### 2.2 取证链（三重证据）

1. QEMU 侧 BL 的 x30=pc+4 为高地址，说明 QEMU 内部 pc 就是高 VA，
   目标计算正确（不可能同时算错下一个 pc）。
2. trace 模式独立复现：BL 行 next_pc=0x41090ac0，随后逐条
   `bti c`/`mov x8,x0` 均报低地址，但 x 寄存器全是高地址派生值
   （如 x8=0xffff8000821fa000）——执行正确，仅 pc 上报错。
3. QEMU 内部机制：`accel/tcg/cpu-exec.c` tb 缓存键
   `h = tb_hash_func(phys_pc, (cflags & CF_PCREL ? 0 : s.pc), ...)`，
   比较时 `(cflags & CF_PCREL) || tb->pc == pc`——PCREL 的 TB 只按
   物理页匹配、完全忽略 VA；而 aarch64 默认 `tcg_cflags_set(CF_PCREL)`
   （target/arm/cpu.c:1824）。
4. 低地址缓存 TB 的来源：head.S 早期（MMU 未开、低别名 VA=PA 阶段）
   执行过 __pi_memset 所在物理页（trace limit=200000 截到
   `pc=0x41b485dc bl #0x41090db0`）；启动后期 start_kernel/fdt 流程
   以高 VA BL 到同一物理页 → 命中低 VA 的旧 TB。

### 2.3 结论

QEMU 实际执行正确（PCREL 语义：TB 入口 env->pc 已由 BL 更新为高 VA，
生成代码按入口 pc 做相对计算，故寄存器/访存与 DUT 逐位一致）；错误
只在插件上报：`insn->vaddr` 是 TB 翻译期的 db->pc_next，别名复用旧
TB 时该值陈旧。DUT 无错。插件 vaddr 来自 `plugin_gen_insn_start`
（plugin-gen.c: db->pc_next）。

### 2.4 修复（QEMU fork）

- `accel/tcg/cpu-exec-common.c`：LCVEX step 模式 cflags 分支增加
  `cflags &= ~CF_PCREL;`。清掉 PCREL 后缓存键包含 VA，别名不再跨
  复用，vaddr 恒为真实翻译 VA。执行语义不变（非 PCREL 生成代码在
  TB 入口显式 set pc）。
- `qemu/patches/0001-tcg-arm-lcvex-difftest-step-hook.patch` 已用
  `git diff 84f0721` 重生成，`git apply --check` 干净 v11.1.0 通过。
- 验证：锁步通过 5652559；后续 memset 循环（0xffff800081090c2c..）
  在 recent_window 中全部正确报高地址。

## 3. 新缺口（seq=5691354）：PACIASP 未实现 -> UDEF

### 3.1 现象

- 0xffff800081b43fac 处执行 0xd503233f（paciasp，HINT #25）。DUT
  UDEF（ESR EC=0），QEMU 按 NOP 提交、next_pc=pc+4、x30 不变
  （SCTLR_EL1.EnIA=0，PAC 未启用）。
- 注意：该地址在 vmlinux 中原本是 `ldr x0,[sp,#32]`——运行时代码页
  内容与镜像不同（内核自改码/解压流程覆盖），但 DUT 与 QEMU 取的
  字节一致，仅译码语义分歧；锁步 store 比对全过。

### 3.2 修复（RTL）

- `rtl/lcvex_decode.sv`：把原 BTI 分支泛化为 HINT 空间
  `(insn & 32'hFFFFF01F) == 32'hD503201F`，排除 YIELD/WFE/WFI/SEV/
  SEVL（事件语义，留待实现）后按 NOP 处理。覆盖：
  - PACIASP/PACIBSP/AUTIASP/AUTIBSP（PAC 未启用时 = NOP）；
  - BTI j/c/jc（SCTLR.BT=0 时无检查副作用；顺带补上原缺失的
    BTI j 0xD503241F 覆盖）；
  - PSSBT/PSSBB（无 SPE 时）、ESB/PSB/CSDB 等。
- 与 QEMU 对齐依据：trans_NOP 对 HINT 空间兜底，实测 0xD503233F
  提交为空操作。
- DUT 已增量重建（`make lockstep-build-kernel`，二进制时间戳晚于
  RTL 修改）。

### 3.3 TLBI VAALE1IS 缺口（seq=5691833）

- （补充）首轮验证 TLBI 时 DUT 超时未提交：TLBI 脉冲同拍中止了 MMU
  在途的 next_pc 取指页表遍历，`fetch_trans_busy` 只能由 mmu_done 清
  除，walk 被丢弃后 done 永不到来，`fetch_next_settled` 永假，维护
  指令在 ID 死锁。修复：lcvex_core.sv 取指在途清除条件加入
  `tlb_invalidate`（冲刷后对 next_pc 重新翻译再提交）。

- 现象：0xffff8000800b7504 处 0xd50883e1 = (op0=1, op1=0, CRn=8, CRm=3,
  op2=7) = TLBI VAALE1IS（QEMU tlb-insns.c 表确认；RTL 原只支持
  VMALLE1IS/VMALLE1/错误映射的 VAE1IS），DUT UDEF、QEMU 正常提交。
- 修复：RTL 维护译码按 QEMU EL1 表全集接受 (CRn=8, CRm∈{3,7},
  op2∈{0,1,2,3,5,7}) 为 MAINT_TLBI；DUT 统一整表失效（合法超集，
  TLB 状态不入锁步比较），op2=4/6（QEMU 表外）保留 UDEF。顺带修正
  原 VAE1IS 编码错误（(8,1,0) -> (8,3,1)，(8,1,*) 实为 EL2 区）。

## 4. 验证状态

- 修复 1（PCREL）验证：通过 seq=5652559（原 BL 分叉）并继续到 5691354。
- 修复 2（HINT/PAC）验证：通过 seq=5691354（paciasp），推进到 5691833。
- 修复 3（TLBI 全集）验证：第三轮 8M 重跑进行中。

## 5. 遗留 / 注意

- P1 trace 模式（run_qemu.py）不设 LCVEX_DIFFTEST_STEP，深启动内核
  trace 仍会遇到同一 vaddr 陈化问题；后续深启动 trace 生成需设
  LCVEX_DIFFTEST_STEP=1，或 fork 增加独立 trace 门控（只清 PCREL、
  保留多指令 TB）。
- WFE/WFI/SEV/SEVL/YIELD 仍为 UDEF（事件语义未实现），属已知缺口。
- 不同运行间同一阶段的指令号有小幅差异（如 0x41b39xxx 循环入口
  0.9M~5.4M 不等），未影响逐指令比对；推测与 FDT/循环路径相关，
  后续如需可复现性再排查。

## 6. 待提交文件

- `qemu/patches/0001-tcg-arm-lcvex-difftest-step-hook.patch`（更新）
- `rtl/lcvex_decode.sv`
- `docs/handoffs/043-kernel-lockstep-pcrel-alias-paciasp.md`
- 041/042 挂账清单继续（工作区未提交状态延续）。
