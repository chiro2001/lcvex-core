# LCVEX 交接文档 015：M2-4a 屏障完成 + M2-4b 维护指令起点

日期：2026-08-23（Asia/Shanghai）
前置：handoff 014（统一 L2）、PROJECT_STATUS M2。
分支：`feature/commit-memory-handshake`，HEAD = `d6fef1e`（M2-4a）。

## 1. 本阶段完成（M2-4a：ISB/DMB/DSB，`d6fef1e`）

- `lcvex_pkg`：`sys_op_t` 增加 `SYS_BARRIER`。
- `lcvex_decode`：识别 DSB(op2=100)/DMB(101)/ISB(110)/SB(111)，
  `insn[31:12]==11010101000000110011`、`rt==11111`（QEMU a64.decode
  权威模式）。
- `lcvex_core`：`sys_at_id` 包含 `SYS_BARRIER`；屏障在 ID 级等前方
  流水线（含未完成访存）排空后提交，`next_pc=pc+4` 并把取指重定向
  重新取（即“等待 + ISB 冲刷”语义，不是无条件 NOP）。
- 定向测试扩为 11 组：
  - `hard_barrier`：DMB/DSB/ISB 混合指令锁步一致。
  - `hard_selfmod`：store 覆盖 0x44000038 + DMB/ISB 后重取，
    x9=0x1234 与 QEMU 一致（无冲刷时预取拿到旧 NOP）。
- 回归全绿：p4c 7、p5a 3、q6、hardening 11、P2 lockstep 36、make test。

## 2. 下一步（M2-4b：IC/DC/TLBI 最小子集）

### 动机（已实测）

全缓存（I+D+L2）配置下 `hard_selfmod` 失败：store 走 D-L1->L2->SRAM
（写通已更新 L2 行），但 I-L1 仍持有旧 NOP 行，ISB 重取命中陈旧行。
需要 **IC IVAU**（失效 I-L1 对应行）。TLBI 同理：TTBR/TCR 或页表
修改后必须能整表失效 TLB。

### QEMU 权威编码（helper.c + 探针实测，全部被 QEMU 接受）

`sysw(op0,op1,crn,crm,op2,rt)` = `0xD5000000 | (op0<<19) | (op1<<16)
| (crn<<12) | (crm<<8) | (op2<<5) | rt`：

| 指令 | 编码 | rt |
| --- | --- | --- |
| IC IALLUIS | (1,0,7,1,0) | 31 |
| IC IALLU | (1,0,7,5,0) | 31 |
| **IC IVAU** | (1,3,7,5,1) | Xt（PL0 可执行） |
| DC IVAC | (1,0,7,6,1) | Xt（PL1） |
| DC ISW | (1,0,7,6,2) | Xt |
| DC CVAC | (1,3,7,10,1) | Xt |
| DC CVAU | (1,3,7,11,1) | Xt |
| DC CIVAC | (1,3,7,14,1) | Xt |
| TLBI VMALLE1IS | (1,0,8,3,0) | 31 |
| TLBI VMALLE1 | (1,0,8,7,0) | 31 |
| TLBI VAE1IS | (1,0,8,1,0) | Xt |

探针脚本：`build/difftest/probe_maint3.bin`（8 个候选全部正常执行、
无 UDEF，含 TLBI 后跟 DSB/ISB 与自循环）。

### 建议实现顺序

1. `mem_req_t` 增加 `maint` 字段（opcode：NONE/IC_IVAU/DC_IVAC/...，
   命名构造缺省为 0，不影响既有模块）。
2. 核心：解码维护 SYS 指令；IC/DC 的 VA 先经 MMU 数据翻译成 PA，
   再向对应路径（IC->imem、DC->dmem）发 `maint` 请求，等响应后提交；
   TLBI 发 `tlb_invalidate` 脉冲给 MMU（整表失效）。
3. I-L1/D-L1：上游收到 `maint` 请求时按 PA index/tag 失效对应行并
   直接响应（不下发下游；L2 为写通、行与 SRAM 一致，无需动作）。
   L2 同样处理（若日后有脏行策略）。
4. DC 各 op 对写通层次是功能 no-op，但必须识别并提交（不能 UDEF）。
5. MMU 增加 `tlb_invalidate` 输入，清空 `tlb_valid`。
6. 验证：`hard_selfmod` 在全缓存配置下转绿；新增 TLBI 定向测试
   （改 TTBR 后不失效会读旧页表，失效后重新遍历）；DC 测试与 QEMU
   锁步。

### 注意事项

- IC IVAU 的 VA 翻译失败应报异常（与数据访问一致）。
- 维护指令也走 `sys_at_id` 路径（ID 级排空后提交），保证先于后续
  访存/取指生效。
- `hard_selfmod` 目前只在无缓存配置下通过；全缓存转绿 = M2-4b
  完成判据之一。

## 3. 仓库状态

- `feature/commit-memory-handshake` 已推送至 `chiro2001/lcvex`（私有）。
- 测试以本地为准；CI（GitHub Actions 三 job）已就绪，核心功能完善后
  再依赖。
- 工作区干净（本交接前已提交 M2-4a）。
