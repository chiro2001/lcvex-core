# LCVEX 交接文档 018：M2-5 Gate D 系统回归完成

日期：2026-08-23（Asia/Shanghai）
前置：handoff 017（M2-4c 旁路完成）、PROJECT_STATUS M2。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（M2-5 Gate D 系统回归）

Gate D 退出条件（PROJECT_STATUS）全部关闭：hit/miss/refill/evict、冲突
替换、写穿副作用、I/D 失效、Device bypass、TLB hit/miss/fault 与
maintenance 均有单元与系统测试；可注入下级延迟（含全缓存配置）；
P0～P5a 全量回归通过；缓存内部事件有 SVA 与覆盖率验证。

### 1.1 本阶段新增

1. **全缓存 + 随机下级延迟锁步构建**（`lockstep-build-l1dl2-delay2`，
   `-GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1 -GMEM_DELAY_MODE=2`）：
   I+D+L2 全缓存下注入 0..4 周期随机（LFSR）下游延迟，验证 Cache 握手
   无丢失/重复。定向 4 组（barrier/selfmod/tlbi/mair_bypass）与随机
   3000 条均与 QEMU 锁步一致。
2. **缓存 SVA**：L1D/L1I/L2 各增加
   - 响应期间不接受新请求（单 outstanding）；
   - 下游响应被消费时必然处于等待响应状态（填行/写通/旁路）；
   L1I 另加维护请求接受后下一拍直接响应、IC IVAU 接受后目标行失效。
3. **I-L1 维护失效单元用例**（lcvex_l1_i_tb）：RAM 更新后 IC IVAU 失效
   单行 -> 读必须 miss 重新填行得新值；IC IALLU 整表失效同理。
4. **MMU 单元 TB**（lcvex_mmu_tb）：TLB miss 4 级遍历、TLB hit、
   无效描述符 fault、AP=10 页面 EL1 读允许/写 fault、Normal NC
   （attr1=0x44）cacheable=0、取指翻译一致、tlb_invalidate 后重新遍历
   得新 PA。
5. **覆盖率**（`make coverage`）：L1D/L1I/L2/MMU/mem_if 五个 SV TB 以
   Verilator `--coverage` 构建运行，`verilator_coverage` 合并到
   `build/coverage/merged.dat` 并打印排名（实测 7199 点）。
6. **Gate D 验收脚本**（`sim/difftest/run_gate_d.sh`，`make gate-d`）：
   make test + coverage + M2-4b/4c + delay2-cache 定向/随机 + hardening
   13 组 + p4c/p5a/p4b + 随机 100k，全部绿。

### 1.2 顺带修正

- `hard_mair_bypass` 的 MAIR 立即数构造字节序反了（attr0/attr1/attr2
  映射错误）：改为 `movz x5,#0x4400; movk x5,#0xff,lsl16` 得到
  attr0=Device(0x00)/attr1=NC(0x44)/attr2=WB(0xFF)。QEMU 不建模缓存，
  原测试仍锁步通过，但覆盖意图（Device/NC/WB 各占一个属性槽）错误；
  已修正并回归。

## 2. 验证结果（本机实跑）

- `make test`（含新增 MMU TB、L1I 失效用例与缓存 SVA）全绿。
- `make coverage`：5 TB 合并 7199 覆盖点。
- `bash sim/difftest/run_gate_d.sh`：14 项步骤、35 项子检查全部 PASS。

## 3. 已知限制与后续

- 覆盖率目前只覆盖 SV 单元 TB 的 RTL；锁步协调器（C++ 驱动）尚未接入
  `--coverage`（需在协调器 main 调用 coverage 写出），留待后续。
- QEMU 只作架构状态参考；Cache 内部事件由单元 TB、SVA 与覆盖率把关。
- 下一步：P6/Linux 前 R1——ESR_EL1/FAR_EL1 完整 syndrome、块描述符、
  SCTLR/TCR/TTBR 写后失效、交叉工具链/ELF/裸机 C、空流水线取指 fault
  合成提交（handoff 016 记录的限制）。

## 4. 仓库状态

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- Gate D 关闭后，`main` 只接受通过 CI 的稳定提交；当前功能分支已推送，
  CI 仍留待核心功能完善后依赖（用户偏好本地测试优先）。
