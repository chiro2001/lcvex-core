# T-20260829-085 B2c 向量访存/编码族闭合 handoff

- 状态：review
- 任务 ID：T-20260829-085（B2c）
- base SHA：`708b3c38065f02efd9c461a97ae7528912d090c7`
- head SHA：见 `docs/tasks/evidence/T-20260829-085.json`
- 分支：`feature/T-20260829-085-b2c-vector-memory`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-085`
- sent_at：2026-08-29T05:16:00+0800
- received_at：2026-08-29T05:52:00+0800
- reported_at：2026-08-29T05:52:00+0800

## 结论摘要

本批先闭合 V82-SELECTED-EXT 中的 **replicate / lane-by-element** 编码族：

- `DUP Vd.<T>, Wn/Xn`（scalar replicate）
- `DUP Vd.<T>, Vn.<T>[index]`（lane element replicate）
- `LD1R {Vt.<T>}, [Xn]`（单寄存器 load-replicate，Q=0/Q=1，B/H/S/D）

实现基于现有 P7-2 NEON 整数单元与单 Q 访存握手，没有引入 SVE/SME、完整
FP exception trap、MOPS/MTE/PAuth/Crypto。结构化/多寄存器访存（LD2R/LD3R/LD4R、
LD1/ST1 multi-register、ST1R/STnR 等）按当前 commit packet 仅有两个 store
slot 的 ABI 明确保持 deferred，不在本批伪装支持。

## 实现与数据路径

- `rtl/lcvex_pkg.sv`
  - `neon_op_t` 增加 `NEON_OP_DUP_SCALAR`、`NEON_OP_DUP_ELEMENT`。
  - `decoded_insn_t/ex_pipe_t` 增加 `neon_quad`、`neon_mem_replicate`，
    用于 DUP 的 64/128 位结果和 LD1R 的复制加载标记。
- `rtl/lcvex_decode.sv`
  - 新增 DUP scalar/element 解码，`imm5` 按 B/H/S/D 推导 size/index，
    拒绝保留的 Q=0 D 形式。
  - 新增 LD1R 解码（`0x0D40C000`/`0x4D40C000` 族，size 取自 `[11:10]`），
    拒绝不存在的 Q=0 D 形式；设置单次 load、元素宽度 strb、`neon_mem_replicate`。
  - 现有 FPEN trap、内存窗口/U DEF 后处理保持生效。
- `rtl/lcvex_neon_int.sv`
  - 增加 `quad` 端口；DUP 将 scalar 或选定 source lane 复制到全部活动 lane，
    Q=0 只写低 64 位。
- `rtl/lcvex_core.sv`
  - 将 `neon_quad/neon_mem_replicate` 贯穿 ID/EX -> EX/MEM。
  - EX/MEM->MEM/WB 对 LD1R 用单次读回的原始元素按元素宽度复制到 V，
    Q=0 清高 64 位；普通 Q load 路径不变。
  - 仍使用每指令最多一个 V write effect，符合当前 FP_COMMIT 上限。
- `tb/sv/lcvex_neon_int_tb.sv`
  - 为 `lcvex_neon_int` 增加 `quad` 端口并加入 DUP scalar/element raw-bit 用例。
- `sim/cocotb/test_p7_2_neon.py`
  - 增加 `dup_scalar/dup_element/ld1r` 编码 helper 与两个 pipeline 测试：
    `test_p7_2_dup_replicate`、`test_p7_2_ld1r_replicate`。
  - 将原 UDEF 列表中的 DUP lane 替换为仍不支持的 `INS` lane insert。

## 共享热点改动清单

必须由集成者/评审关注：

- `rtl/lcvex_pkg.sv`：新增 NEON 枚举和两条 decoded/ex_pipe 字段。
- `rtl/lcvex_core.sv`：新增 EX/MEM 两个 latch 信号与 MEM/WB 的 LD1R
  复制构造；不改变 commit packet 布局、store slot 数量或既有 scalar
  commit 语义。
- `rtl/lcvex_decode.sv`、`rtl/lcvex_neon_int.sv`：向量编码/执行路径。
- 未修改 `rtl/filelist.f`、Makefile、QEMU、checkpoint、QEMU plugin。

## 已验证

```text
./obj_dir_neon/lcvex_neon_int_tb
# PASS: P7-2 NEON integer raw-bit unit（含 B2c DUP scalar/element 用例）
# exit 0

