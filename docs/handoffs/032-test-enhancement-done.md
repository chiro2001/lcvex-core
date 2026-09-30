# LCVEX 交接文档 032：测试增强计划完成与 pair-store 缺口修复

日期：2026-08-24（Asia/Shanghai）
前置：handoff 031（测试增强计划状态）、TEST_ENHANCEMENT_PLAN.md。
分支：`feature/m3-isa`（HEAD=`3e4fe23`，工作区干净，待 Gate D 全绿后合 main）。

## 1. 项目状态快照

- **阶段**：M3（Linux 前 ISA 收敛）进行中，**仅剩 exclusive**；
  P0-P5/Gate A-D 完成，P6 未开始。
- **分支**：`feature/m3-isa`，main 停在 `c70928a`（待本轮阶段门合并）。
- 本轮提交（均在 feature/m3-isa）：
  - `fd65d6d` verify: M3 random difftest families + encoder self-check
  - `05b30c3` infra: instruction coverage accounting from QEMU trace
  - `7d8d458` infra: lockstep --only filter + planner-bound parallel runner
  - `0d5f207` infra: gate-D --only/multi-seed L3 + coverage step + verilator -j
  - `44be98d` docs: test enhancement plan completion status
  - `3e4fe23` fix: pair-store commit fidelity（随机回归暴露的缺口）

## 2. 测试增强计划完成情况（全部落地）

1. **`--only` 筛选**：`run_gate_d.sh` / `run_m2_4b.sh` /
   `run_p5a_hardening.sh` 支持 `--only name1,name2`（gate_d 透传子脚本）；
2. **随机生成器扩展（difftest 三缺口之一）**：
   - a64.py 新增编码器：CSEL/CSINC/CSINV/CSNEG（X/W）、
     SBFM/UBFM/BFM/BFI/BFXIL、MADD/MSUB/SMADDL/SMSUBL/UMADDL/UMSUBL、
     LDP/STP（offset/pre/post，X/W）、寄存器偏移 LDR/STR（含
     LDRSW/LDRSB/LDRSH W/X）、扩展 ADD/SUB、BIC/BICS/ORN/EON；
   - `sim/difftest/check_encoders.py`：35 条与 GNU 汇编器逐字对照 +
     360 条随机模糊对照全过，已并入 `make test`；
   - random_program.py 纳入全部新族 + LDR literal/PRFM/NOP；约束防
     异常：pair pre/post 用专用基址 x21/x22（每步 movz 重置防漂移）、
     寄存器偏移索引 x23 受限且非 byte 固定 S=1、UBFM X 的 imms≤30
     （保留编码）；
   - L3 改为 seed 1~3 × 100k（`make difftest-random-multi`）。
3. **多 seed**：seed 1~3 × 100k 纳入 Gate D（此前仅 seed 1）。
4. **指令覆盖记账（difftest 三缺口之一）**：`scripts/insn_coverage.py`
   从 QEMU trace 提取归一化助记符，与 ISA_SCOPE 支持矩阵比对；
   mov/movn/movz/movk 按 opc 解码，bfi/bfxil/sbfx/ubfx/cneg/cinc/cinv
   别名折叠；归档 `build/coverage/insn_map.txt`；缺失 FAIL
   （`--warn-only` 降级）。seed 1~3 trace 汇总 54/54 族命中。
5. **并行化**：Verilator 构建 `-j $(VERILATOR_JOBS)`（默认 6）；
   `scripts/run_lockstep_parallel.sh`（planner 并行度 + 物理核 taskset +
   per-test socket/日志 + `--wait` 排队）；`run_p5a_hardening.sh --parallel`
   与 `make test-parallel` 接入；`run_lockstep_step.sh` 路径可覆盖。
   **Gate D 主流程 `--parallel` 已实现**（`2b021a7`）：M2-4b、delay2
   （17 项含 random smoke）、P5a-Hardening 三个批次改用并行 runner，
   Gate C/P5a/P4b 保持串行；默认仍为串行（先拿可复现基线），需要时
   `bash sim/difftest/run_gate_d.sh --parallel`。

