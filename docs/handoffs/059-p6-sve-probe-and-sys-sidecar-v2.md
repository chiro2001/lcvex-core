# LCVEX 交接文档 059：SVE/SME 探测 shim 修正与 sys sidecar v2

日期：2026-08-24（Asia/Shanghai）
前置：handoff 058（SVE/SME 探测兼容与 sidecar 缺口）。

## 1. 结论

对 handoff 058 加入的 SVE/SME 探测 shim 逐条做了真实 Linux 尾段验证，
发现并关闭五类语义缺口；同时把 ZCR/SMCR/CSSELR 纳入 sys checkpoint
sidecar v2，旧链不再需要 `--restore-smcr` 诊断 override。

尾段验证（`linux-resume-14m-fixed` 链，QEMU 11.1.0 + step 锁步）已从
seq=9999999 推进到约 seq=11.5M（本地 150 万条）全绿，随后在本地
seq=1548064（总 ~11.55M）暴露 RNDR/RNDRRS 运行时补丁读取；关闭该缺口
后正在继续向 14.8M 推进（见第 4 节当前状态）。

继续推进后又在本地 seq=1550247 暴露 EXTR（Linux alternatives 把
`ror #imm` 补丁成 EXTR），并在扩展 hard_p6_isa 边界时顺带暴露两个
P4 时期就存在的 SP 银行选择潜伏 bug。修复见第 2 节。

## 2. 修复清单（按尾段出现顺序）

1. **SMCR/SMPRI 编码混淆（真实 bug）**：`MRS x0, smcr_el1` =
   S3_0_C1_C2_6（0xd53812c0），`MRS x0, smpri_el1` = S3_0_C1_C2_4
   （0xd5381280）。旧 decode 把两者都归为 SREG_SMCR_EL1 且 MRS 恒返回 0；
   现拆为两个寄存器：SMCR 返回已保存 LEN，SMPRI 读 0、写忽略
   （QEMU SMIDR_EL1.SMPS=0，RES0）。
2. **CSSELR_EL1 编码错误（真实 bug）**：正确编码是 S3_2_C0_C0_0
   （QEMU opc1=2），旧 decode 误用 S3_1_C0_C0_6（保留编码，QEMU UDEF）。
   写入掩码从 0x1f 修正为 0xf（QEMU csselr_write）。
3. **SMIDR_EL1/AIDR_EL1 缺失**：Linux cpufeature 路径读取
   `SMIDR_EL1`（S3_1_C0_C0_6）与 `AIDR_EL1`（S3_1_C0_C0_7），
   QEMU 均恒 0；补为只读 ID 寄存器。
4. **RDSVL 未按 QEMU SME VQ 映射取整（真实语义缺口）**：QEMU -cpu max
   的 sme_vq.map = `SVE_VQ_POW2_MAP`（VL 128/256/512/1024/2048），
   `sve_vqm1_for_el_sm` 写 SMCR 后取“≤LEN 的最高支持档”。例如
   LEN=14 -> 有效 7 -> RDSVL#1=128 B；LEN=15 -> 256 B。RDVL（ZCR）不受
   影响（sve_vq.map 覆盖 0..15）。
5. **RNDR/RNDRRS 确定性镜像**：Linux 的 alternatives 在检测到 RNG 后把
   `arch_get_random` 桩替换为 `mrs x0, rndrrs`（S3_3_C2_C4_1）等。真实
   RNDR 值随机、无法差分；QEMU fork 在 `rndr_readfn` 中当 lcvex 激活时
   返回 `gt_get_countervalue`（当前指令可见计数），RTL 的 RNDR/RNDRRS
   MRS 在 EX 用同一 timer_count 镜像该值，并在提交时置 NZCV=0000
   （QEMU rndr_readfn 成功语义）。这不是跳过比较，而是把架构上非确定
   的寄存器确定化后继续逐指令严格比较。
