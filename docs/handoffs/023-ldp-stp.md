# LCVEX 交接文档 023：M3 - LDP/STP 成对访存完成

日期：2026-08-24（Asia/Shanghai）
前置：handoff 022（编译器指令第一批 + 裸机 C）、PROJECT_STATUS M3。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（LDP/STP 全寻址模式）

编译器栈帧与结构体拷贝核心的成对访存落地：LDP/STP（GPR 对）支持
signed-offset（含 non-temporal 别名）、pre-index、post-index，X 对与
W 对。这是编译后裸机 C（含 `stp x29,x30,[sp,#-48]!`、`ldp x0,x1,[sp,#32]`）
在 RTL 上运行的必要条件。

### 1.1 RTL 改动

- `lcvex_pkg`：decoded_insn_t/ex_pipe_t 增加 `is_pair`、`mem_wdata2`、
  `wb2_*`（LDP 第二目标）、`wb3_*`（pre/post 基址更新）；commit_packet_t
  增加 `gpr2/gpr3` 与 `mem2` 字段（双/三 GPR 写回，成对存储保留）。
- `lcvex_decode`：LDP/STP 分支（insn[30:27]==0101、V=0、
  mode∈{000,001,010,011}、sz∈{2,3}）：
  - 寻址：offset/pre = base+imm，post = base；pre/post 更新基址（rn 经
    wb3，SP 经 sp_we）；
  - STP 提交按 QEMU 插件语义报**单条**成对存储：X 对 data=rt（u128.low），
    W 对 data={rt2,rt}（64 位组合），strb=0xFF；实际 dmem 仍两段写。
- `lcvex_core`：
  - 成对访存双请求 FSM（pair_part：第一段 addr，第二段 addr+8/4）；
  - 流水线携带 wb2/wb3；WB/COMMIT 应用三写回；load-use 覆盖 LDP 双目标；
  - gprv 前递扩展 wb2/wb3（pre/post 基址在 EX/MEM 即可前递）；
  - **修复潜在 bug**：WB 级 dmem 响应 fault（`wb_exc_commit`）此前不冲刷
    流水线也不重定向取指（该路径从未被锁步触达）——现在冲刷 ID/EX/
    EX/MEM/WB 并重定向 if_pc 到异常向量。

### 1.2 经验证修正的语义细节

- QEMU 对 X 对 STP 发单条 128 位存储（插件报 size=16、data=u128.low=rt），
  W 对发 64 位存储（data=rt|rt2<<32）；DUT 提交包按此表示单条存储；
- mmu 关闭时访问超 48 位地址（非 canonical，如 0xFFFF...E0）QEMU 报
  address-size fault（FSC=0），而 48 位内未映射地址报外部中止（0x10）——
  修 decode 级 DABT/IABT 的 FSC 选择。

### 1.3 测试

- `hard_pair_ldst`：X/W 对、offset/pre/post、基址更新、双写回、
  成对存储提交，与 QEMU 锁步；异常路径（越界基址 DABT + handler）一致。
- 裸机 C 扩展：pair_t 结构体 `pair_set/pair_sum`（noinline）生成
  `stp x29,x30,[sp,#-48]!` 与 `ldp x0,x1,[sp,#32]`，200 条锁步一致。

## 2. 验证结果（本机实跑）

- `make test` 全绿；hardening 19/19；M2/R1 20/20；
- `run_gate_d.sh`：59 项子检查全部 PASS。

## 3. 已知限制

- LDPSW（符号扩展 32 位对）未实现；FPR/SIMD 对（LDP/STP_v）不支持
  （P7 前不需要）；
- rt/rt2/rn 相同寄存器的写回冲突未建模（架构上 UNPREDICTABLE，常见
  编译器输出不产生）。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- M3 剩余：MADD/MSUB/UMULL、CSEL 族、BFM、LDR literal、寄存器偏移寻址、
  exclusive；随后 Linux head.S 缺口清单。
