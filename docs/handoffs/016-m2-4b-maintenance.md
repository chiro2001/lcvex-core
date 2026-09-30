# LCVEX 交接文档 016：M2-4b 缓存/TLB 维护指令完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 015（M2-4a 屏障完成，M2-4b 起点）、PROJECT_STATUS M2。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（M2-4b：IC/DC/TLBI 最小子集）

M2-4b 完成判据达成：**全缓存（I+D+L2）配置下 `hard_selfmod` 与 QEMU 锁步
转绿**（store 经 D-L1->L2->SRAM 更新，IC IVAU 失效 I-L1 陈旧行后重取得到
新指令）。同时新增 TLBI 定向测试，验证改页表描述符后整表失效并重新遍历。

### 1.1 RTL 改动

- `lcvex_pkg`：`maint_op_t` 枚举（`MAINT_IC_IVAU/IC_IALLU/DC_IVAC/DC_ISW/
  DC_CVAC/DC_CVAU/DC_CIVAC/TLBI`）；`mem_req_t` 增加 `maint` 字段（命名
  构造缺省为 NONE，既有模块无感知）；`sys_op_t` 增加 `SYS_MAINT`；
  `decoded_insn_t` 增加 `maint_op/maint_va`。
- `lcvex_decode`：SYS 空间（op0=01）识别维护指令；EL0 权限按 QEMU
  accessfn 语义：IC IALLU*、DC IVAC/ISW、TLBI 为 PL1-only，IC IVAU 与
  DC CVAU/CVAC/CIVAC 在 EL0 需 SCTLR_EL1.UCI=1，否则 UDEF。
- `lcvex_core`：
  - 维护指令并入 `sys_at_id`（ID 级等前方排空后提交，next_pc=pc+4 并
    重取，语义与屏障一致）；
  - IC IVAU：维护 VA 走数据侧 MMU 翻译（`MS_TRANSLATE`），成功按 PA 向
    I-L1 发 `MAINT_IC_IVAU` 请求，失败跳过失效并正常提交（与 QEMU system
    模式 NOP 语义一致，不产生异常）；
  - IC IALLU/IALLUIS：向 I-L1 发 `MAINT_IC_IALLU` 整表失效；
  - DC 各 op：写通层次为功能无操作（缓存与内存始终一致），仅识别并提交；
  - TLBI（VMALLE1IS/VMALLE1/VAE1IS）：向 MMU 发 1 周期 `tlb_invalidate`
    脉冲（VAE1IS 的 Xt 忽略，整表失效是架构允许的超集）；
  - `sys_fetch_redirect` 扩展到 SYS_BARRIER/SYS_MAINT：维护/屏障提交前
    预翻译 next_pc，翻译失败合并为 IABT（修复屏障+MMU 的潜在死锁）；
  - imem 端口维护期间 mux 到维护请求，取指 FSM 只认普通取指 accept。
- `lcvex_l1_i`：上游收到 `maint` 请求时按 PA 组索引失效单行或清空全部
  有效位，直接响应、不下发下游（L2 写通，行与 SRAM 一致）。
- `lcvex_mmu`：新增 `tlb_invalidate` 输入，整表失效并中止在途遍历。

### 1.2 QEMU 权威编码（helper.c v8_cp_reginfo，探针实测全部接受）

`sysw(op0,op1,crn,crm,op2,rt)=0xD5000000|(op0<<19)|(op1<<16)|(crn<<12)|
(crm<<8)|(op2<<5)|rt`：

| 指令 | 编码 | rt | EL0 |
| --- | --- | --- | --- |
| IC IALLUIS / IALLU | (1,0,7,1,0)/(1,0,7,5,0) | 31 | 无 |
| **IC IVAU** | (1,3,7,5,1) | Xt | 需 UCI=1 |
| DC IVAC / ISW | (1,0,7,6,1)/(1,0,7,6,2) | Xt | 无 |
| DC CVAC / CVAU / CIVAC | (1,3,7,10,1)/(1,3,7,11,1)/(1,3,7,14,1) | Xt | 需 UCI=1 |
| TLBI VMALLE1IS / VMALLE1 | (1,0,8,3,0)/(1,0,8,7,0) | 31 | 无 |
| TLBI VAE1IS | (1,0,8,1,0) | Xt | 无 |

## 2. 本阶段修复的两个 RTL bug

1. **解码器**：`unique case ({1'b0, crn, crm, op2})` 在 Verilator 5.050 下
   不匹配（0xd50b7520 被误判为 UDEF，基础与缓存构建均复现）。改为显式
   if-else 编码匹配后正确。
2. **P5a 遗留（MMU 请求 mux）**：`mmu_req_va/is_insn/is_write` 原先以
   `d.is_load || d.is_store` 判断请求类型。数据翻译完成后 load/store 仍
   停留 ID，此时先发出的取指翻译会被误标为数据翻译（VA 取 `d.mem_addr`），
   导致取指按数据页地址翻译（`hard_tlbi` 中取指 0x44000034 实际翻译到
   PA 0x44008000 拿到数据 A 低字）。改为以 `data_req_valid` 为准，并区分
   `maint_va_pending`（IC IVAU 维护 VA 也用数据侧翻译）。该修复对全部
   MMU 测试无回归（见下）。

## 3. 验证结果（本机实跑）

- `make test`：lint + SV（core/backpressure/memif/L1D/L1I/L2）+
  Cocotb（ALU/regfile/backpressure）全绿。
- `bash sim/difftest/run_p5a_hardening.sh`：12/12（含新增 hard_tlbi）。
- `bash sim/difftest/run_m2_4b.sh`：6/6（base 3 + l1dl2 全缓存 3）。
- p4c 7 组、p5a 3 组、p4b 全部与 QEMU 锁步一致。
- 随机回归：seed 1/2/3 × 100k 全过；随机 3000 条在全缓存锁步构建下
  与 QEMU 一致。

## 4. 设计取舍与已知限制

- **DC op 不翻译、不发缓存请求**：QEMU system 模式对 IC/DC 维护均为 NOP
  （无地址翻译、无异常），写通层次下 DC 无操作即精确匹配；若日后改写回
  缓存需为 DC 增加失效/回写路径。
- **IC IVAU 翻译失败不报异常**：与 QEMU system 模式一致（QEMU 的 IC IVAU
  是 NOP）。ARM 规范允许翻译故障，但锁步参考模型为准。
- **TLBI VAE1IS 按整表失效处理**：架构允许超集失效。
- **已知限制**：`msr sctlr` 使能 MMU 后紧接的取指若翻译失败，会因流水线
  已空而无法合并 IABT（预翻译只覆盖 sys_at_id 期间的指令）。现有测试均
  在使能 MMU 后继续执行已映射代码，未触发；后续 R1 需为“空流水线取指
  fault”补合成提交路径。

## 5. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）；
  测试以本地为准，CI 仍留待核心功能完善后依赖。
- 下一步：M2-4c（MAIR Device/不可缓存旁路，请求属性或 PA 区域判定）→
  M2-5 Gate D 系统回归（hit/miss/refill/evict、I/D 失效、Device bypass、
  随机下级延迟、覆盖率）→ P6/Linux 前 R1（TLBI 一致性、ESR_EL1/FAR_EL1
  完整 syndrome、块描述符、交叉工具链/ELF/裸机 C）。