6. **EXTR（ror #imm 别名）**：Linux alternatives 把 `ror wX, #8` 补丁成
   `EXTR Wd, Wn, Wm, #lsb`（S3_3 外，Data-processing extract，编码
   `sf 00 100111 N 0 rm imm6 rn rd`）。新增 ALU_EXTR：
   `{Rn, Rm} >> lsb`（lsb=0 时为 Rn），32 位形式 N/bit10 必须为 0，
   且 32 位回卷必须用 32 位宽度（首版误用 64 位公式，被 W 形式定向
   用例捕获并修正）。
7. **ERET/SP 银行两个潜伏 bug（P4 时期遗留，扩展测试边界暴露）**：
   - `commit_sp_wdata_r` 用 `spsr_el1[2]`（EL）选 SP 银行，应使用
     `spsr_el1[0]`（PSTATE.SP）：EL1t ERET 后可见 SP 是 sp_el0。
   - `assign sp = el ? sp_el1 : sp_el0` 同样用 EL 选银行，应使用
     `sp_sel`：EL1t 执行时 SP 访问的是 sp_el0。修复后 hard_p6_isa
     扩展到 86 条（含 EXTR）全绿，未发现其它回归。
8. **SPSel 解码过度限制**：DUT 要求 CRm==0，QEMU 接受任意 CRm 并只取
   `CRm[0]`（`imm & PSTATE_SP`）；放宽为不检查 CRm（CRm[3:1] 忽略）。
   hard_p6_isa 扩到 98 条（覆盖 W 形式 EXTR 与 SPSel#1 的 CRm=1 编码）
   全绿。

## 3. sys sidecar v2

`DutSysState`/`lcvex_sys_state` 新增 `zcr_el1/smcr_el1/csselr_el1`
三个 u64（magic `LCVXSYS2`、version=2、size=500）；协调器读取兼容 v1
（476 B，新字段为 0），恢复时写入 RTL。checkpoint.py 的 `read-sys`
同时解析 v1/v2。QEMU 保存侧填充 `env->vfp.zcr_el[1]`、
`env->vfp.smcr_el[1]`、`env->cp15.csselr_el[1]`。

验证：`make checkpoint-sys-smoke`（新增）在 hard_sve_probe 的 seq=48
保存 v2 sidecar（zcr=0xe、smcr=0xe、csselr=0xb），QEMU -incoming +
DUT 联合恢复 4 条全绿；旧 14m 链继续只读兼容（v1，字段 0）。

## 4. 尾段验证与资源

- 旧链 `linux-resume-14m-fixed.A056Gm` 的 QEMU 摘要绑定重建前的二进制；
  QEMU 重建（rndr 钩子 + v2 sidecar）后复制为
  `build/difftest/linux-resume-14m-rndr.A056Gm` 并更新 manifest
  （vmstate 格式未变，恢复兼容），后续续跑使用该链。
- 续跑脚本 `sim/difftest/run_lockstep_resume.sh`：从链中任意 seq 恢复
  QEMU（-incoming + RAM）+ DUT（arch/sys/timer/gic sidecar）继续锁步；
  支持 `RESTORE_SMCR` 诊断 override（默认空；handoff 058 的 0xf 假设
  经 DBG 实证为错误——QEMU 在 SME 探测前 SMCR_EL1=0）。
- 临时 DBG 钩子：协调器在 SMCR/SMPRI 探测指令提交时打印 DUT smcr_el1
  与 QEMU x0（定位用，尾段稳定后移除）。
- 资源遵守：续跑绑定物理核 0、50% 预算；每轮运行目录 128 MiB RAM
  临时文件随目录清理，链仅保留压缩文件。

## 5. 下一步

1. 继续尾段推进到 ~14.8M（RNDR 关闭后的首轮全量验证）；
2. 若再遇真实 SVE/SME 向量指令，停止 P6 快进并转入 P8 设计评审；
3. 尾段稳定后移除协调器临时 DBG 钩子并提交；
4. 侧车 v2 的 QEMU patch 0002 已同步（含 rndr 钩子），干净重放校验通过。
