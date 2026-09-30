# LCVEX 交接文档 022：M3 - 编译器常用指令 + 裸机 C 里程碑

日期：2026-08-23（Asia/Shanghai）
前置：handoff 021（ESR/FAR 完成）、PROJECT_STATUS M3。
分支：`feature/commit-memory-handshake`。

## 1. 本阶段完成（编译器指令缺口第一批 + 裸机 C 跑通）

用真实交叉编译器（aarch64-linux-gnu-gcc 16.1）输出建立 ISA 缺口清单，
优先补齐编译器最常用的两类指令，并让**编译后的裸机 C 程序在 RTL 上
与 QEMU 锁步运行**（M3 第 1 步完成）。

### 1.1 ISA 缺口清单（最小 C 程序实测）

已支持：addsub 立即数/移位寄存器、and/orr/eor 移位寄存器、cmp/cmn、
b.cond/b/bl/ret、movz/movk/movn、adrp/adr、unsigned-immediate ldr/str、
sub sp（栈操作）、nop。

第一批缺口（本阶段补齐）：
- **逻辑立即数（位掩码）**：AND/ORR/EOR/ANDS #imm；ORR Rn=XZR 即
  `mov w, #任意 32 位常量`（编译器对 0xf0f0f0f0 等常量必用）；
- **位域**：SBFM/UBFM（LSR/LSL/ASR 立即数、SXTB/SXTH/UBFX 等）。

后续缺口（已记录，未实现）：LDP/STP、MADD/MSUB、CSEL 族、BFM
（位域插入）、EXTR、exclusive、LDR literal、扩展寄存器加/减。

### 1.2 RTL 改动

- `lcvex_pkg`：ALU 增加 `ALU_SBFM/ALU_UBFM`。
- `lcvex_decode`：
  - `logic_imm_valid`（QEMU logic_imm_decode_wmask 语义）：由
    N:immr:imms 解出 64 位掩码，保留编码返回无效；32 位形式 immr/imms
    为 6 位全宽字段（bit21/bit15 参与编码），仅 immn(bit22)=0；
  - 逻辑立即数分支（insn[28:23]==100100）：AND/ORR/EOR/ANDS；
  - 位域分支（insn[28:23]==100110）：SBFM(00)/UBFM(10)；BFM(01)
    暂按 UDEF 记录。
- `lcvex_alu`：`bitfield_op`（QEMU disas_bitfield 语义）——si>=ri 提取
  （UBFM 零扩展/SBFM 符号扩展），si<ri 左移（SBFM 在 len<ri 时先符号
  扩展再截断）；32 位形式经 r32 路径零扩展。

### 1.3 裸机 C 基础设施

- `baremetal/`：startup.s（设 SP 进 main）、main.c（无 libc，覆盖
  位掩码立即数/位域/移位寄存器逻辑/栈访问）、link.ld（0x44000000）；
- `scripts/build-baremetal.sh`：交叉编译 + objcopy 生成
  `build/difftest/bm_c.bin`（工具链缺失时退出码 2）；
- 新增 `hard_compiler_isa` 定向测试（as/objdump 校验的 9 条新指令编码）；
  `run_gate_d.sh` 增加 baremetal-C 锁步（工具链缺失跳过）。

## 2. 验证结果（本机实跑）

- `hard_compiler_isa` 基础/全缓存锁步与 QEMU 一致；
- 编译后的 `bm_c.bin`（664 字节，含 startup+main+compute）在 RTL 上
  与 QEMU 锁步 200 条一致（delay 循环 + 计算 + 自旋）；
- `make test` 全绿；hardening 18/18；M2/R1 18/18；
- `run_gate_d.sh`：55 项子检查全部 PASS。

## 3. 设计取舍与已知限制

- BFM（bitfield insert）暂未实现：C 位域赋值会用到，后续补；
- LDR literal 未实现：启动代码避免字面量池（用 movz 设 SP）；后续补；
- 工具链为系统 aarch64-linux-gnu-gcc（Linux 目标），freestanding 标志
  下产物与裸机一致；CI 环境缺工具链时 baremetal 步骤自动跳过。

## 4. 仓库状态与下一步

- `feature/commit-memory-handshake`，HEAD 为本阶段提交（见 git log）。
- M3 下一步：按缺口清单补 LDP/STP、MADD/MSUB、CSEL、BFM、LDR literal，
  扩展裸机 C 测试（结构体/位域/函数指针），然后用 Linux head.S 建立
  更大 ISA 缺口清单。
