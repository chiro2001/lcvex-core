# LCVEX 交接文档 008：M0 前半完成（R0.1–R0.4 修复与定向测试）

日期：2026-08-23（Asia/Shanghai）
前置：`docs/PROJECT_STATUS.md`（外部评估，权威依据）、handoff 007。
当前分支：`feature/p5a-arch-fixes`（基于 `verify/p5a-hardening-tests`）。

## 1. 本阶段完成了什么

按 handoff 007 与 PROJECT_STATUS M0 的顺序 1/2，完成：

1. **`verify/p5a-hardening-tests`（`4281fcb`）**：9 组定向锁步测试，
   修复前全部 RED（每种失败原因都与评估 R0.1～R0.4 一致）：
   - `hard_nzcv`：MRS/MSR NZCV 位域 `[31:28]`
   - `hard_movwide`：MOV wide 保留 `opc=01` -> UDEF
   - `hard_addsub_shift`：ADD/SUB 立即数 `LSL#12`
   - `hard_bcond_f`：B.cond `cond=1111` 恒跳
   - `hard_ap_matrix`：4 AP × EL0/EL1 × read/write 全组合
   - `hard_af`：L3 `AF=0` -> AccessFlag fault
   - `hard_uxn_pxn`：取指 UXN/PXN/AP=01 矩阵
   - `hard_ttbr_gap`：T0SZ=16 下 gap VA `0x1000000000000`
   - `hard_pa_oob`：L3 映射 PA 越出 SRAM/QEMU RAM
2. **`feature/p5a-arch-fixes`（`8a1a7b6`、`fd7c987`）**：
   - `lcvex_decode.sv`：NZCV MRS `nzcv<<28`；MOV wide `opc=01` -> UDEF；
     ADD/SUB 立即数 `sh=1` LSL#12；B.cond 0xf 恒跳；扩展寄存器
     （bit21=1）-> UDEF。
   - `lcvex_core.sv`：MSR NZCV 取 `wdata[31:28]`。
   - `lcvex_mmu.sv`：AP 权限矩阵按 QEMU `simple_ap_to_rw_prot` /
     `get_S1prot` 重写；L3 AF 检查。

所有语义以 QEMU 实跑（`qemu_probe.py --el1`）为最终裁决，每个测试先
确认 QEMU 权威行为，再固化为 RTL 锁步。

## 2. 回归结果（修复后全绿）

- `run_p5a_hardening.sh`：9/9 通过。
- `make p4c`（7 组）、`make p5a`（3 组）、`make q6`、`make lockstep-q5`、
  `make lockstep`（P2 36 条）通过。
- `make difftest`（P1/P2 trace）、`make difftest-hazard` 通过。
- `make difftest-random`：seed 1～5，各 100k 提交通过。
- `make test`（toolcheck/lint/SV smoke/Cocotb）通过。

## 3. 分支与合并状态

- `verify/p5a-hardening-tests` 和 `feature/p5a-arch-fixes` 尚未合并回
  `main`。合并前更新 PROJECT_STATUS 阶段表与 Gate 文案，附回归摘要。
- `docs/ISA_SCOPE.md` 已更新为精确支持矩阵（解码边界、AP 表、取指规则、
  AF/TTBR gap/PA 越界）。
- `docs/PROJECT_STATUS.md` 已追加“P5a-Hardening 进展”与 M0 剩余项。

## 4. M0 剩余项（下一步前应关闭）

- 系统寄存器 reset/读写掩码/EL 权限/提交时机表格（NZCV 已修）。
- Gate 文案与支持矩阵完全对齐（ISA_SCOPE 已更新，阶段表待合并时修订）。
- 失败样本的 Cocotb / 独立 SV testbench 双轨复现（M1/CI 阶段补齐）。
- R1 状态保持：TLBI/TLB 一致性、ESR_EL1/FAR_EL1 完整 syndrome、
  SCTLR/TCR/TTBR 写后失效、块描述符、跨页访问（R0.7，随 M1 内存握手）。

## 5. 下一步

按 PROJECT_STATUS 顺序 3：`feature/commit-memory-handshake`（M1）——
统一 stage `valid/ready` 与显式 `commit_fire`，取指/数据/PTW 改为
request/response，Store 副作用与提交一一对应，加随机延迟与 SVA。
**不要**在握手协议落地前直接开发 Cache（教训见 handoff 006/007）。