## 3. 随机回归暴露的真缺口：pair-store 提交包表示有损

首次多 seed 随机（seed 1 × 100k）在 `stp x2, x3, [x21], #272`
（**STP post-index**，定向测试未覆盖）上 RED：

- RTL 提交包只报单条 8 字节存储（`mem`，仅 rt 值），`mem2` 从未置位；
- QEMU 插件对 16 字节 store 只记 `u128.low`（rt2 数据丢失），锁步协议
  又把 strb 截断成 8 位，两条路径**恰好互相掩盖**（协调器比对通过但
   rt2 的存储从未被校验）；
- cocotb harness 只读 `gpr/gpr3/sp/nzcv/mem`，忽略 `gpr2/gpr3/mem2`。

修复（`3e4fe23`）：

1. 插件：16B store 拆成两个 8B 记录（low@addr、high@addr+8）；
2. RTL：传播 `memwb_mem_wdata2`，STP X 对在正常提交路径发 `mem2`
   （rt2@addr+8，strb=0xFF）；W 对保持单笔 8B（`mem_wdata={rt2,rt}`）；
3. cocotb：读并应用 `gpr2/gpr3/mem2`，内存副作用按 mem+mem2 比较；
4. `docs/COMMIT_PACKET.md` 补成对指令提交语义说明。

验证：seed 1 × 100k cocotb 差分 **PASS**（12s，此前 insn[21] 失败）；
锁步 `hard_pair_ldst` 在新严格双存储比对下仍绿。

## 4. Gate D 重跑状态

- 第一轮（含多 seed + 覆盖记账）：**RED 仅 1 项失败** = 随机 seed 1
  （pair-store 缺口，已修复）；其余全部绿：make test、coverage
  （7337 覆盖率点）、M2-4b 34/34、delay2 16、hardening 26、Gate C 7、
  P5a 3、P4b 5、baremetal-C 200 条。
- 修复后第二轮 Gate D：make test 通过后在 `step "make coverage"` 处
  崩溃（**教训：后台脚本运行中不得修改脚本文件**——运行期间改动
  run_gate_d.sh 导致 bash 增量解析读到新旧混合内容）。
- **第三轮 Gate D：全绿 ✅**（日志 `build/logs/gate_d_full3_*.log`）：
  make test（含 check-encoders）、coverage（7337 覆盖率点）、M2-4b
  34/34、delay2 16+smoke、hardening 26/26、Gate C 7/7、P5a 3/3、
  P4b 5/5、**随机 seed 1~3 × 100k 全部 PASS（300,006 条）**、
  **覆盖记账 52/52 族命中**、baremetal-C 200 条。
  已按阶段门快进合入 main（`git merge --ff-only`）。

## 5. 关键命令

```bash
make test-plan                     # 资源决策 JSON
make microbench                    # L0（无 QEMU）
make check-encoders                # a64 编码器对照
make test-parallel                 # P5a-Hardening 26 项并行
make difftest-random-multi         # seed 1~3 × 100k 差分
python3 scripts/insn_coverage.py --expect random \
  build/difftest/random_1.trace build/difftest/random_2.trace \
  build/difftest/random_3.trace    # 覆盖记账
bash sim/difftest/run_gate_d.sh --only hard_csel   # 单测筛选
SPECS="..." bash scripts/run_lockstep_parallel.sh --wait
```

## 6. 已知限制与下一步

- 随机生成器约束保护"不产生异常"（地址受限、对齐保持），异常/MMU 随机
  覆盖仍由定向 + P5a 系列承担（L4 nightly 可扩展）；
- 锁步主流程仍串行（并行 runner 已就绪，未切换默认），后续可用
  `--parallel` 提速 Gate D；
- 下一步（M3 收尾）：exclusive 指令（LDXR/STXR 等，P6 Linux 所需）→
  Linux head.S 缺口清单 → P6。
