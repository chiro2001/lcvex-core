# LCVEX 交接文档 019：P6/Linux 前 R1 - 块描述符（2 MB / 1 GB）完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 018（Gate D 完成）、PROJECT_STATUS M2。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（块描述符）

MMU 支持 4K 颗粒下 L1（1 GB）与 L2（2 MB）块描述符（QEMU ptw
`lpae_block_desc_valid`：4K 颗粒下 level 1/2 块合法），此前遇到块描述符
一律按 fault 处理。Linux 线性映射使用块映射，这是 Linux 前必要能力。

### 1.1 RTL 改动（lcvex_mmu）

- 遍历重构：L0 只接受表描述符（4K 颗粒下 L0 块非法）；L1/L2 遇 bit1=0
  为块描述符，记录 `walk_level_r`（1=1GB / 2=2MB）进入统一完成态
  `S_COMPLETE`；L3 页描述符同样进入 S_COMPLETE。
- `S_COMPLETE`：AF（QEMU HA=0 语义）、权限（AP/UXN/PXN）、PA 越界检查
  与 TLB 填充统一处理。
- 输出地址函数：`desc_pa`（PA = {desc OA[47:N], va[N-1:0]}，N=30/21/12）
  与 `desc_pa_page`（TLB 记录的 4 KiB 页基址 [47:12]）。
- `walking` 覆盖 S_COMPLETE。

### 1.2 测试

- MMU 单元 TB 新增：2 MB 块（VA 0x40201000 -> PA 0x44001000）、1 GB 块
  （VA 0x8004001000 -> PA 0x44001000）、块内另一 4K 页（TLB 按页记录）。
- 新增 `hard_block_desc` 定向锁步：2 MB 块与 1 GB 块各自读/写同一标记
  PA，验证翻译与写通路径；基础、全缓存（I+D+L2）、全缓存+随机延迟
  （delay2）配置下均与 QEMU 一致。

## 2. 验证结果（本机实跑）

- `make test`（含更新后的 MMU TB）全绿。
- `run_m2_4b.sh`：10/10（base 5 + l1dl2 全缓存 5）。
- hardening 14/14、p4c/p5a/p4b 全部锁步一致。
- `run_gate_d.sh`：39 项子检查全部 PASS（delay2 集合含 hard_block_desc）。

## 3. 设计取舍与已知限制

- TLB 仍按 4 KiB 页记录块内访问的页（块内其他页 miss 时重新遍历），
  正确性优先，性能优化（块级 TLB 项）留待后续。
- 块描述符的 AttrIndx/AP/UXN/PXN/AF 语义与页描述符一致；保留位未单独
  校验（QEMU 亦不校验通用保留位）。
- L0 块（LPA2/DS）不支持，与当前 48 位 4K 模型一致。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- R1 剩余：ESR_EL1/FAR_EL1 完整 syndrome、SCTLR/TCR/TTBR 写后失效、
  空流水线取指 fault 合成提交、交叉工具链/ELF/裸机 C。