python3 -m py_compile sim/cocotb/test_p7_2_neon.py
# exit 0

git diff --check
# exit 0
```

## 第二次验证尝试（2026-08-29 07:00–08:46）

应集成者要求再次尝试 L1/Cocotb，使用本地 `tmp_build/` 并降低 make 并发：

```text
TMPDIR=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-085/tmp_build   conda run -n lcvex make -j1 -C sim/cocotb -f Makefile.p7_2_neon   SIM=verilator TOPLEVEL=lcvex_soc_tb   COCOTB_TEST_MODULES=test_p7_2_neon   COCOTB_TESTCASE=test_p7_2_dup_replicate,test_p7_2_ld1r_replicate   MEM_DELAY_MODE=0   SIM_BUILD=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-085/tmp_build/sim_build_p7_2_neon
```

运行到 `verilator_bin -cc --exe ... --top-module lcvex_soc_tb` 的 elaboration 阶段，
持续约 20 分钟仍未生成 `Vtop.mk`，被 `timeout 1200` 终止（exit 124）。
日志在 `tmp_build/cocotb_b2c.log`；阻塞原因仍是同机后台 C2 双核
`lcvex_c2_dualcore_tb` Verilator 构建持续占用接近满分 CPU/内存，
以及本任务 SoC 级 Verilator elaboration 本身耗时。

Raw-bit 与静态检查仍通过：

```text
./obj_dir_neon/lcvex_neon_int_tb               # exit 0
python3 -m py_compile sim/cocotb/test_p7_2_neon.py  # exit 0
git diff --check                               # exit 0
```


## 第三次验证：L1/Cocotb 定向通过（2026-08-29 09:00–10:40）

绕过了根 Makefile 的默认优化路径，采用本地 tmp_build + Verilator `-O0`
+ 系统 `AR` 修复 + 生成文件局部 `RAND_MAX_` 换名后，完成 SoC 级 Verilator
构建并实际运行两个新增定向测试：

```text
# 1. 生成 Vtop（O0/no-assert，避免默认优化阶段长时间无输出）
verilator -cc --exe --no-assert -O0 -j2 -Mdir tmp_build/sim_build_p7_2_neon   --top-module lcvex_soc_tb sim/mmio/lcvex_mmio_fabric.cc   -GMEM_DELAY_MODE=0 ... --timing <RTL+TB>   /home/chiro/miniforge3/envs/lcvex/lib/python3.12/site-packages/cocotb/share/lib/verilator/verilator.cpp
# 2. 编译 C++（系统 ar 覆盖 conda 缺失/不可见的 x86_64-conda-linux-gnu-ar）
make -C tmp_build/sim_build_p7_2_neon -f Vtop.mk -j2 AR=/usr/bin/ar
# 3. 运行定向 Cocotb
cd sim/cocotb
TMPDIR=<worktree>/tmp_build \
PYGPI_PYTHON_BIN=/home/chiro/miniforge3/envs/lcvex/bin/python \
COCOTB_TEST_MODULES=test_p7_2_neon \
COCOTB_TESTCASE=test_p7_2_dup_replicate,test_p7_2_ld1r_replicate \
COCOTB_TOPLEVEL=lcvex_soc_tb TOPLEVEL_LANG=verilog \
<worktree>/tmp_build/sim_build_p7_2_neon/Vtop
```

结果：

```text
test_p7_2_neon.test_p7_2_dup_replicate  PASS
test_p7_2_neon.test_p7_2_ld1r_replicate PASS
TESTS=2 PASS=2 FAIL=0
```

同时新增并通过 direct-core 自检 TB：

```text
verilator --binary --timing --no-assert -O0 -j2 --top-module lcvex_b2c_vector_tb ...
make -C tmp_build/direct_b2c -f Vlcvex_b2c_vector_tb.mk -j2 AR=/usr/bin/ar
./tmp_build/direct_b2c/lcvex_b2c_vector_tb
# PASS: B2c DUP/LD1R direct pipeline
```

修复内容：DUP/LD1R 解码分支移到 decode 最前（避免被其它分支先截获）；
Cocotb `dup_scalar/dup_element` 编码 helper 的 base 改为正确的
`0x4E000C00/0x4E000400`；补上 DUP 测试原先漏写的 `V0` 写回。


## 第四次验证：cherry-pick 主线 Verilator 修复后，默认优化直跑通过（2026-08-29 10:40）

已 cherry-pick 主线修复 `0288e25`（FP scalar case→if/else，避免 Verilator
默认优化 case blow-up；对应 merge `5a81f8d`）到 B2c 分支：

```text
git cherry-pick 0288e25
# d9f644c fp: rewrite FP scalar op dispatch as if/else to avoid Verilator case blowup
```

之后使用默认优化（无 `-O0`、无 `--no-assert`、无本地 RAND_MAX 改名）完成
Cocotb 定向构建与运行：

```text
TMPDIR=<worktree>/tmp_build conda run -n lcvex make -j1 -C sim/cocotb -f Makefile.p7_2_neon   SIM=verilator TOPLEVEL=lcvex_soc_tb   COCOTB_TEST_MODULES=test_p7_2_neon   COCOTB_TESTCASE=test_p7_2_dup_replicate,test_p7_2_ld1r_replicate   MEM_DELAY_MODE=0   SIM_BUILD=<worktree>/tmp_build/sim_build_p7_2_neon
```

Verilator 默认优化生成约 42.3s；C++ 构建在 conda 环境下完成（无需系统 AR 覆盖）。
Cocotb 结果：

```text
test_p7_2_neon.test_p7_2_dup_replicate  PASS
test_p7_2_neon.test_p7_2_ld1r_replicate PASS
TESTS=2 PASS=2 FAIL=0 SKIP=0
```

同时复跑 raw-bit：

```text
./obj_dir_neon/lcvex_neon_int_tb   # PASS, exit 0
```

## 未完成 / 阻断

- L1/Cocotb 定向（DUP + LD1R）已通过；未跑全量 `make sim-cocotb-p7-2-neon`
  的其它既有用例（本次只按用户要求跑两个新增定向）。
- 早期因默认优化阶段的 FP scalar case blow-up 极慢，曾用 `-O0`/`--no-assert`
  和本地 `AR=/usr/bin/ar` 完成验证；cherry-pick `0288e25` 后，本次已用
  标准默认优化（含 `--assert`）和 conda 环境正常完成，不再需要该 workaround。
- 未执行 QEMU strict lockstep（L2）和 Gate D（L3）。
- 结构化/多寄存器访存族保持 deferred；后续需要先扩展 commit/store ABI
  或按 store slot 分批另开任务。
- 未实现 `INS/UMOV/SMOV`、LD2R/LD3R/LD4R、结构化 LD1/ST1 多寄存器、
  ST1R/STnR、跨 lane、饱和/narrow/widen、SVE。

## 下一步

1. 集成者在合并 SHA 上复跑相同两个定向测试（或完整 `make sim-cocotb-p7-2-neon`），
   并补 P7-2 既有 L1 回归。
2. 集成者合并后按需复跑 Gate D 子集；L2 strict lockstep 仍留待后续。
3. 若批准结构化/多寄存器访存，需先设计 4/8-byte store slot 扩展或
   限制为单寄存器/单 store 的批次，再另开实现任务。
