# LCVEX 交接文档 017：M2-4c MAIR Device/不可缓存旁路完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 016（M2-4b 维护指令完成）、PROJECT_STATUS M2。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（M2-4c：Device/不可缓存旁路）

按 MAIR_EL1 属性把 Device（memtype 0..3）与 Normal Non-cacheable
（memtype 0b0100）区域直通 L1/L2（不命中、不分配、不更新行），Normal
可缓存区域走原有缓存路径。这是 Linux 前 Device memory 语义的基础。

### 1.1 RTL 改动

- `lcvex_pkg`：`mem_req_t` 增加 `bypass` 字段（1=旁路 L1/L2；缺省 0=正常
  缓存路径，既有构造无感知）。
- `lcvex_mmu`：
  - 按页描述符 AttrIndx[4:2] 索引 MAIR_EL1 的 8 位属性项，memtype
    0..3（Device）与 0b0100（Normal NC）输出 `cacheable=0`，其余 Normal
    （WT/WB 等）为 1；
  - TLB 增加 `tlb_cacheable` 数组（命中直出、L3 填表时一并记录）；
  - `mmu_en=0` 直通路径 `cacheable=1`（SRAM 视为 Normal 可缓存）。
- `lcvex_core`：
  - 数据翻译完成锁存 `trans_cacheable_r`，随 `ex_pipe_t.mem_cacheable`
    流经 ID/EX->EX/MEM，`dmem_req.bypass = !exmem_mem_cacheable`；
  - 取指翻译完成锁存 `fetch_cacheable_r`，
    `fetch_imem_req.bypass = !fetch_cacheable_r`；
  - 维护请求 bypass 恒 0；PTW 请求 bypass 恒 0。
- `lcvex_l1_d / lcvex_l1_i / lcvex_l2`：新增 `S_BYPASS/S_BYPASS_WAIT`，
  `u_req.bypass=1` 时把原请求直通下游（读写均不分配/不更新行），响应
  rdata/fault 原样传回上游。

### 1.2 验证

- 单元 TB（sim-sv-l1d/l1i/l2）新增 bypass 用例：bypass 写不更新已缓存行
  （随后普通读仍命中旧值）、bypass 读直通 RAM、bypass 读不分配/不驱逐。
- 新增 `hard_mair_bypass` 定向锁步程序：三个 4 KiB 页分别用
  attr0=Device（0x00）、attr1=Normal NC（0x44）、attr2=Normal WB（0xFF），
  各映射不同 PA，做 64 位读写后回读；基础与全缓存（I+D+L2）配置下均与
  QEMU 一致。

## 2. 验证结果（本机实跑）

- `make test`：lint + SV（core/backpressure/memif/L1D/L1I/L2，含 bypass
  用例）+ Cocotb 全绿。
- `bash sim/difftest/run_m2_4b.sh`：8/8（base 4 + l1dl2 全缓存 4，
  含 hard_mair_bypass）。
- hardening 13/13、p4c 7、p5a 3、p4b 全部与 QEMU 锁步一致。
- 随机回归：seed 1/2 x 100k 全过。

## 3. 设计取舍与已知限制

- **QEMU 不建模缓存行为**：锁步只能验证旁路路径端到端正确（响应直通），
  "不分配行/不驱逐"由 L1D/L1I/L2 单元 TB 断言。
- Device 区域的指令取指也走旁路（读直通），与 QEMU 一致（QEMU 允许从
  Device 取指）；架构上通常禁止，后续 Linux 平台阶段再收紧。
- 旁路不影响写通一致性：即使不旁路，写通也保证缓存与内存一致；旁路的
  意义在于策略正确性（Device 行不应驻留缓存）与后续写回缓存的准备。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）；
  测试以本地为准，CI 留待核心功能完善后依赖。
- 下一步：M2-5 Gate D 系统回归（hit/miss/refill/evict、I/D 失效、
  Device bypass、随机下级延迟、覆盖率）-> P6/Linux 前 R1（TLBI 一致性、
  ESR_EL1/FAR_EL1 完整 syndrome、块描述符、交叉工具链/ELF/裸机 C）。
